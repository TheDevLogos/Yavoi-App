package mx.yavoi.pasajero;
import android.app.*; import android.content.*; import android.os.SystemClock; import com.getcapacitor.*; import com.getcapacitor.annotation.*;
@CapacitorPlugin(name="YavoiReminder") public class YavoiReminderPlugin extends Plugin {
 @PluginMethod public void schedule(PluginCall call){AlarmManager a=(AlarmManager)getContext().getSystemService(AlarmManager.class); PendingIntent p=PendingIntent.getBroadcast(getContext(),8004,new Intent(getContext(),YavoiReminderReceiver.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE); long i=4L*60L*60L*1000L; a.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP,SystemClock.elapsedRealtime()+i,i,p);call.resolve();}
 @PluginMethod public void cancel(PluginCall call){AlarmManager a=(AlarmManager)getContext().getSystemService(AlarmManager.class);PendingIntent p=PendingIntent.getBroadcast(getContext(),8004,new Intent(getContext(),YavoiReminderReceiver.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);a.cancel(p);p.cancel();call.resolve();}
}
