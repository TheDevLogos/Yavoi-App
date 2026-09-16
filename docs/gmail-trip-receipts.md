# Recibos de viaje por Gmail

Yavoi! prepara y envía un recibo al correo del pasajero cuando el conductor finaliza el viaje. El envío usa la API oficial de Gmail por HTTPS y la cuenta `admin.yavoi@gmail.com`. No usa SMTP, contraseñas normales ni credenciales guardadas en el repositorio.

## Contenido del recibo

Cada recibo contiene y valida estos datos antes del envío:

1. Fecha del viaje.
2. Precio total cobrado al usuario.
3. Tiempo total y kilómetros recorridos.
4. Punto de inicio y destino.
5. Hora de inicio y finalización.
6. Nombre y fotografía protegida del conductor.

Si falta el correo del pasajero, el conductor o su fotografía, el recibo queda marcado como fallido y Operaciones puede corregir el expediente y reintentarlo. Los kilómetros indican si provienen del GPS o de la ruta resguardada cuando no hubo una traza GPS válida.

## Configuración privada de Google

Conviene crear un cliente OAuth independiente llamado **Yavoi Recibos** para no mezclar el envío con el acceso de usuarios.

1. En Google Cloud Console, abre el proyecto de Yavoi! y habilita **Gmail API**.
2. Configura la pantalla de consentimiento. Mientras la aplicación esté en pruebas, agrega `admin.yavoi@gmail.com` como usuario de prueba.
3. Crea un cliente OAuth 2.0 de tipo **Aplicación web**.
4. Agrega `https://developers.google.com/oauthplayground` como URI de redirección autorizada.
5. En OAuth 2.0 Playground, activa **Use your own OAuth credentials**, escribe el ID y secreto del cliente, autoriza el alcance `https://www.googleapis.com/auth/gmail.send` con `admin.yavoi@gmail.com` e intercambia el código por un `refresh_token`.
6. En Supabase, abre **Project Settings > Edge Functions > Secrets** y crea:

   - `GMAIL_CLIENT_ID`
   - `GMAIL_CLIENT_SECRET`
   - `GMAIL_REFRESH_TOKEN`
   - `GMAIL_SENDER_EMAIL` con el valor `admin.yavoi@gmail.com`
   - `RECEIPT_CRON_TOKEN` con un valor aleatorio largo para el procesamiento periódico

Nunca pegues el secreto del cliente ni el `refresh_token` en el repositorio, una conversación, una captura o código del navegador.

## Activación y prueba

1. En Yavoi!, entra a **Operaciones > Auditoría y cumplimiento**.
2. Activa **Enviar recibos por correo** cuando los secretos ya estén cargados.
3. Finaliza un viaje de prueba con un pasajero que tenga correo confirmado y un conductor cuyo expediente incluya nombre y fotografía.
4. Verifica que el recibo cambie de **Pendiente** a **Enviado**. Operaciones también puede pulsar **Enviar por correo** para reintentar un recibo.

La cola es idempotente: un viaje conserva un solo recibo, usa arrendamientos para impedir envíos simultáneos y guarda el identificador devuelto por Gmail. Los fallos temporales aplican reintentos con espera creciente y no bloquean la finalización del viaje.
