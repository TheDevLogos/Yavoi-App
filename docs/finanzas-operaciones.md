# Finanzas en Operaciones

Implementado el 29 de septiembre de 2026. Acceso: Operaciones → Finanzas, con cuenta administradora y verificación en dos pasos.

## Reportes

- Semana de lunes a domingo y mes natural, con fechas en America/Chihuahua; importes en centavos MXN.
- Comparación con el periodo anterior, cobros por día, efectivo/electrónico, resultado operativo, descuentos, incentivos, retiros y billeteras.
- Conciliación completa por viaje y conductor, conservando el expediente de cada servicio. Los viajes usan fecha de finalización; el flujo de pagos usa confirmación del cobro o del reembolso.
- Resumen fiscal: ISR/IVA efectivamente retenidos, aportación estatal de 1.5%, IVA propio e ISR propio RESICO de Yavoi! separados.
- PDF, impresión y CSV con todos los viajes; el límite de visualización de la tabla no limita las exportaciones.

## Cierres

Se habilitan después de terminar el periodo. Guardan una copia completa, folio, versión, fecha, nota, observaciones y huella del contenido. Los movimientos conciliados posteriormente aparecen en una revisión nueva; la versión anterior permanece inalterada. Un cierre no inicia cargos, retiros o declaraciones fiscales.

Los cobros pendientes, registros históricos, reembolsos y saldos fiscales no conciliados requieren guardar con observaciones. Las promociones pendientes se distinguen de los abonos y de las transferencias bancarias.

## RESICO: S.A.S. persona moral

Estimación mensual acumulada desde enero:

Ingresos propios cobrados sin IVA − deducciones efectivamente pagadas y validadas − PTU pagada − pérdidas fiscales aplicables = base fiscal acumulada, mínimo cero.

ISR estimado = base × 30% − pagos provisionales anteriores − ISR acreditable propio, mínimo cero. Las retenciones realizadas a conductores se contabilizan como obligaciones diferentes.

Los ingresos conocidos incluyen comisiones electrónicas confirmadas, comisiones de efectivo liquidadas directamente, cuotas conciliadas y cargos por retiro, con sus reversos. Las comisiones de efectivo efectivamente compensadas con abonos de billetera requieren documentar su conciliación en “Saldos y ajustes fiscales”; no se infieren automáticamente de un saldo neto. No se cuentan saldos de apertura como ventas.

Gastos: registrar importe, IVA acreditable validado y deducción ISR validada por separado. El 1.5% pagado puede llevar deducción sólo si su tratamiento está validado. Registrar pérdidas/saldos iniciales una vez por ejercicio. Certificar saldos desde enero después de cotejar ingresos, compensaciones, CFDI y pagos anteriores.

Una determinación mensual validada sustituye la estimación en la tabla fiscal. Si se anula vuelve a mostrarse el cálculo estimado. “Registrar pago fiscal” conserva fecha de pago y mes de obligación; evita confundir pago y gasto operativo.

## Controles

Permisos restringidos en servidor, RLS, registros inmutables y correcciones con contrapartida. Claves únicas evitan duplicar documentos o cierres en reintentos. Los documentos no modifican el saldo del conductor.

Los históricos anteriores al registro fiscal actual requieren conciliación. El flujo identificado debe cotejarse con los estados de cuenta y no equivale al saldo bancario. El proveedor de retiros actual es manual; Mercado Pago necesita habilitación y credenciales para automatizar las transferencias y cobros reales. Los reportes no presentan declaraciones ante SAT ni pagan automáticamente la aportación estatal.

Fuentes: [LISR, arts. 9 y 207–211](https://www.diputados.gob.mx/LeyesBiblio/pdf/LISR.pdf), [LIVA, arts. 5 y 5-D](https://www.diputados.gob.mx/LeyesBiblio/pdf/LIVA.pdf), [Ley de Transporte de Chihuahua, art. 128](https://portalair.chihuahua.gob.mx/media/archivos/74505_LEY-DE-TRANSPORTE.-2020..pdf). La elegibilidad y permanencia en RESICO y los comprobantes deben corresponder a la situación fiscal registrada de la empresa.
