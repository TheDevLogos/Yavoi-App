package mx.yavoi.conductor;

import android.app.Service;
import android.content.Intent;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.Process;

import androidx.annotation.Nullable;

import com.google.android.libraries.mapsplatform.turnbyturn.TurnByTurnManager;

public class YavoiTurnByTurnService extends Service {
    private TurnByTurnManager manager;
    private HandlerThread thread;
    private Messenger incomingMessenger;

    private final class NavigationMessageHandler extends Handler {
        NavigationMessageHandler(Looper looper) { super(looper); }
        @Override public void handleMessage(Message message) {
            if (manager != null && message.what == TurnByTurnManager.MSG_NAV_INFO) {
                YavoiCarState.setNavInfo(manager.readNavInfoFromBundle(message.getData()));
            }
        }
    }

    @Override public void onCreate() {
        super.onCreate();
        manager = TurnByTurnManager.createInstance();
        thread = new HandlerThread("YavoiTurnByTurn", Process.THREAD_PRIORITY_DEFAULT);
        thread.start();
        incomingMessenger = new Messenger(new NavigationMessageHandler(thread.getLooper()));
    }

    @Nullable @Override public IBinder onBind(Intent intent) {
        return incomingMessenger == null ? null : incomingMessenger.getBinder();
    }

    @Override public void onDestroy() {
        if (thread != null) thread.quitSafely();
        super.onDestroy();
    }
}
