package mx.yavoi.conductor;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.activity.result.ActivityResult;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.PluginMethod;

/** Requests the optional Android alert-window permission only after the driver opts in. */
@CapacitorPlugin(name = "YavoiDevicePermissions")
public class YavoiDevicePermissionsPlugin extends Plugin {
    @PluginMethod
    public void overlayStatus(PluginCall call) {
        JSObject result = new JSObject();
        result.put("granted", Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(getContext()));
        call.resolve(result);
    }

    @PluginMethod
    public void requestOverlay(PluginCall call) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(getContext())) {
            JSObject result = new JSObject();
            result.put("granted", true);
            call.resolve(result);
            return;
        }
        Intent intent = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + getContext().getPackageName()));
        startActivityForResult(call, intent, "overlayPermissionResult");
    }

    @ActivityCallback
    private void overlayPermissionResult(PluginCall call, ActivityResult ignored) {
        JSObject result = new JSObject();
        result.put("granted", Settings.canDrawOverlays(getContext()));
        call.resolve(result);
    }
}
