package mx.yavoi.conductor;

import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;

import androidx.core.content.ContextCompat;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.PluginMethod;

/** Bridge between the shared Yavoi! portal and the Android Navigation SDK view. */
@CapacitorPlugin(name = "YavoiNavigation")
public class YavoiNavigationPlugin extends Plugin {
    private void putTrip(Intent intent, PluginCall call) {
        intent.putExtra(YavoiNavigationActivity.EXTRA_TRIP_ID, call.getString("tripId", ""));
        intent.putExtra(YavoiNavigationActivity.EXTRA_STAGE, call.getString("stage", "pickup"));
        intent.putExtra(YavoiNavigationActivity.EXTRA_DESTINATION, call.getString("destination", ""));
        intent.putExtra(YavoiNavigationActivity.EXTRA_FINAL_DESTINATION, call.getString("finalDestination", ""));
        intent.putExtra(YavoiNavigationActivity.EXTRA_PASSENGER_NAME, call.getString("passengerName", "Pasajero"));
        intent.putExtra(YavoiNavigationActivity.EXTRA_PAYMENT_METHOD, call.getString("paymentMethod", "cash"));
        Double lat = call.getDouble("lat"); Double lng = call.getDouble("lng");
        if (lat != null) intent.putExtra(YavoiNavigationActivity.EXTRA_LAT, lat.doubleValue());
        if (lng != null) intent.putExtra(YavoiNavigationActivity.EXTRA_LNG, lng.doubleValue());
        Double finalLat = call.getDouble("finalLat"); Double finalLng = call.getDouble("finalLng");
        if (finalLat != null) intent.putExtra(YavoiNavigationActivity.EXTRA_FINAL_LAT, finalLat.doubleValue());
        if (finalLng != null) intent.putExtra(YavoiNavigationActivity.EXTRA_FINAL_LNG, finalLng.doubleValue());
        intent.putExtra(YavoiNavigationActivity.EXTRA_TOTAL, call.getString("total", ""));
    }
    private final BroadcastReceiver navigationEvents = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            JSObject payload = new JSObject();
            payload.put("action", intent.getStringExtra(YavoiNavigationActivity.EXTRA_EVENT));
            payload.put("tripId", intent.getStringExtra(YavoiNavigationActivity.EXTRA_TRIP_ID));
            payload.put("offerId", intent.getStringExtra(YavoiNavigationActivity.EXTRA_OFFER_ID));
            notifyListeners("event", payload);
        }
    };

    @Override public void load() {
        ContextCompat.registerReceiver(getContext(), navigationEvents,
                new IntentFilter(YavoiNavigationActivity.ACTION_EVENT), ContextCompat.RECEIVER_NOT_EXPORTED);
    }
    @Override protected void handleOnDestroy() { getContext().unregisterReceiver(navigationEvents); }
    @PluginMethod
    public void start(PluginCall call) {
        Double lat = call.getDouble("lat");
        Double lng = call.getDouble("lng");
        if (lat == null || lng == null) {
            call.reject("El destino requiere coordenadas para iniciar la navegación.");
            return;
        }

        Intent intent = new Intent(getActivity(), YavoiNavigationActivity.class);
        putTrip(intent, call);
        getActivity().startActivity(intent);
        JSObject response = new JSObject(); response.put("started", true); call.resolve(response);
    }

    @PluginMethod public void showOffer(PluginCall call) {
        Intent command = new Intent(YavoiNavigationActivity.ACTION_COMMAND);
        command.setPackage(getContext().getPackageName());
        command.putExtra(YavoiNavigationActivity.EXTRA_OFFER_ID, call.getString("offerId", ""));
        command.putExtra("summary", call.getString("summary", ""));
        command.putExtra("route", call.getString("route", ""));
        getContext().sendBroadcast(command); call.resolve();
    }

    @PluginMethod public void nextTrip(PluginCall call) {
        Intent command = new Intent(YavoiNavigationActivity.ACTION_COMMAND);
        command.setPackage(getContext().getPackageName());
        command.putExtra(YavoiNavigationActivity.EXTRA_COMMAND, "next_trip");
        putTrip(command, call);
        getContext().sendBroadcast(command); call.resolve();
    }

    @PluginMethod public void updateFare(PluginCall call) {
        Intent command = new Intent(YavoiNavigationActivity.ACTION_COMMAND);
        command.setPackage(getContext().getPackageName());
        command.putExtra(YavoiNavigationActivity.EXTRA_COMMAND, "update_fare");
        command.putExtra(YavoiNavigationActivity.EXTRA_TRIP_ID, call.getString("tripId", ""));
        command.putExtra(YavoiNavigationActivity.EXTRA_TOTAL, call.getString("total", ""));
        command.putExtra("waiting", call.getString("waiting", "$0.00"));
        command.putExtra("adjustments", call.getString("adjustments", "$0.00"));
        command.putExtra("dynamic", call.getString("dynamic", "$0.00"));
        command.putExtra("error", call.getString("error", ""));
        getContext().sendBroadcast(command); call.resolve();
    }

    @PluginMethod public void transitionFailed(PluginCall call) {
        Intent command = new Intent(YavoiNavigationActivity.ACTION_COMMAND);
        command.setPackage(getContext().getPackageName());
        command.putExtra(YavoiNavigationActivity.EXTRA_COMMAND, "transition_failed");
        command.putExtra(YavoiNavigationActivity.EXTRA_TRIP_ID, call.getString("tripId", ""));
        command.putExtra(YavoiNavigationActivity.EXTRA_EVENT, call.getString("action", ""));
        command.putExtra("message", call.getString("message", "No se pudo actualizar el viaje."));
        getContext().sendBroadcast(command); call.resolve();
    }

    @PluginMethod public void close(PluginCall call) {
        Intent command = new Intent(YavoiNavigationActivity.ACTION_COMMAND);
        command.setPackage(getContext().getPackageName());
        command.putExtra(YavoiNavigationActivity.EXTRA_COMMAND, "close");
        getContext().sendBroadcast(command); call.resolve();
    }

}
