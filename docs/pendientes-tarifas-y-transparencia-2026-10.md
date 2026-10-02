# Pendientes: tarifas, cobros y transparencia financiera

**Estado:** hoja de ruta guardada. No modifica tarifas, comisiones, impuestos ni cobros activos.

Las capturas compartidas de un viaje de Uber se usarán únicamente como referencia de claridad visual y orden de conceptos. Yavoi! conservará su propia nomenclatura, reglas comerciales, cálculo y documentación fiscal.

## Principio de presentación

Cada viaje debe poder explicarse de punta a punta, con importes verificables:

`cotización aceptada → precio final del usuario → cobro recibido → movimientos de billetera → comisión y costos → retenciones fiscales → ganancia disponible del conductor → retiro o conciliación`

Los conceptos comerciales, los impuestos retenidos y los costos de cobro deben mostrarse por separado. Ningún cargo debe etiquetarse como impuesto si es una comisión, ni como comisión si corresponde a una retención fiscal.

## Ajustes de experiencia pendientes

### Detalle para usuario

- Mostrar la **tarifa anticipada** aceptada y, al finalizar, el **precio final**.
- Desglosar solo los conceptos aplicables: tarifa base, distancia, tiempo, demanda dinámica, espera, peajes, promociones, ajustes y propina.
- Indicar de forma visible el motivo de una diferencia entre precio anticipado y final, antes de cobrarla cuando el flujo lo permita.
- Conservar mapa de recorrido, duración, distancia, origen, destino y puntos o recompensas obtenidos.
- Añadir un enlace breve de “Ver desglose” en el detalle del viaje terminado, sin sobrecargar la pantalla de solicitud.

### Detalle para conductor

- En la oferta: mostrar **ganancia estimada** y qué elementos podrían cambiar al cierre.
- En el viaje terminado: separar pago por servicio, incentivos o bonos, promociones financiadas, comisión de plataforma, cargos de procesamiento, retenciones fiscales, ajustes y propinas.
- Mostrar tres saldos sin ambigüedad: **ganancia bruta**, **retenciones y cargos aplicables**, y **saldo disponible en billetera**.
- Identificar por separado la tarifa anticipada contractual y cualquier ajuste posterior con referencia, motivo y fecha.
- La propina debe registrarse como concepto independiente y no integrarse a la comisión de plataforma.

### Finanzas de Operaciones

- Reconciliar por viaje: pago del usuario, medio de pago, comisión, promoción, incentivo, impuestos y saldo del conductor.
- Exponer una cadena auditable: cobro recibido → saldo en tránsito → obligación fiscal o comercial → billetera → retiro/compensación.
- Mantener el detalle inmutable una vez que el viaje tenga términos financieros y vincular cada ajuste a una referencia y motivo.
- Ofrecer exportables semanales y mensuales con totales conciliados, excepciones, ajustes pendientes y saldos por liquidar.

## Decisiones requeridas antes de activar cambios comerciales

1. **Tarifario oficial por categoría y zona:** mínimo, tarifa base, costo por kilómetro, minuto, tiempo de espera, peajes y regla de redondeo.
2. **Impuestos incluidos o desglosados:** definir qué ve el usuario en la cotización y cómo se factura cada concepto.
3. **Demanda dinámica:** zonas, horario, señal de oferta/demanda, multiplicador, tope, aviso al usuario y proceso de aprobación. Actualmente permanece desactivada hasta contar con esta política aprobada.
4. **Comisiones y cargos de cobro:** porcentaje contractual por tipo de conductor, costo real de Mercado Pago y quién absorbe cada costo. No se debe crear un cargo equivalente a una “cuota de solicitud” sin una regla comercial y fiscal aprobada.
5. **Promociones e incentivos:** catálogo, fuente de financiamiento, requisitos, vigencia y forma de reflejarlos para usuario, conductor y Operaciones.
6. **Perfil fiscal del conductor:** RFC validado, condición de retención aplicable y confirmación de las tasas con contador fiscal. La regla para conductores sin RFC no debe ajustarse sin esa validación.
7. **Cumplimiento fiscal operativo:** proveedor PAC/CFDI, comprobantes, enteros, calendario y responsables. Las reservas internas no sustituyen CFDI ni entero ante autoridad.
8. **Excepciones de cobro:** cancelaciones, diferencias de ruta, efectivo incompleto/excedente, devoluciones, contracargos, peajes y ajustes manuales.

## Referencia de las capturas recibidas

El ejemplo muestra una estructura útil de lectura: pago del usuario, conceptos gubernamentales, cargos de plataforma, ganancia del conductor, tarifa anticipada, incentivo y ajustes. En Yavoi! cada renglón se mostrará solo si existe y estará respaldado por el registro real del viaje; no se copiarán nombres, importes, reglas ni fórmulas de Uber.

## Controles de integridad antes de liberar

- La suma de los conceptos debe coincidir exactamente con el precio final y con el movimiento de billetera, con regla única de redondeo.
- Cotización, términos aceptados y desglose final deben conservar versión, fecha y fuente de cada ajuste.
- Todo ajuste posterior debe ser idempotente, tener motivo, referencia, autor y trazabilidad en el estado de cuenta.
- Los reportes semanales y mensuales deben cuadrar contra pagos electrónicos, efectivo declarado, retiros, impuestos por enterar y promociones financiadas.
- Las pantallas de usuario, conductor y Operaciones deben derivar de los mismos datos financieros, sin cálculos visuales independientes.

## Información que se solicitará al retomar este trabajo

- Tarifario vigente por servicio y cobertura.
- Contrato o porcentaje de comisión para conductores Yavoi! y de Apoyo.
- Política aprobada de demanda dinámica y promociones.
- Comisiones reales de Mercado Pago y tratamiento de efectivo.
- Criterio firmado por contador sobre IVA, ISR, impuesto estatal y facturación de Yavoi! como S.A.S.
