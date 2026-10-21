package mx.yavoi.conductor;

import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;

import com.google.android.libraries.mapsplatform.turnbyturn.model.NavInfo;
import com.google.android.libraries.mapsplatform.turnbyturn.model.StepInfo;
import com.google.android.libraries.navigation.NavigationUpdatesOptions;
import com.google.android.libraries.navigation.Navigator;

import java.util.concurrent.CopyOnWriteArrayList;

/** Shared, process-local snapshot for the phone navigator and Android Auto screen. */
final class YavoiCarState {
    static final class Offer {
        final String id, summary, route;
        Offer(String id, String summary, String route) {
            this.id = safe(id); this.summary = safe(summary); this.route = safe(route);
        }
    }

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final CopyOnWriteArrayList<Runnable> observers = new CopyOnWriteArrayList<>();
    private static volatile boolean autoConnected;
    private static volatile String tripId = "", stage = "idle", passenger = "", destination = "", pickup = "", payment = "cash";
    private static volatile String total = "", waiting = "$0.00", adjustments = "$0.00", dynamic = "$0.00", fareError = "";
    private static volatile boolean fareReady;
    private static volatile Offer offer;
    private static volatile int queuedTrips;
    private static volatile String road = "", cue = "";
    private static volatile int maneuver = 0;
    private static volatile Integer stepDistanceMeters, destinationDistanceMeters, destinationSeconds;
    private static volatile Bitmap maneuverBitmap;
    private static volatile Navigator navigator;
    private static volatile boolean turnFeedRegistered;

    private YavoiCarState() {}

    static Runnable observe(Runnable observer) {
        observers.add(observer);
        return () -> observers.remove(observer);
    }

    static void removeObserver(Runnable observer) { observers.remove(observer); }

    static void changed() {
        Runnable notify = () -> { for (Runnable observer : observers) observer.run(); };
        if (Looper.myLooper() == Looper.getMainLooper()) notify.run(); else MAIN.post(notify);
    }

    static boolean isAutoConnected() { return autoConnected; }
    static void setAutoConnected(boolean connected) { autoConnected = connected; changed(); }

    static String tripId() { return tripId; }
    static String stage() { return stage; }
    static String passenger() { return passenger; }
    static String destination() { return destination; }
    static String pickup() { return pickup; }
    static String payment() { return payment; }
    static String total() { return total; }
    static String waiting() { return waiting; }
    static String adjustments() { return adjustments; }
    static String dynamic() { return dynamic; }
    static String fareError() { return fareError; }
    static boolean fareReady() { return fareReady; }
    static Offer offer() { return offer; }
    static int queuedTrips() { return queuedTrips; }
    static void setQueuedTrips(int count) { queuedTrips = Math.max(0, count); changed(); }
    static String road() { return road; }
    static String cue() { return cue; }
    static int maneuver() { return maneuver; }
    static Integer stepDistanceMeters() { return stepDistanceMeters; }
    static Integer destinationDistanceMeters() { return destinationDistanceMeters; }
    static Integer destinationSeconds() { return destinationSeconds; }
    static Bitmap maneuverBitmap() { return maneuverBitmap; }
    static Navigator navigator() { return navigator; }

    static void setTrip(Intent source) {
        tripId = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_TRIP_ID));
        stage = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_STAGE));
        if (stage.isEmpty()) stage = "pickup";
        passenger = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_PASSENGER_NAME));
        if (passenger.isEmpty() || passenger.equalsIgnoreCase("pasajero")) passenger = "tu pasajero";
        pickup = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_DESTINATION));
        destination = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_FINAL_DESTINATION));
        payment = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_PAYMENT_METHOD));
        if (payment.isEmpty()) payment = "cash";
        total = safe(source.getStringExtra(YavoiNavigationActivity.EXTRA_TOTAL));
        fareReady = false;
        fareError = "";
        road = ""; cue = ""; maneuver = 0; maneuverBitmap = null;
        stepDistanceMeters = destinationDistanceMeters = destinationSeconds = null;
        offer = null;
        changed();
    }

    static void setIdle() {
        Navigator currentNavigator = navigator;
        if (currentNavigator != null) {
            try { currentNavigator.stopGuidance(); } catch (RuntimeException ignored) { }
            try { currentNavigator.clearDestinations(); } catch (RuntimeException ignored) { }
        }
        tripId = ""; stage = "idle"; passenger = ""; destination = ""; pickup = ""; payment = "cash";
        total = ""; waiting = "$0.00"; adjustments = "$0.00"; dynamic = "$0.00";
        fareError = ""; fareReady = false; offer = null;
        road = ""; cue = ""; maneuver = 0; maneuverBitmap = null;
        stepDistanceMeters = destinationDistanceMeters = destinationSeconds = null;
        changed();
    }

    static void setStage(String nextStage) {
        stage = safe(nextStage);
        changed();
    }

    static void setOffer(String id, String summary, String route) {
        offer = new Offer(id, summary, route);
        changed();
    }

    static void clearOffer() { offer = null; changed(); }

    static void setFare(Intent command) {
        if (!tripId.equals(safe(command.getStringExtra(YavoiNavigationActivity.EXTRA_TRIP_ID)))) return;
        total = safe(command.getStringExtra(YavoiNavigationActivity.EXTRA_TOTAL));
        waiting = safeOr(command.getStringExtra("waiting"), "$0.00");
        adjustments = safeOr(command.getStringExtra("adjustments"), "$0.00");
        dynamic = safeOr(command.getStringExtra("dynamic"), "$0.00");
        fareError = safe(command.getStringExtra("error"));
        fareReady = !fareError.isEmpty() ? false : !total.isEmpty();
        changed();
    }

    static void setNavigator(Navigator readyNavigator, Context context) {
        navigator = readyNavigator;
        if (readyNavigator == null || turnFeedRegistered || context == null) return;
        try {
            NavigationUpdatesOptions options = NavigationUpdatesOptions.builder()
                    .setNumNextStepsToPreview(0)
                    .setGeneratedStepImagesType(NavigationUpdatesOptions.GeneratedStepImagesType.BITMAP)
                    .setDisplayMetrics(context.getResources().getDisplayMetrics())
                    .build();
            turnFeedRegistered = readyNavigator.registerServiceForNavUpdates(
                    context.getPackageName(), YavoiTurnByTurnService.class.getName(), options);
        } catch (Exception ignored) {
            turnFeedRegistered = false;
        }
        changed();
    }

    static void setNavInfo(NavInfo info) {
        if (info == null) {
            road = ""; cue = ""; maneuver = 0; maneuverBitmap = null;
            stepDistanceMeters = destinationDistanceMeters = destinationSeconds = null;
        } else {
            StepInfo current = info.getCurrentStep();
            road = current == null ? "" : safe(current.getFullRoadName());
            cue = current == null ? "" : safe(current.getFullInstructionText());
            maneuver = current == null ? 0 : current.getManeuver();
            maneuverBitmap = current == null ? null : current.getManeuverBitmap();
            stepDistanceMeters = info.getDistanceToCurrentStepMeters();
            destinationDistanceMeters = info.getDistanceToDestinationMeters();
            destinationSeconds = info.getTimeToDestinationSeconds();
        }
        changed();
    }

    static String passengerTripLabel() {
        String person = passenger.isEmpty() ? "tu pasajero" : passenger;
        if ("pickup".equals(stage)) return "Ver por " + person;
        if ("ready".equals(stage)) return person + " a bordo";
        if ("destination".equals(stage)) return "Llevamos a " + person;
        if ("collect".equals(stage)) return "Llegamos con " + person;
        if ("switching".equals(stage)) return "Preparando siguiente viaje";
        return "Yavoi! Drive · disponible";
    }

    static boolean hasActiveRoute() { return "pickup".equals(stage) || "destination".equals(stage); }

    private static String safe(String value) { return value == null ? "" : value.trim(); }
    private static String safeOr(String value, String fallback) { String clean = safe(value); return clean.isEmpty() ? fallback : clean; }
}
