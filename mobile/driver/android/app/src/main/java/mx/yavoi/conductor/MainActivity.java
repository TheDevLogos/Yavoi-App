package mx.yavoi.conductor;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(android.os.Bundle savedInstanceState) {
        // Capacitor consumes the initial plugin list while BridgeActivity starts.
        // Register local plugins before that bridge is created.
        registerPlugin(YavoiNavigationPlugin.class);
        registerPlugin(YavoiDevicePermissionsPlugin.class);
        registerPlugin(YavoiGoogleAuthPlugin.class);
        registerPlugin(YavoiReminderPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
