package mx.yavoi.conductor;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.os.SystemClock;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.PluginMethod;

@CapacitorPlugin(name = "YavoiReminder")
public class YavoiReminderPlugin extends Plugin {
    private static final int REQUEST_CODE = 8004;
    @PluginMethod public void schedule(PluginCall call) {
        AlarmManager alarms = (AlarmManager) getContext().getSystemService(AlarmManager.class);
        Intent intent = new Intent(getContext(), YavoiReminderReceiver.class);
        PendingIntent pending = PendingIntent.getBroadcast(getContext(), REQUEST_CODE, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        long interval = 4L * 60L * 60L * 1000L;
        alarms.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + interval, interval, pending);
        call.resolve();
    }
    @PluginMethod public void cancel(PluginCall call) {
        AlarmManager alarms = (AlarmManager) getContext().getSystemService(AlarmManager.class);
        Intent intent = new Intent(getContext(), YavoiReminderReceiver.class);
        PendingIntent pending = PendingIntent.getBroadcast(getContext(), REQUEST_CODE, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        alarms.cancel(pending); pending.cancel(); call.resolve();
    }
}
