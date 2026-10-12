package mx.yavoi.conductor;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import androidx.core.app.NotificationCompat;

public class YavoiReminderReceiver extends BroadcastReceiver {
    public static final String CHANNEL_ID = "yavoi_tips";
    private static final String[] TIPS = {
        "Revisa tus herramientas y mantén tus alertas activas.",
        "Confirma el importe antes de iniciar cada viaje.",
        "La seguridad y la transparencia acompañan cada recorrido.",
        "Puedes consultar tus viajes y sus detalles en cualquier momento.",
        "Mantén actualizada tu ubicación para recibir solicitudes compatibles."
    };

    @Override public void onReceive(Context context, Intent ignored) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "Novedades y consejos Yavoi! Drive", NotificationManager.IMPORTANCE_DEFAULT);
            channel.setDescription("Consejos y novedades informativas de Yavoi! Drive");
            manager.createNotificationChannel(channel);
        }
        Intent open = new Intent(context, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pending = PendingIntent.getActivity(context, 8004, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        String tip = TIPS[(int) ((System.currentTimeMillis() / (4L * 60L * 60L * 1000L)) % TIPS.length)];
        NotificationCompat.Builder notification = new NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_yavoi)
            .setContentTitle("Yavoi! Drive")
            .setContentText(tip)
            .setStyle(new NotificationCompat.BigTextStyle().bigText(tip))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT);
        manager.notify(8004, notification.build());
    }
}
