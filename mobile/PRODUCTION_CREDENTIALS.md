# Credenciales de producción: Maps y notificaciones

La primera publicación usa efectivo directo entre pasajero y conductor. Operaciones conserva los cálculos comerciales y fiscales para el corte semanal; las aplicaciones no administran pagos, cuentas, saldos ni transferencias.

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

## Modelo de cobro vigente

Yavoi! opera con efectivo entregado directamente al conductor. La app calcula tarifa, ajustes, comisión e impuestos para fines de transparencia y conciliación, pero no integra ni requiere un proveedor de pagos, cuentas bancarias, transferencias, retiros o billeteras. No crear ni cargar credenciales de proveedores de pago para esta versión.

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
conciliación operativa y notificaciones. Los secretos se introducen desde los paneles de los proveedores que estén activos y nunca se copian a archivos del repositorio.
