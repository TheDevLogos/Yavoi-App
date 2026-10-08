package mx.yavoi.conductor;

import android.app.Activity;
import android.content.Intent;

import androidx.activity.result.ActivityResult;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.PluginMethod;

/** Bridge between the shared Yavoi! portal and the Android Navigation SDK view. */
@CapacitorPlugin(name = "YavoiNavigation")
public class YavoiNavigationPlugin extends Plugin {
    @PluginMethod
    public void start(PluginCall call) {
        Double lat = call.getDouble("lat");
        Double lng = call.getDouble("lng");
        if (lat == null || lng == null) {
            call.reject("El destino requiere coordenadas para iniciar la navegación.");
            return;
        }

        Intent intent = new Intent(getActivity(), YavoiNavigationActivity.class);
        intent.putExtra(YavoiNavigationActivity.EXTRA_TRIP_ID, call.getString("tripId", ""));
        intent.putExtra(YavoiNavigationActivity.EXTRA_STAGE, call.getString("stage", "pickup"));
        intent.putExtra(YavoiNavigationActivity.EXTRA_DESTINATION, call.getString("destination", ""));
        intent.putExtra(YavoiNavigationActivity.EXTRA_PAYMENT_METHOD, call.getString("paymentMethod", "cash"));
        intent.putExtra(YavoiNavigationActivity.EXTRA_LAT, lat);
        intent.putExtra(YavoiNavigationActivity.EXTRA_LNG, lng);
        startActivityForResult(call, intent, "navigationFinished");
    }

    @ActivityCallback
    private void navigationFinished(PluginCall call, ActivityResult result) {
        JSObject response = new JSObject();
        if (result.getResultCode() == Activity.RESULT_OK && result.getData() != null) {
            response.put("action", result.getData().getStringExtra(YavoiNavigationActivity.RESULT_ACTION));
            response.put("arrived", result.getData().getBooleanExtra(YavoiNavigationActivity.RESULT_ARRIVED, false));
        }
        call.resolve(response);
    }
}
