# Auditoría del flujo de viaje Yavoi!

Fecha: 13 de septiembre de 2026

## Flujo verificado

1. El pasajero completa perfil, políticas, cotiza en servidor y confirma método de pago, propina y cambio.
2. El servidor conserva la cotización, tarifa, distancia, tiempos, categoría y preferencias. El navegador sólo presenta el desglose.
3. En efectivo, el conductor confirma recepción y cambio al completar. En tarjeta, el servicio no se libera hasta recibir confirmación del proveedor.
4. La comisión se fija al aceptar el conductor. La modalidad semanal conserva el efectivo para el conductor y aplica el porcentaje configurado a tarjeta; la modalidad por comisión genera la liquidación semanal correspondiente.
5. La ubicación del conductor se registra durante estados activos. El historial se conserva para la ficha del viaje; la pantalla muestra señal desactualizada en vez de inventar posición.
6. La finalización genera movimientos contables, conciliación para Operaciones, puntuación/recompensas y valoración. La cancelación conserva responsable, motivo, cuota y reembolso.

## Hallazgos y correcciones aplicadas

| Área | Corrección |
| --- | --- |
| Ruta propuesta | Se guarda una instantánea vial al crear el viaje. La ficha muestra propuesta azul con borde blanco y GPS real naranja. |
| Mejor alternativa | El servicio de rutas evalúa alternativas de OSRM con una ponderación de 65% tiempo y 35% distancia. |
| Programación | Se puede crear una vez, diaria, semanal o mensual. Cada ocurrencia es un viaje independiente y auditable. |
| Tarjeta programada | Cada fecha conserva su propio pago pendiente hasta que el pasajero lo confirme; no se generan cargos anticipados. |
| Reserva de unidad | Operaciones puede asignar o liberar conductor, validando categoría, requisitos, viaje activo y choque de horario. |
| Activación | A quince minutos del horario, una reserva pagada se activa para el conductor; una sin reserva se entrega al despacho normal. |
| Navegación | El conductor recibe un acceso visible a Google Maps hacia recogida o destino, mientras Yavoi! conserva el rastreo GPS. |

## Límites operativos

La ruta propuesta es una guía y no una medición de taxímetro. Tráfico, cierres, una entrada más segura o instrucciones del pasajero pueden cambiar el recorrido real. La tarifa sigue proveniendo de la cotización segura del servidor. Las alertas se muestran al abrir o actualizar la aplicación; para notificaciones aun con la aplicación cerrada se requiere configurar un proveedor de push y permisos del dispositivo.
