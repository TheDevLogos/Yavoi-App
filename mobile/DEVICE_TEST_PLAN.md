# Pruebas reales antes de prueba cerrada

Ejecutar cada caso en un teléfono Android y, cuando esté disponible, en iPhone
con cuenta de pasajero y conductor de demostración separadas.

## Pasajero

- Registro, inicio y recuperación de sesión.
- Permisos de ubicación y notificaciones: aceptar, negar y volver a permitir.
- Búsqueda de dirección, destino frecuente, cotización y tarifa fija.
- Solicitud, asignación, seguimiento, mensajes, cancelación y reporte.
- Viaje en efectivo: llegada, espera, inicio, finalización y comprobante.
- Confirmar que tarjeta está deshabilitada en cotización y propina durante el
  piloto y que el servidor rechaza intentos directos de iniciar un cobro.
- Solicitud de eliminación de cuenta mediante la URL pública.

## Conductor

- Inicio con estado desconectado; conexión y desconexión manual.
- Recepción de una oferta en primer plano, segundo plano y después de tocar la
  notificación; comprobar el vencimiento a ocho segundos.
- Aceptación, navegación a recolección, llegada, inicio y navegación a destino.
- Cobro efectivo, monto distinto, ajuste autorizado, finalización y siguiente
  viaje en cola.
- Resumen semanal, viajes en efectivo, adeudo/comisión y datos bancarios para
  liquidación manual; confirmar que no existe solicitud de retiro en la app.
- Pérdida y recuperación de red, cierre temporal de la app y sesión renovada.

## Evidencia mínima

Anotar versión, dispositivo, sistema operativo, resultado y captura para cada
caso. Bloquear el lanzamiento si fallan pago en efectivo, asignación, cierre de
viaje, notificación de oferta, bloqueo de tarjeta o eliminación de cuenta.
