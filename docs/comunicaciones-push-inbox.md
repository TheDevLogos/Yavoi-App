# Comunicaciones desde Recompensas y Publicidad

Operaciones puede publicar mensajes en la Bandeja de Entrada de Yavoi!, Yavoi! Drive, ambas aplicaciones o una cuenta específica por correo. Puede adjuntar una imagen desde el almacenamiento de campañas Yavoi! y elegir entre Inbox o Inbox más push.

Los mensajes quedan en Supabase hasta su fecha de vencimiento y muestran un punto naranja en Inicio y Perfil mientras no se lean. Abrirlos en Inbox marca cada mensaje como leído. Las preferencias de push promocional son individuales; empiezan desactivadas y se guardan en Supabase. La autorización del sistema operativo se solicita mediante el botón del Perfil en ambas aplicaciones.

Los envíos push manuales se limitan a cuentas que aceptaron las comunicaciones promocionales y registraron el dispositivo. Los avisos operativos de viajes siguen en su flujo separado. El mensaje se guarda en una cola duradera y un trabajo programado cada minuto llama a `push-communications` con una credencial exclusiva en Supabase Vault. La función procesa audiencias en lotes y registra cuántas solicitudes aceptó FCM/Web Push o fallaron, aunque Operaciones cierre el navegador. La aceptación del proveedor no garantiza que el sistema operativo muestre el aviso. El mensaje de Inbox permite recuperarlo al volver a conectarse.

## Estado de implementación

- Migración `20261020194500_marketing_communications.sql` aplicada al proyecto Supabase Yavoi! el 20 de octubre de 2026.
- Edge Function `push-communications` versión 4 activa, con autorización propia de Operaciones/MFA o token de trabajador guardado en Vault.
- Migración `20261020201500_communications_background_dispatch.sql` aplicada; trabajo `yavoi-communications-every-minute` activo.
- Compilan los destinos web, Android pasajero y Android conductor; pasaron 108 pruebas locales.
- Los cambios de interfaz están en el repositorio local y todavía deben incluirse en el siguiente despliegue web y en los próximos paquetes móviles. No se publicó una versión nueva de Play Console en este cambio.

## Límites de plataforma

Un dispositivo sin conexión no puede recibir un push en ese instante. El mensaje de Inbox permanece guardado para cuando recupere conexión; Web Push usa vigencia de 24 horas para intentar su entrega. Las imágenes de notificaciones iOS necesitan una Notification Service Extension para mostrarse fuera de la app; el texto y la imagen en Inbox ya están preparados. Las imágenes push se limitan a 1 MB por compatibilidad con FCM.
