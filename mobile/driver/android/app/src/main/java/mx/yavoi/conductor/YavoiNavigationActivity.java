package mx.yavoi.conductor;

import android.Manifest;
import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.media.AudioManager;
import android.media.ToneGenerator;
import android.speech.tts.TextToSpeech;
import android.os.Build;
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
    public static final String ACTION_EVENT = "mx.yavoi.conductor.NAVIGATION_EVENT";
    public static final String ACTION_COMMAND = "mx.yavoi.conductor.NAVIGATION_COMMAND";
    public static final String EXTRA_EVENT = "event";
    public static final String EXTRA_OFFER_ID = "offer_id";
    public static final String EXTRA_FINAL_DESTINATION = "final_destination";
    public static final String EXTRA_FINAL_LAT = "final_lat";
    public static final String EXTRA_FINAL_LNG = "final_lng";
    public static final String EXTRA_TOTAL = "total";
    public static final String EXTRA_PASSENGER_NAME = "passenger_name";
    public static final String EXTRA_COMMAND = "command";

    private static final int LOCATION_PERMISSION_REQUEST = 41;
    private Navigator navigator;
    private SupportNavigationFragment navigationFragment;
    private String stage;
    private String paymentMethod;
    private double destinationLat;
    private double destinationLng;
    private boolean destinationReached = false;
    private String tripId, finalDestination, total, passengerName;
    private double finalLat, finalLng;
    private android.view.View offerCard;
    private TextToSpeech speech;
    private final BroadcastReceiver commandReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            String command = intent.getStringExtra(EXTRA_COMMAND);
            if ("next_trip".equals(command)) { switchTrip(intent); return; }
            if ("close".equals(command)) { finishWithAction("resume", true); return; }
            String offerId = intent.getStringExtra(EXTRA_OFFER_ID);
            ((TextView) findViewById(R.id.navigation_offer_title)).setText("NUEVO VIAJE DISPONIBLE");
            ((TextView) findViewById(R.id.navigation_offer_summary)).setText(intent.getStringExtra("summary"));
            ((TextView) findViewById(R.id.navigation_offer_route)).setText(intent.getStringExtra("route"));
            offerCard.setTag(offerId); offerCard.setVisibility(android.view.View.VISIBLE);
            new ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90).startTone(ToneGenerator.TONE_PROP_BEEP2, 280);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_yavoi_navigation);

        applyTrip(getIntent());
        String destination = getIntent().getStringExtra(EXTRA_DESTINATION);

        TextView stageView = findViewById(R.id.navigation_stage);
        TextView destinationView = findViewById(R.id.navigation_destination);
        Button primary = findViewById(R.id.navigation_primary_action);
        Button returnToTrip = findViewById(R.id.navigation_return_action);

        offerCard = findViewById(R.id.navigation_offer_card);
        renderStage(destination);
        speech = new TextToSpeech(this, status -> {});
        primary.setOnClickListener(view -> handlePrimaryAction());
        returnToTrip.setOnClickListener(view -> finishWithAction("resume", destinationReached));
        findViewById(R.id.navigation_offer_accept).setOnClickListener(view -> {
            dispatchEvent("accept_offer", String.valueOf(offerCard.getTag()));
            offerCard.setVisibility(android.view.View.GONE);
        });
        ContextCompat.registerReceiver(this, commandReceiver, new IntentFilter(ACTION_COMMAND), ContextCompat.RECEIVER_NOT_EXPORTED);

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
        if (navigator == null || !Double.isFinite(destinationLat) || !Double.isFinite(destinationLng)) return;
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

    private String primaryLabel() {
        if ("pickup".equals(stage)) return destinationReached ? "Confirmar llegada" : "Avisar que ya llegué";
        if ("ready".equals(stage)) return "Iniciar viaje";
        if ("destination".equals(stage)) return "Llegué al destino";
        if ("switching".equals(stage)) return "Preparando siguiente viaje";
        return "cash".equals(paymentMethod) ? "Confirmar dinero recibido" : "Completar viaje";
    }

    private void renderStage(String initialDestination) {
        TextView stageView = findViewById(R.id.navigation_stage);
        TextView destinationView = findViewById(R.id.navigation_destination);
        String label = "pickup".equals(stage) ? "Ve por tu pasajero" : "ready".equals(stage) ? "Pasajero a bordo" : "destination".equals(stage) ? "Lleva al pasajero a su destino" : "switching".equals(stage) ? "Preparando siguiente viaje" : "Cierre del viaje";
        stageView.setText(label);
        ((TextView) findViewById(R.id.navigation_passenger)).setText("Ver por " + (passengerName == null || passengerName.trim().isEmpty() ? "pasajero" : passengerName));
        String target = ("destination".equals(stage) || "collect".equals(stage)) ? finalDestination : initialDestination;
        destinationView.setText(target == null || target.trim().isEmpty() ? "Destino del viaje" : target);
        ((Button) findViewById(R.id.navigation_primary_action)).setText(primaryLabel());
        findViewById(R.id.navigation_primary_action).setEnabled(!"switching".equals(stage));
    }

    private void handlePrimaryAction() {
        if ("pickup".equals(stage)) {
            dispatchEvent("arrive", null); if (navigator != null) navigator.stopGuidance(); stage = "ready"; renderStage(getIntent().getStringExtra(EXTRA_DESTINATION)); speak("Ya llegaste por " + passengerName + ". Confirma cuando el pasajero esté listo."); return;
        }
        if ("ready".equals(stage)) {
            dispatchEvent("start", null); stage = "destination"; destinationLat = finalLat; destinationLng = finalLng; routeToDestination(); renderStage(null); speak("Viaje iniciado. Te llevamos al destino de " + passengerName + "."); return;
        }
        if ("destination".equals(stage)) {
            if (navigator != null) navigator.stopGuidance(); stage = "collect"; renderStage(null); return;
        }
        dispatchEvent("complete", null); stage = "switching"; renderStage(null); speak("Que tengas un bonito día, " + passengerName + ". Buscando tu siguiente viaje.");
    }

    private void applyTrip(Intent source) {
        stage = source.getStringExtra(EXTRA_STAGE); if (stage == null) stage = "pickup";
        tripId = source.getStringExtra(EXTRA_TRIP_ID);
        passengerName = source.getStringExtra(EXTRA_PASSENGER_NAME);
        paymentMethod = source.getStringExtra(EXTRA_PAYMENT_METHOD);
        finalDestination = source.getStringExtra(EXTRA_FINAL_DESTINATION);
        finalLat = source.getDoubleExtra(EXTRA_FINAL_LAT, Double.NaN);
        finalLng = source.getDoubleExtra(EXTRA_FINAL_LNG, Double.NaN);
        total = source.getStringExtra(EXTRA_TOTAL);
        destinationLat = source.getDoubleExtra(EXTRA_LAT, Double.NaN);
        destinationLng = source.getDoubleExtra(EXTRA_LNG, Double.NaN);
        destinationReached = false;
    }
    private void switchTrip(Intent source) {
        applyTrip(source);
        offerCard.setVisibility(android.view.View.GONE);
        renderStage(source.getStringExtra(EXTRA_DESTINATION));
        routeToDestination();
        speak("Nuevo viaje. Ve por " + passengerName + ".");
    }
    private void speak(String message) {
        if (speech == null || message == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) speech.speak(message, TextToSpeech.QUEUE_ADD, null, "yavoi-" + System.nanoTime());
        else speech.speak(message, TextToSpeech.QUEUE_ADD, null);
    }

    private void dispatchEvent(String action, String offerId) {
        Intent event = new Intent(ACTION_EVENT); event.setPackage(getPackageName());
        event.putExtra(EXTRA_EVENT, action); event.putExtra(EXTRA_TRIP_ID, tripId); event.putExtra(EXTRA_OFFER_ID, offerId); sendBroadcast(event);
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
        try { unregisterReceiver(commandReceiver); } catch (Exception ignored) {}
        if (speech != null) { speech.stop(); speech.shutdown(); }
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
