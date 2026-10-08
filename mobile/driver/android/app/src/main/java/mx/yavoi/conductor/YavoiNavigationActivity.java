package mx.yavoi.conductor;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.google.android.gms.maps.GoogleMap.CameraPerspective;
import com.google.android.libraries.navigation.AudioGuidanceSettings;
import com.google.android.libraries.navigation.ListenableResultFuture;
import com.google.android.libraries.navigation.NavigationApi;
import com.google.android.libraries.navigation.SupportNavigationFragment;
import com.google.android.libraries.navigation.Navigator;
import com.google.android.libraries.navigation.RoutingOptions;
import com.google.android.libraries.navigation.Waypoint;

/**
 * Native, in-app Navigation SDK surface for Yavoi! Drive.
 * Business transitions remain server-authoritative: this activity returns an action to the Capacitor
 * bridge, which then executes the existing verified trip transition in the web layer.
 */
public class YavoiNavigationActivity extends AppCompatActivity {
    public static final String EXTRA_TRIP_ID = "trip_id";
    public static final String EXTRA_STAGE = "stage";
    public static final String EXTRA_DESTINATION = "destination";
    public static final String EXTRA_PAYMENT_METHOD = "payment_method";
    public static final String EXTRA_LAT = "lat";
    public static final String EXTRA_LNG = "lng";
    public static final String RESULT_ACTION = "action";
    public static final String RESULT_ARRIVED = "arrived";

    private static final int LOCATION_PERMISSION_REQUEST = 41;
    private Navigator navigator;
    private SupportNavigationFragment navigationFragment;
    private String stage;
    private String paymentMethod;
    private double destinationLat;
    private double destinationLng;
    private boolean destinationReached = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_yavoi_navigation);

        stage = getIntent().getStringExtra(EXTRA_STAGE);
        paymentMethod = getIntent().getStringExtra(EXTRA_PAYMENT_METHOD);
        destinationLat = getIntent().getDoubleExtra(EXTRA_LAT, Double.NaN);
        destinationLng = getIntent().getDoubleExtra(EXTRA_LNG, Double.NaN);
        String destination = getIntent().getStringExtra(EXTRA_DESTINATION);

        TextView stageView = findViewById(R.id.navigation_stage);
        TextView destinationView = findViewById(R.id.navigation_destination);
        Button primary = findViewById(R.id.navigation_primary_action);
        Button returnToTrip = findViewById(R.id.navigation_return_action);

        boolean pickup = "pickup".equals(stage);
        stageView.setText(pickup ? "Ve por tu pasajero" : "Lleva al pasajero a su destino");
        destinationView.setText(destination == null || destination.trim().isEmpty() ? "Destino del viaje" : destination);
        primary.setText(primaryLabel());
        primary.setOnClickListener(view -> finishWithAction(primaryAction(), destinationReached));
        returnToTrip.setOnClickListener(view -> finishWithAction("resume", destinationReached));

        if (!Double.isFinite(destinationLat) || !Double.isFinite(destinationLng)) {
            Toast.makeText(this, "No encontramos coordenadas válidas para este destino.", Toast.LENGTH_LONG).show();
            return;
        }
        if (hasLocationPermission()) initializeNavigation();
        else ActivityCompat.requestPermissions(this, new String[] { Manifest.permission.ACCESS_FINE_LOCATION }, LOCATION_PERMISSION_REQUEST);
    }

    private boolean hasLocationPermission() {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private void initializeNavigation() {
        NavigationApi.getNavigator(this, new NavigationApi.NavigatorListener() {
            @Override
            public void onNavigatorReady(Navigator readyNavigator) {
                navigator = readyNavigator;
                navigationFragment = (SupportNavigationFragment) getSupportFragmentManager().findFragmentById(R.id.yavoi_navigation_fragment);
                if (navigationFragment != null) {
                    navigationFragment.getMapAsync(map -> map.followMyLocation(CameraPerspective.TILTED));
                }
                navigator.addArrivalListener(arrivalEvent -> {
                    if (arrivalEvent.isFinalDestination()) {
                        destinationReached = true;
                        ((TextView) findViewById(R.id.navigation_stage)).setText("Llegaste al punto del viaje");
                        ((Button) findViewById(R.id.navigation_primary_action)).setText(primaryLabel());
                    }
                });
                routeToDestination();
            }

            @Override
            public void onError(@NavigationApi.ErrorCode int errorCode) {
                Toast.makeText(YavoiNavigationActivity.this, "No se pudo iniciar la navegación: " + errorCode, Toast.LENGTH_LONG).show();
            }
        });
    }

    private void routeToDestination() {
        Waypoint waypoint = Waypoint.builder()
                .setLatLng(destinationLat, destinationLng)
                .setTitle(getIntent().getStringExtra(EXTRA_DESTINATION))
                .setVehicleStopover(true)
                .build();
        RoutingOptions options = new RoutingOptions();
        options.travelMode(RoutingOptions.TravelMode.DRIVING);
        ListenableResultFuture<Navigator.RouteStatus> route = navigator.setDestination(waypoint, options);
        route.setOnResultListener(status -> {
            if (status == Navigator.RouteStatus.OK) {
                navigator.setAudioGuidanceSettings(AudioGuidanceSettings.builder()
                        .setGuidanceMode(AudioGuidanceSettings.GuidanceMode.VOICE_ALERTS_AND_GUIDANCE)
                        .build());
                navigator.startGuidance();
            } else {
                Toast.makeText(this, "No pudimos trazar la ruta: " + status, Toast.LENGTH_LONG).show();
            }
        });
    }

    private String primaryAction() {
        if ("pickup".equals(stage)) return "arrive";
        return "finish";
    }

    private String primaryLabel() {
        if ("pickup".equals(stage)) return destinationReached ? "Confirmar llegada" : "Avisar que ya llegué";
        return "cash".equals(paymentMethod) ? "Finalizar y recolectar dinero" : "Finalizar viaje";
    }

    private void finishWithAction(String action, boolean arrived) {
        Intent result = new Intent();
        result.putExtra(RESULT_ACTION, action);
        result.putExtra(RESULT_ARRIVED, arrived);
        setResult(RESULT_OK, result);
        finish();
    }

    @Override
    protected void onDestroy() {
        if (navigator != null && isFinishing()) navigator.stopGuidance();
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == LOCATION_PERMISSION_REQUEST && grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            initializeNavigation();
        } else if (requestCode == LOCATION_PERMISSION_REQUEST) {
            Toast.makeText(this, "Yavoi! Drive necesita ubicación precisa para navegar.", Toast.LENGTH_LONG).show();
        }
    }
}
