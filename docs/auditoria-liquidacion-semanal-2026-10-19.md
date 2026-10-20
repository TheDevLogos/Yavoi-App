# Auditoría de liquidación semanal

## Resultado

Cada viaje completado conserva un expediente financiero inmutable: folio, conductor, fecha de finalización, tarifa aceptada y final, ajustes, método de cobro, comisión aplicada, IVA, ISR de referencia y aportación estatal. Finanzas y Pagos y cuotas consultan esos mismos registros, por lo que Operaciones puede rastrear el origen de cada importe hasta el viaje.

El efectivo se entrega directamente al conductor. El corte semanal se genera por conductor, de lunes a domingo, con la suma de la cuota comercial fijada en cada viaje. El comprobante cargado por el conductor y la conciliación de Operaciones quedan vinculados al corte, con folio de recibo y bitácora.

## Lo que el sistema calcula hoy

- Cobro bruto acumulado en efectivo por conductor.
- Cuota comercial de Yavoi!, con porcentaje congelado por viaje.
- Base gravable, IVA incluido en la tarifa, ISR e IVA de referencia y aportación estatal de 1.5%.
- Promociones, ajustes, cancelaciones y diferencias que requieren revisión.
- Gastos y pagos fiscales documentados dentro de Finanzas para los cierres mensuales.

## Límite deliberado

El importe exigible al conductor es actualmente **solo la cuota comercial acumulada**. Los impuestos propios de Yavoi!, la aportación estatal y los gastos operativos se calculan y documentan para Operaciones, pero no se trasladan automáticamente al conductor ni se denominan retenciones.

Para incluir cualquiera de esos conceptos en una liquidación del conductor se requiere antes una política comercial firmada que defina: concepto, base, porcentaje o tarifa, vigencia, responsable, tratamiento de IVA, condiciones de ajuste y evidencia de aceptación. Sin ello, sumar impuestos o gastos de Yavoi! al cobro del conductor crearía un importe sin sustento contractual ni fiscal suficiente.

## Flujo validado

1. El pasajero y conductor ven el importe final y el detalle del viaje.
2. El viaje completado guarda su fotografía financiera; la cotización no se altera posteriormente.
3. Operaciones consolida la semana cerrada y emite una liquidación por conductor.
4. El conductor carga su comprobante y Operaciones concilia exactamente el importe solicitado.
5. Se crea recibo, aviso en Bandeja de Entrada y, si el expediente sigue vigente, se autoriza la conducción.

## Siguiente decisión de negocio

Definir si la liquidación seguirá siendo únicamente la cuota comercial o si existirá una cuota de operación separada y contractualmente aceptada. La segunda opción debe implementarse como partidas identificables por viaje o por semana; nunca mezclada con ISR, IVA o contribuciones propias de Yavoi!.
