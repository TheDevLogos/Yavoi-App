package mx.yavoi.pasajero;

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
        "Revisa las novedades y herramientas de Yavoi!.",
        "Confirma el precio antes de solicitar.",
        "Consulta el detalle de cada viaje para mayor transparencia.",
        "Activa las alertas para recibir actualizaciones.",
        "Comparte tu viaje y usa las herramientas de seguridad.",
        "Tus puntos y promociones están disponibles en Recompensas.",
        "Guarda tus destinos frecuentes para pedir tu viaje más rápido.",
        "Revisa la unidad y al conductor antes de iniciar el viaje.",
        "La tarifa final muestra claramente cada ajuste aceptado.",
        "Consulta las políticas de seguridad desde tu perfil cuando lo necesites."
    };

    @Override public void onReceive(Context context, Intent ignored) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "Novedades y consejos Yavoi!", NotificationManager.IMPORTANCE_DEFAULT);
            channel.setDescription("Promociones, novedades, recomendaciones y consejos de seguridad de Yavoi!");
            manager.createNotificationChannel(channel);
        }
        Intent open = new Intent(context, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pending = PendingIntent.getActivity(context, 8004, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        String tip = TIPS[(int) ((System.currentTimeMillis() / (4L * 60L * 60L * 1000L)) % TIPS.length)];
        manager.notify(8004, new NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_yavoi)
            .setContentTitle("Yavoi! · novedades y consejos")
            .setContentText(tip)
            .setStyle(new NotificationCompat.BigTextStyle().bigText(tip))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build());
    }
}
