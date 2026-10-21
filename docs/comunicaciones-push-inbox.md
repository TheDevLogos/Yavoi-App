# Comunicaciones desde Recompensas y Publicidad

Operaciones puede publicar mensajes en la Bandeja de Entrada de Yavoi!, Yavoi! Drive, ambas aplicaciones o una cuenta específica por correo. Puede adjuntar una imagen desde el almacenamiento de campañas Yavoi! y elegir entre Inbox o Inbox más push.

Los mensajes quedan en Supabase hasta su fecha de vencimiento y muestran un punto naranja en Inicio y Perfil mientras no se lean. Abrirlos en Inbox marca cada mensaje como leído. Las preferencias de push promocional son individuales; empiezan desactivadas y se guardan en Supabase. La autorización del sistema operativo se solicita mediante el botón del Perfil en ambas aplicaciones.

Los envíos push manuales se limitan a cuentas que aceptaron las comunicaciones promocionales y registraron el dispositivo. Los avisos operativos de viajes siguen en su flujo separado. El mensaje se guarda en una cola duradera y un trabajo programado cada minuto llama a `push-communications` con una credencial exclusiva en Supabase Vault. La función procesa audiencias en lotes y registra cuántas solicitudes aceptó FCM/Web Push o fallaron, aunque Operaciones cierre el navegador. La aceptación del proveedor no garantiza que el sistema operativo muestre el aviso. El mensaje de Inbox permite recuperarlo al volver a conectarse.

## Estado de implementación

- Migración `20261020194500_marketing_communications.sql` aplicada al proyecto Supabase Yavoi! el 20 de octubre de 2026.
- Edge Function `push-communications` versión 4 activa, con autorización propia de Operaciones/MFA o token de trabajador guardado en Vault.
- Migración `20261020201500_communications_background_dispatch.sql` aplicada; trabajo `yavoi-communications-every-minute` activo.
- Compilan los destinos web, Android pasajero y Android conductor; pasaron 109 pruebas locales.
- El PWA se desplegó desde `main` (`10c4775`) a `yavoi-app.vercel.app` el 20 de octubre de 2026.
- Yavoi! 1.0.17 (código 18) y Yavoi! Drive 1.0.21 (código 22) incluyen el registro automático de un dispositivo que ya concedió permiso al reabrir la app.

## Comprobación en teléfono

1. Instala la versión interna de cada aplicación, entra con el perfil correspondiente y en Mi perfil activa las notificaciones del dispositivo y la preferencia opcional de promociones.
2. Cierra la aplicación y, desde Operaciones, envía un mensaje `Push + Inbox` dirigido al correo de esa cuenta. La cola lo procesará en el siguiente minuto; consulta en el historial si FCM aceptó el envío.
3. Comprueba que el aviso aparezca fuera de la app, tócalo y confirma que abra la Bandeja de Entrada. Repite con la app en segundo plano y tras reiniciar el teléfono. Marca el mensaje como leído y verifica que desaparezca el punto naranja.

La verificación con pantalla apagada requiere un teléfono real con permiso y suscripción vigentes. Al 20 de octubre había 0 cuentas con promociones aceptadas, 0 tokens nativos de pasajeros, 7 tokens nativos de Drive y 4 suscripciones web; por ello todavía no hay evidencia de entrega visible en un dispositivo para estas campañas nuevas.

## Límites de plataforma

Un dispositivo sin conexión no puede recibir un push en ese instante. El mensaje de Inbox permanece guardado para cuando recupere conexión; Web Push usa vigencia de 24 horas para intentar su entrega. Las imágenes de notificaciones iOS necesitan una Notification Service Extension para mostrarse fuera de la app; el texto y la imagen en Inbox ya están preparados. Las imágenes push se limitan a 1 MB por compatibilidad con FCM.
