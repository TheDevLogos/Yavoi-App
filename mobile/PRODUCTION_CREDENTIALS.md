# Credenciales de producción: Maps, pagos y notificaciones

Las aplicaciones se mantienen en modo seguro mientras falten las credenciales.
No se deben activar cobros, retiros ni notificaciones nativas hasta concluir
la prueba correspondiente.

## Google Maps Platform

1. Crear una clave de navegador para `VITE_GOOGLE_MAPS_BROWSER_KEY`.
2. Restringirla por referentes HTTPS a los dominios reales de Yavoi!, incluida
   `https://yavoi-app.vercel.app/*` mientras se usa ese dominio.
3. Restringir las APIs a Maps JavaScript API y las necesarias en navegador.
4. Crear una clave de servidor distinta para el secreto de Supabase
   `GOOGLE_MAPS_API_KEY`; restringirla por API a Places API (New), Geocoding
   API y Routes API, y no exponerla en Vite ni en las apps.
5. Aplicar cuotas, alertas de presupuesto y límites de uso en Google Cloud.
6. Probar: autocompletado de dirección, detalle de lugar, geocodificación
   inversa, ruta y cotización en Delicias antes de retirar el respaldo actual.

## Mercado Pago

1. Crear la aplicación de producción en la cuenta empresarial de Yavoi!.
2. Configurar el webhook a `https://asjlyureqokifjkpdwgc.supabase.co/functions/v1/mercado-pago-webhook`.
3. Registrar en secretos de Supabase `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET` y
   `APP_ORIGINS`. Para retiros automatizados, agregar únicamente después de la
   aprobación de Mercado Pago `MP_PAYOUT_SIGNING_PRIVATE_KEY` y
   `MP_PAYOUTS_ENABLED=true`.
4. Mantener `mercado_pago_enabled=false` hasta confirmar con pagos de prueba:
   cobro, webhook firmado, rechazo, reembolso, propina y ajuste posterior.
5. Activar la clave pública y el interruptor mediante el cambio controlado
   documentado en `docs/mercado-pago.md`. Confirmar primero que la llave
   pública pertenece al mismo entorno que el Access Token.

## Firebase Cloud Messaging

1. Habilitar Firebase Cloud Messaging API en el proyecto `yavoi-4a7af`.
2. Crear una cuenta de servicio limitada para FCM y guardar su JSON completo
   sólo como secreto `FIREBASE_SERVICE_ACCOUNT_JSON` en Supabase.
3. No subir el JSON a Git, a Vercel ni a los paquetes móviles.
4. Instalar la versión interna en un Android físico, conceder notificaciones,
   registrar el token y comprobar una oferta que venza en ocho segundos.
5. Probar el mismo flujo en iPhone después de configurar APNs.

## Comprobación antes de activar cada proveedor

La evidencia mínima es un caso de prueba fechado con resultado para éxito,
rechazo y recuperación: Maps sin resultado; pago rechazado y reembolso;
notificación sin permiso, en segundo plano y al abrirla. Los secretos se
introducen desde los paneles de cada proveedor y nunca se copian a archivos del
repositorio.
