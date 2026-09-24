# Yavoi! — plataforma web de movilidad

Aplicación web responsiva para pasajeros, conductores y el equipo de Operaciones de Yavoi! en Delicias, Chihuahua y su región.

## Experiencia disponible

- Acceso único con correo verificado, recuperación de contraseña, sesión persistente y botón oficial de Google preparado con Google Identity Services.
- Alta de pasajero o conductor; el rol de Operaciones no puede elegirse durante el registro.
- Paneles y rutas separados por rol, con validación adicional en PostgreSQL.
- Perfil de pasajero y expediente privado del conductor con identidad, autorización, vehículo, vigencias y equipo de seguridad; revisión reforzada por Operaciones.
- PWA instalable en Android y iOS, con iconos Yavoi!, modo independiente y recuperación de la interfaz sin conexión.
- Cotización en servidor por categoría, kilómetros estimados, duración y zona.
- Unidades compatibles en mapa, selección opcional y oferta automática a la unidad más cercana; el conductor acepta o rechaza después de revisar la solicitud.
- Avisos de nuevas solicitudes, disponibilidad voluntaria y presencia GPS renovada mientras el portal del conductor permanece abierto.
- Ayuda y seguridad integrada en Conducir, con reporte asociado al viaje y acceso directo a Emergencias 911 durante un servicio activo.
- Ficha previa del pasajero con fotografía, calificación, número de personas y peticiones de espacio o servicio.
- Zonas central, urbana y regional; Meoqui se clasifica como servicio regional.
- Preferencia de conductora verificada y unidad con accesibilidad verificada.
- Efectivo con cambio y Checkout Bricks de Mercado Pago listo para activar con credenciales reales.
- Propina voluntaria antes o después del viaje, conciliada por método de pago.
- Puntos Viajeros para pasajeros y Rating Yavoi! para conductores: niveles, historial, catálogo escalable, canjes, beneficios aplicables al viaje y promociones al entrar.
- Viaje local Básico gratis acumulable cada 15 viajes; descuentos y amenidades se eligen antes de confirmar y quedan visibles en precio, viaje y recibo.
- Operaciones consulta puntos, nivel, viajes, ingresos, rating e incidentes por conductor, y registra la entrega o cancelación de beneficios físicos con auditoría y devolución automática de puntos.
- Solicitud y cobro idempotentes, PIN de inicio, ubicación, trayectoria, chat y estados del viaje.
- Cierre con confirmación de efectivo, recibo legal enviado por correo mediante Gmail, valoración mutua, propina, recompensas y quejas.
- Centro de Operaciones con mapa de flotilla en vivo, trayectorias GPS, expedientes, viajes, conciliación de efectivo o tarjeta, reembolsos, cuotas semanales, reportes, tarifas y auditoría.
- Auditoría simplificada con responsable, persona o viaje afectado, filtros por área y búsqueda, además de detalle colapsable en lenguaje claro.
- Informes operativos por día, semana, mes, año o rango personalizado: viajes, ingresos, comisión, pagos, incidentes, valoraciones, rendimiento individual de conductores y vigencia de seguros; disponibles para imprimir o exportar a PDF con identidad Yavoi!.
- Pólizas de seguro resguardadas como PDF privado, con fecha de caducidad, semáforo de vigencia y alertas anticipadas para Operaciones.
- Centro de cumplimiento para autorización estatal, póliza empresarial, expedientes vigentes, aportación estimada al Fondo de Movilidad, recibos por correo y avisos a la autoridad.
- Expediente regulatorio de cada viaje con aceptación, cotización, asignación, conductor, unidad, ruta propuesta, recorrido real, cobro y cierre, protegido durante al menos cinco años.
- Cuota semanal dentro del perfil del conductor y expediente de unidad colapsado automáticamente al llegar al 100%.
- Perfiles completos protegidos contra cambios; Operaciones con MFA puede abrir o revocar una autorización temporal de 24 horas con motivo y registro de auditoría.
- Recuperación del viaje y del plan de solicitud desde Supabase después de recargar, cerrar o volver a abrir el navegador.
- Exportación CSV segura para análisis operativo.

## Seguridad

Supabase Auth usa PKCE y correo verificado. Los permisos se obtienen del perfil almacenado en la base, nunca de metadatos modificables por el usuario. Todas las tablas expuestas tienen Row Level Security; las operaciones sensibles pasan por funciones del servidor con control de rol, estado del viaje, vigencias, límites de frecuencia y MFA AAL2 para Operaciones.

La primera cuenta de Operaciones está reservada para `admin.yavoi@gmail.com`. El correo debe verificarse y la cuenta debe configurar autenticación de dos pasos antes de usar el panel administrativo.

Las fotografías y documentos se guardan en depósitos privados y se consultan mediante enlaces temporales. La clave incluida en el cliente es la clave publicable de Supabase; no se utiliza ninguna clave de servicio en el navegador.

La presencia de un conductor vence a los 90 segundos sin señal. Esto impide nuevas asignaciones si el navegador se cierra, pierde conexión o el sistema operativo suspende la página; al regresar, la sesión y el rastreo se recuperan automáticamente.

## Estimador de tarifa

La tarifa se calcula en PostgreSQL y se conserva en la cotización durante cinco minutos. Usa inicio del servicio, kilómetros estimados, minutos estimados, tarifa mínima, zona y accesibilidad. No cobra reservación. La recogida lejana sólo se agrega cuando el pasajero elige una unidad ubicada a más de 7 km, y se cobra únicamente el excedente. La asignación automática sigue priorizando la unidad compatible más cercana.

Los mapas de pasajero, conductor, viaje y Operaciones usan Google Maps JavaScript API. La búsqueda de calles, lugares y puntos al tocar el mapa pasa por un servicio protegido con caché: `GOOGLE_MAPS_API_KEY` en Supabase habilita Places API (New), Geocoding API y Routes API. El servidor conserva su propio cálculo de tarifa para impedir que un cliente altere el precio.

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
5. Completar el control regulatorio de la empresa y aprobar conductores sólo después de verificar todos los requisitos y documentos vigentes de su expediente.
6. Completar la guía [Activar Mercado Pago](docs/mercado-pago.md). La tarjeta permanece bloqueada hasta terminar esos pasos.
7. Completar la guía [Activar Google](docs/oauth-providers.md). El Client ID público ya está integrado; falta guardar el Client Secret sólo en Supabase y habilitar el proveedor.
8. Seguir la [matriz de cumplimiento de transporte](docs/cumplimiento-ley-transporte-chihuahua-2026-09-15.md) y formalizar con la autoridad los canales de reportes mensuales e incidentes.
9. Completar la guía [Activar recibos de viaje por Gmail](docs/gmail-trip-receipts.md) antes de habilitar el envío automático en Operaciones.
10. Para Maps, habilitar **Maps JavaScript API**, **Places API (New)**, **Routes API** y **Geocoding API** en Google Cloud. En Vercel guardar `VITE_GOOGLE_MAPS_BROWSER_KEY` (restringida por referentes HTTP) y `VITE_GOOGLE_MAP_ID`. En Supabase guardar una segunda clave, restringida a Places, Routes y Geocoding, como secreto `GOOGLE_MAPS_API_KEY`; después volver a desplegar la función `maps`.

Diseño y desarrollo: **TheDevLogos Creación Inteligente**.
