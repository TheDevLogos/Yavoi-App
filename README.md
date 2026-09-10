# Yavoi! — plataforma web de movilidad

Aplicación web responsiva para pasajeros, conductores y el equipo de Operaciones de Yavoi! en Delicias, Chihuahua y su región.

## Experiencia disponible

- Acceso único con correo verificado, recuperación de contraseña y sesión persistente.
- Alta de pasajero o conductor; el rol de Operaciones no puede elegirse durante el registro.
- Paneles y rutas separados por rol, con validación adicional en PostgreSQL.
- Perfil de pasajero, expediente privado de conductor y revisión por Operaciones.
- Cotización en servidor por categoría, kilómetros estimados, duración y zona.
- Estimación de distancia y tiempo de una unidad disponible hasta la recogida.
- Zonas central, urbana y regional; Meoqui se clasifica como servicio regional.
- Preferencia de conductora verificada y unidad con accesibilidad verificada.
- Efectivo con importe para cambio. Tarjeta permanece deshabilitada hasta conectar un proveedor real.
- Solicitud idempotente, asignación de conductor, PIN de inicio, ubicación, chat y estados del viaje.
- Cierre con confirmación de efectivo, recibo, valoración mutua, propina, recompensas y quejas.
- Centro de Operaciones con flotilla, expedientes, viajes, ingresos, reportes, tarifas y auditoría.
- Exportación CSV segura para análisis operativo.

## Seguridad

Supabase Auth usa PKCE y correo verificado. Los permisos se obtienen del perfil almacenado en la base, nunca de metadatos modificables por el usuario. Todas las tablas expuestas tienen Row Level Security; las operaciones sensibles pasan por funciones del servidor con control de rol, estado del viaje, vigencias, límites de frecuencia y MFA AAL2 para Operaciones.

La primera cuenta de Operaciones está reservada para `admin.yavoi@gmail.com`. El correo debe verificarse y la cuenta debe configurar autenticación de dos pasos antes de usar el panel administrativo.

Las fotografías y documentos se guardan en depósitos privados y se consultan mediante enlaces temporales. La clave incluida en el cliente es la clave publicable de Supabase; no se utiliza ninguna clave de servicio en el navegador.

## Estimador de tarifa

La tarifa se calcula en PostgreSQL y se conserva en la cotización durante cinco minutos. Usa tarifa base, kilómetros estimados de recorrido, minutos estimados, cuota de reservación, tarifa mínima, zona y accesibilidad. La distancia de recogida utiliza la posición reciente de una unidad compatible; cuando no existe, muestra una referencia operativa de zona.

El modelo actual estima la ruta con factores territoriales. Está preparado para sustituirse por un proveedor vial y de tráfico antes de una operación comercial de gran escala.

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
5. Aprobar conductores únicamente después de revisar fotografía, licencia, seguro y vigencias.
6. Conectar un proveedor de pagos certificado antes de habilitar tarjeta.

Diseño y desarrollo: **TheDevLogos Creación Inteligente**.
