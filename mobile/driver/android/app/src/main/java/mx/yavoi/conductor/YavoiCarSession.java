package mx.yavoi.conductor;

import android.content.Intent;

import androidx.annotation.NonNull;
import androidx.car.app.Screen;
import androidx.car.app.Session;
import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.LifecycleOwner;

public class YavoiCarSession extends Session {
    private YavoiCarNavigationScreen screen;

    public YavoiCarSession() {
        getLifecycle().addObserver(new DefaultLifecycleObserver() {
            @Override public void onStart(@NonNull LifecycleOwner owner) { YavoiCarState.setAutoConnected(true); }
            @Override public void onStop(@NonNull LifecycleOwner owner) { YavoiCarState.setAutoConnected(false); }
            @Override public void onDestroy(@NonNull LifecycleOwner owner) {
                YavoiCarState.setAutoConnected(false);
                if (screen != null) screen.release();
                screen = null;
            }
        });
    }

    @NonNull
    @Override
    public Screen onCreateScreen(@NonNull Intent intent) {
        screen = new YavoiCarNavigationScreen(getCarContext());
        return screen;
    }
}
