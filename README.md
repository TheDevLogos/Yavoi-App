# Yavoi! — plataforma web de movilidad

Aplicación web responsiva para pasajeros, conductores y el equipo de Operaciones de Yavoi! en Delicias, Chihuahua y su región.

## Experiencia disponible

- Acceso único con correo verificado, recuperación de contraseña, sesión persistente y botón oficial de Google preparado con Google Identity Services.
- Alta de pasajero o conductor; el rol de Operaciones no puede elegirse durante el registro.
- Paneles y rutas separados por rol, con validación adicional en PostgreSQL.
- Perfil de pasajero, expediente privado de conductor con avance de 16 requisitos y revisión reforzada por Operaciones.
- PWA instalable en Android y iOS, con iconos Yavoi!, modo independiente y recuperación de la interfaz sin conexión.
- Cotización en servidor por categoría, kilómetros estimados, duración y zona.
- Unidades compatibles en mapa, selección opcional y oferta automática a la unidad más cercana; el conductor acepta o rechaza después de revisar la solicitud.
- Avisos de nuevas solicitudes, disponibilidad voluntaria y presencia GPS renovada mientras el portal del conductor permanece abierto.
- Ficha previa del pasajero con fotografía, calificación, número de personas y peticiones de espacio o servicio.
- Zonas central, urbana y regional; Meoqui se clasifica como servicio regional.
- Preferencia de conductora verificada y unidad con accesibilidad verificada.
- Efectivo con cambio y Checkout Bricks de Mercado Pago listo para activar con credenciales reales.
- Propina voluntaria antes o después del viaje, conciliada por método de pago.
- Solicitud y cobro idempotentes, PIN de inicio, ubicación, trayectoria, chat y estados del viaje.
- Cierre con confirmación de efectivo, recibo, valoración mutua, propina, recompensas y quejas.
- Centro de Operaciones con mapa de flotilla en vivo, trayectorias GPS, expedientes, viajes, conciliación de efectivo o tarjeta, reembolsos, cuotas semanales, reportes, tarifas y auditoría.
- Recuperación del viaje y del plan de solicitud desde Supabase después de recargar, cerrar o volver a abrir el navegador.
- Exportación CSV segura para análisis operativo.

## Seguridad

Supabase Auth usa PKCE y correo verificado. Los permisos se obtienen del perfil almacenado en la base, nunca de metadatos modificables por el usuario. Todas las tablas expuestas tienen Row Level Security; las operaciones sensibles pasan por funciones del servidor con control de rol, estado del viaje, vigencias, límites de frecuencia y MFA AAL2 para Operaciones.

La primera cuenta de Operaciones está reservada para `admin.yavoi@gmail.com`. El correo debe verificarse y la cuenta debe configurar autenticación de dos pasos antes de usar el panel administrativo.

Las fotografías y documentos se guardan en depósitos privados y se consultan mediante enlaces temporales. La clave incluida en el cliente es la clave publicable de Supabase; no se utiliza ninguna clave de servicio en el navegador.

La presencia de un conductor vence a los 90 segundos sin señal. Esto impide nuevas asignaciones si el navegador se cierra, pierde conexión o el sistema operativo suspende la página; al regresar, la sesión y el rastreo se recuperan automáticamente.

## Estimador de tarifa

La tarifa se calcula en PostgreSQL y se conserva en la cotización durante cinco minutos. Usa inicio del servicio, kilómetros estimados, minutos estimados, tarifa mínima, zona y accesibilidad. No cobra reservación. La recogida lejana sólo se agrega cuando el pasajero elige una unidad ubicada a más de 7 km, y se cobra únicamente el excedente. La asignación automática sigue priorizando la unidad compatible más cercana.

La búsqueda de calles y lugares usa un servicio protegido del backend con caché. El mapa traza la ruta vial y el servidor conserva su propio cálculo de tarifa para impedir que un cliente altere el precio.

## Desarrollo y validación

```bash
npm ci
npm test
npm run dev
npm run build
```

Las migraciones versionadas están en `supabase/migrations`. La integración continua repite pruebas y compilación en cada cambio.

## Configuración de producción

1. Aplicar las migraciones de Supabase en orden.
2. Configurar la URL pública en Supabase Auth y permitir `/portal.html` como URL de confirmación y recuperación.
3. Publicar el resultado de `npm run build` con HTTPS.
4. Registrar y verificar `admin.yavoi@gmail.com`, y después activar MFA.
5. Aprobar conductores únicamente después de completar los 16 requisitos, incluidos los cinco documentos privados y sus vigencias.
6. Completar la guía [Activar Mercado Pago](docs/mercado-pago.md). La tarjeta permanece bloqueada hasta terminar esos pasos.
7. Completar la guía [Activar Google](docs/oauth-providers.md). El Client ID público ya está integrado; falta guardar el Client Secret sólo en Supabase y habilitar el proveedor.

Diseño y desarrollo: **TheDevLogos Creación Inteligente**.
