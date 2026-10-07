# Credenciales de producción: Maps, pagos y notificaciones

La primera publicación se prepara en modo piloto de efectivo. Los cobros con
tarjeta y los retiros iniciados por conductores permanecen desactivados. Las
liquidaciones excepcionales de saldo a favor se concilian y documentan a mano
por Operaciones cada semana; el efectivo del viaje lo recibe directamente el
conductor. No activar funciones de pago electrónico antes de cerrar sus pruebas.

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
   `APP_ORIGINS` sólo para la fase posterior de pagos electrónicos. No configurar
   ni activar retiros automatizados para la publicación piloto.
4. Mantener `mercado_pago_enabled=false` durante el piloto. Antes de una versión
   posterior, probar cobro, webhook firmado, rechazo, reembolso, propina y ajuste.
5. Activar la clave pública y el interruptor sólo con un cambio separado,
   revisado y documentado en `docs/mercado-pago.md`; confirmar que la llave
   pública y el Access Token pertenecen al mismo entorno.

## Firebase Cloud Messaging

1. Habilitar Firebase Cloud Messaging API en el proyecto `yavoi-4a7af`.
2. Crear una cuenta de servicio limitada para FCM y guardar su JSON completo
   sólo como secreto `FIREBASE_SERVICE_ACCOUNT_JSON` en Supabase.
3. No subir el JSON a Git, a Vercel ni a los paquetes móviles.
4. Instalar la versión interna en un Android físico, conceder notificaciones,
   registrar el token y comprobar una oferta que venza en ocho segundos.
5. Probar el mismo flujo en iPhone después de configurar APNs.

## Comprobación antes de activar cada proveedor

Para el piloto, documentar cotización, viaje pagado en efectivo, recibo,
conciliación operativa y notificaciones. Antes de habilitar tarjeta en una
versión futura, adjuntar casos fechados de pago aprobado, rechazo, reembolso y
recuperación. Los secretos se introducen desde los paneles de cada proveedor y
nunca se copian a archivos del repositorio.
