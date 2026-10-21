package mx.yavoi.conductor;

import android.app.Presentation;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.app.Application;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.graphics.Point;
import android.view.Display;

import androidx.annotation.NonNull;
import androidx.car.app.AppManager;
import androidx.car.app.CarContext;
import androidx.car.app.Screen;
import androidx.car.app.SurfaceCallback;
import androidx.car.app.SurfaceContainer;
import androidx.car.app.model.Action;
import androidx.car.app.model.ActionStrip;
import androidx.car.app.model.Alert;
import androidx.car.app.model.AlertCallback;
import androidx.car.app.model.CarText;
import androidx.car.app.model.DateTimeWithZone;
import androidx.car.app.model.Distance;
import androidx.car.app.navigation.model.NavigationTemplate;
import androidx.car.app.navigation.model.RoutingInfo;
import androidx.car.app.navigation.model.Step;
import androidx.car.app.navigation.model.TravelEstimate;
import androidx.core.graphics.drawable.IconCompat;
import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.LifecycleOwner;

import com.google.android.gms.maps.CameraUpdateFactory;
import com.google.android.gms.maps.GoogleMap;
import com.google.android.gms.maps.GoogleMap.CameraPerspective;
import com.google.android.gms.maps.model.MapStyleOptions;
import com.google.android.libraries.navigation.NavigationViewForAuto;
import com.google.android.libraries.navigation.NavigationApi;
import com.google.android.libraries.navigation.Navigator;

import java.util.TimeZone;

/** Android Auto surface, turn card and compact driver controls for Yavoi! Drive. */
public final class YavoiCarNavigationScreen extends Screen implements SurfaceCallback {
    private static final String DISPLAY_NAME = "Yavoi! Drive Navigation";
    private static final int OFFER_ALERT_ID = 6201;
    private static final int CASH_ALERT_ID = 6202;

    private final AppManager appManager;
    private final Runnable stateObserver;
    private VirtualDisplay virtualDisplay;
    private Presentation presentation;
    private NavigationViewForAuto navigationView;
    private GoogleMap googleMap;
    private String offerAlertFor = "";
    private boolean cashAlertShown;
    private boolean released;
    private boolean navigatorRequested;

    YavoiCarNavigationScreen(@NonNull CarContext carContext) {
        super(carContext);
        appManager = carContext.getCarService(AppManager.class);
        appManager.setSurfaceCallback(this);
        stateObserver = this::onStateChanged;
        YavoiCarState.observe(stateObserver);
        getLifecycle().addObserver(new DefaultLifecycleObserver() {
            @Override public void onResume(@NonNull LifecycleOwner owner) {
                if (YavoiCarState.hasActiveRoute() && getCarContext().checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                        == PackageManager.PERMISSION_GRANTED) requestSharedNavigatorIfNeeded();
                onStateChanged();
            }
            @Override public void onDestroy(@NonNull LifecycleOwner owner) {
                release();
            }
        });
    }

    private void requestSharedNavigatorIfNeeded() {
        if (YavoiCarState.navigator() != null || navigatorRequested) return;
        navigatorRequested = true;
        Application application = (Application) getCarContext().getApplicationContext();
        try { NavigationApi.getNavigator(application, new NavigationApi.NavigatorListener() {
            @Override public void onNavigatorReady(Navigator navigator) {
                YavoiCarState.setNavigator(navigator, application);
            }
            @Override public void onError(int errorCode) {
                navigatorRequested = false;
                appManager.showToast("Abre Yavoi! Drive en tu teléfono y concede ubicación para usar la navegación.", android.widget.Toast.LENGTH_LONG);
            }
        }); } catch (RuntimeException error) { navigatorRequested = false; }
    }

    @NonNull
    @Override
    public androidx.car.app.model.Template onGetTemplate() {
        NavigationTemplate.Builder template = new NavigationTemplate.Builder()
                .setActionStrip(buildActionStrip());
        if (getCarContext().getCarAppApiLevel() >= 2) {
            Action brand = new Action.Builder()
                    .setIcon(new androidx.car.app.model.CarIcon.Builder(
                            IconCompat.createWithResource(getCarContext(), R.mipmap.ic_launcher)).build())
                    .setOnClickListener(() -> appManager.showToast("Yavoi! Drive", android.widget.Toast.LENGTH_SHORT))
                    .build();
            template.setMapActionStrip(new ActionStrip.Builder().addAction(Action.PAN).addAction(brand).build());
        }

        RoutingInfo routingInfo = buildRoutingInfo();
        if (routingInfo != null) template.setNavigationInfo(routingInfo);

        Integer meters = YavoiCarState.destinationDistanceMeters();
        Integer seconds = YavoiCarState.destinationSeconds();
        if (YavoiCarState.hasActiveRoute() && meters != null && seconds != null) {
            long safeSeconds = Math.max(0, seconds.longValue());
            TravelEstimate.Builder estimate = new TravelEstimate.Builder(
                    distance(meters), DateTimeWithZone.create(
                    System.currentTimeMillis() + safeSeconds * 1000L, TimeZone.getDefault()))
                    .setRemainingTimeSeconds(safeSeconds);
            if (getCarContext().getCarAppApiLevel() >= 5) {
                estimate.setTripText(CarText.create(YavoiCarState.passengerTripLabel()));
            }
            template.setDestinationTravelEstimate(estimate.build());
        }
        return template.build();
    }

    private ActionStrip buildActionStrip() {
        ActionStrip.Builder strip = new ActionStrip.Builder();
        YavoiCarState.Offer offer = YavoiCarState.offer();
        if (offer != null) {
            strip.addAction(new Action.Builder().setTitle("Aceptar")
                    .setOnClickListener(() -> acceptOffer(offer.id)).build());
            strip.addAction(new Action.Builder().setTitle("Rechazar")
                    .setOnClickListener(() -> rejectOffer(offer.id)).build());
            return strip.build();
        }

        String stage = YavoiCarState.stage();
        String title = null;
        if ("pickup".equals(stage)) title = "Avisar llegada";
        else if ("ready".equals(stage)) title = "Comenzar viaje";
        else if ("destination".equals(stage)) title = "Llegué al destino";
        else if ("collect".equals(stage)) title = "cash".equals(YavoiCarState.payment()) ? "Confirmar pago" : "Finalizar viaje";
        if (title != null) {
            strip.addAction(new Action.Builder().setTitle(title)
                    .setOnClickListener(this::runPrimaryAction).build());
        }
        if (YavoiCarState.queuedTrips() > 0) {
            strip.addAction(new Action.Builder().setTitle("Cola " + YavoiCarState.queuedTrips())
                    .setOnClickListener(() -> appManager.showToast(
                            YavoiCarState.queuedTrips() + " viaje(s) aceptados para después del actual",
                            android.widget.Toast.LENGTH_SHORT)).build());
        }
        if (title == null && YavoiCarState.queuedTrips() == 0) {
            strip.addAction(new Action.Builder().setTitle("Yavoi!")
                    .setOnClickListener(() -> appManager.showToast("Yavoi! Drive · listo para viajes",
                            android.widget.Toast.LENGTH_SHORT)).build());
        }
        return strip.build();
    }

    private RoutingInfo buildRoutingInfo() {
        if (!YavoiCarState.hasActiveRoute()) return null;
        String cue = YavoiCarState.cue();
        if (cue == null || cue.trim().isEmpty()) return null;
        Step.Builder step = new Step.Builder(cue.trim());
        String road = YavoiCarState.road();
        if (road != null && !road.trim().isEmpty()) step.setRoad(road.trim());
        Integer remainingMeters = YavoiCarState.stepDistanceMeters();
        return new RoutingInfo.Builder()
                .setCurrentStep(step.build(), distance(remainingMeters == null ? 0 : remainingMeters))
                .build();
    }

    private static Distance distance(int meters) {
        return Distance.create(Math.max(0, meters), Distance.UNIT_METERS);
    }

    private void onStateChanged() {
        if (released) return;
        if (YavoiCarState.hasActiveRoute() && !navigatorRequested
                && getCarContext().checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED) requestSharedNavigatorIfNeeded();
        invalidate();
        if (!getLifecycle().getCurrentState().isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)) return;
        YavoiCarState.Offer offer = YavoiCarState.offer();
        if (offer == null) {
            if (!offerAlertFor.isEmpty()) dismissAlert(OFFER_ALERT_ID);
            offerAlertFor = "";
        } else if (!offer.id.equals(offerAlertFor)) {
            offerAlertFor = offer.id;
            showOfferAlert(offer);
        }

        if (!"collect".equals(YavoiCarState.stage()) || !"cash".equals(YavoiCarState.payment())) {
            if (cashAlertShown) dismissAlert(CASH_ALERT_ID);
            cashAlertShown = false;
        } else if (YavoiCarState.fareReady() && !cashAlertShown) {
            cashAlertShown = true;
            showCashAlert();
        }
    }

    private void showOfferAlert(YavoiCarState.Offer offer) {
        if (getCarContext().getCarAppApiLevel() < 5) {
            appManager.showToast("Nuevo viaje: " + offer.summary, android.widget.Toast.LENGTH_LONG);
            return;
        }
        try {
            Alert alert = new Alert.Builder(OFFER_ALERT_ID, CarText.create("Nuevo viaje Yavoi!"), 10000L)
                    .setSubtitle(CarText.create(offer.summary + "\n" + offer.route))
                    .setIcon(new androidx.car.app.model.CarIcon.Builder(
                            IconCompat.createWithResource(getCarContext(), mx.yavoi.conductor.R.mipmap.ic_launcher)).build())
                    .addAction(new Action.Builder().setTitle("Aceptar")
                            .setOnClickListener(() -> acceptOffer(offer.id)).build())
                    .addAction(new Action.Builder().setTitle("Rechazar")
                            .setOnClickListener(() -> rejectOffer(offer.id)).build())
                    .setCallback(new AlertCallback() {
                        @Override public void onCancel(int reason) { }
                        @Override public void onDismiss() { }
                    }).build();
            appManager.showAlert(alert);
        } catch (RuntimeException unsupportedHost) {
            appManager.showToast("Nuevo viaje disponible: " + offer.summary, android.widget.Toast.LENGTH_LONG);
        }
    }

    private void showCashAlert() {
        if (getCarContext().getCarAppApiLevel() < 5) {
            appManager.showToast("Confirma el efectivo recibido en Yavoi! Drive.", android.widget.Toast.LENGTH_LONG);
            return;
        }
        String detail = "Total " + YavoiCarState.total()
                + " · espera " + YavoiCarState.waiting()
                + " · ajustes " + YavoiCarState.adjustments()
                + " · demanda " + YavoiCarState.dynamic();
        try {
            Alert alert = new Alert.Builder(CASH_ALERT_ID, CarText.create("Llegada y pago en efectivo"), 15000L)
                    .setSubtitle(CarText.create(detail))
                    .addAction(new Action.Builder().setTitle("Recibí el pago")
                            .setOnClickListener(() -> sendActivityCommand("car_confirm_cash")).build())
                    .addAction(new Action.Builder().setTitle("Ahora no")
                            .setOnClickListener(() -> dismissAlert(CASH_ALERT_ID)).build())
                    .build();
            appManager.showAlert(alert);
        } catch (RuntimeException unsupportedHost) {
            appManager.showToast("Total a recolectar: " + YavoiCarState.total(), android.widget.Toast.LENGTH_LONG);
        }
    }

    private void acceptOffer(String offerId) {
        dismissAlert(OFFER_ALERT_ID);
        YavoiCarState.clearOffer();
        dispatchEvent("accept_offer", offerId);
    }

    private void rejectOffer(String offerId) {
        dismissAlert(OFFER_ALERT_ID);
        YavoiCarState.clearOffer();
        dispatchEvent("reject_offer", offerId);
    }

    private void runPrimaryAction() {
        if ("collect".equals(YavoiCarState.stage()) && "cash".equals(YavoiCarState.payment())) {
            showCashAlert();
        } else {
            sendActivityCommand("car_primary");
        }
    }

    private void dispatchEvent(String action, String offerId) {
        Intent event = new Intent(YavoiNavigationActivity.ACTION_EVENT)
                .setPackage(getCarContext().getPackageName())
                .putExtra(YavoiNavigationActivity.EXTRA_EVENT, action)
                .putExtra(YavoiNavigationActivity.EXTRA_TRIP_ID, YavoiCarState.tripId())
                .putExtra(YavoiNavigationActivity.EXTRA_OFFER_ID, offerId);
        getCarContext().sendBroadcast(event);
    }

    private void sendActivityCommand(String command) {
        Intent intent = new Intent(YavoiNavigationActivity.ACTION_COMMAND)
                .setPackage(getCarContext().getPackageName())
                .putExtra(YavoiNavigationActivity.EXTRA_COMMAND, command);
        getCarContext().sendBroadcast(intent);
    }

    private void dismissAlert(int id) {
        if (getCarContext().getCarAppApiLevel() < 5) return;
        try { appManager.dismissAlert(id); } catch (RuntimeException ignored) { }
    }

    private static boolean isSurfaceReady(SurfaceContainer container) {
        return container.getSurface() != null && container.getDpi() > 0
                && container.getWidth() > 0 && container.getHeight() > 0;
    }

    @Override public void onSurfaceAvailable(@NonNull SurfaceContainer container) {
        if (!isSurfaceReady(container) || released) return;
        releaseSurface();
        DisplayManager manager = (DisplayManager) getCarContext().getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) return;
        virtualDisplay = manager.createVirtualDisplay(DISPLAY_NAME, container.getWidth(), container.getHeight(),
                container.getDpi(), container.getSurface(), DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY);
        if (virtualDisplay == null) return;
        Display display = virtualDisplay.getDisplay();
        presentation = new Presentation(getCarContext(), display);
        navigationView = new NavigationViewForAuto(getCarContext());
        navigationView.onCreate(null);
        navigationView.onStart();
        navigationView.onResume();
        presentation.setContentView(navigationView);
        presentation.show();
        navigationView.getMapAsync(map -> {
            googleMap = map;
            try {
                map.setMapStyle(MapStyleOptions.loadRawResourceStyle(getCarContext(), R.raw.yavoi_car_map_style));
                if (getCarContext().checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                        == PackageManager.PERMISSION_GRANTED) map.setMyLocationEnabled(true);
                map.followMyLocation(CameraPerspective.TILTED);
            } catch (SecurityException ignored) { }
        });
    }

    @Override public void onSurfaceDestroyed(@NonNull SurfaceContainer container) { releaseSurface(); }

    @Override public void onClick(float x, float y) { }

    @Override public void onScale(float focusX, float focusY, float scaleFactor) {
        if (googleMap != null) googleMap.animateCamera(CameraUpdateFactory.zoomBy(scaleFactor - 1f,
                new Point((int) focusX, (int) focusY)));
    }

    @Override public void onScroll(float distanceX, float distanceY) {
        if (googleMap != null) googleMap.moveCamera(CameraUpdateFactory.scrollBy(distanceX, distanceY));
    }

    private void releaseSurface() {
        if (navigationView != null) {
            try { navigationView.onPause(); } catch (RuntimeException ignored) { }
            try { navigationView.onStop(); } catch (RuntimeException ignored) { }
            try { navigationView.onDestroy(); } catch (RuntimeException ignored) { }
            navigationView = null;
        }
        googleMap = null;
        if (presentation != null) {
            try { presentation.dismiss(); } catch (RuntimeException ignored) { }
            presentation = null;
        }
        if (virtualDisplay != null) {
            virtualDisplay.release();
            virtualDisplay = null;
        }
    }

    void release() {
        if (released) return;
        released = true;
        YavoiCarState.removeObserver(stateObserver);
        releaseSurface();
    }
}
