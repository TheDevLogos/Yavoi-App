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

## Renovar un `refresh_token` vencido o revocado

Antes de generar el reemplazo, abre **Google Auth Platform > Público** y cambia el estado de **Pruebas** a **En producción**. En una aplicación externa en pruebas, Google emite autorizaciones que vencen a los siete días. La cuenta propietaria del proyecto puede ser `alonsovl.logos@gmail.com`; `admin.yavoi@gmail.com` debe permanecer como usuario autorizado, correo de soporte y contacto de desarrollador.

1. En **Clientes > Yavoi Recibos**, confirma que el cliente sea de tipo aplicación web y que su URI de redirección sea exactamente `https://developers.google.com/oauthplayground`.
2. Desde la cuenta `admin.yavoi@gmail.com`, abre las conexiones de la cuenta de Google y elimina el acceso anterior de **Yavoi Recibos** para forzar un consentimiento nuevo.
3. En OAuth Playground abre la configuración y selecciona **Server-side**, **Offline**, **Consent Screen** y **Use your own OAuth credentials**.
4. Escribe el ID y secreto del mismo cliente **Yavoi Recibos**, autoriza únicamente `https://www.googleapis.com/auth/gmail.send` e intercambia el código.
5. Pulsa **Refresh access token** antes de guardar nada. Sólo si la prueba funciona, copia el nuevo `refresh_token`.
6. En **Supabase > Edge Functions > Secrets**, sustituye `GMAIL_REFRESH_TOKEN`. Confirma también que `GMAIL_CLIENT_ID` y `GMAIL_CLIENT_SECRET` pertenecen al mismo cliente que emitió el token.
7. No es necesario desplegar nuevamente la función; los secretos actualizados se aplican directamente. Regresa a Operaciones y reintenta el recibo pendiente.

Nunca guardes estos valores en Git, documentos compartidos, capturas ni conversaciones.
