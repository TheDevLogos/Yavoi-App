# Yavoi!: tarifas, fiscalidad y billetera

Revisión: 29 de septiembre de 2026. Implementación para viajes nuevos, en MXN y centavos enteros. Los viajes históricos conservan sus condiciones y requieren conciliación antes de convertirse en saldo retirable.

## Criterios y fuentes oficiales

- **ISR**: transporte y entrega de bienes por personas físicas: 2.1% sobre ingresos intermediados sin IVA, antes de comisión. Sin RFC proporcionado: 20%. El efectivo recibido directamente tiene tratamiento declarativo propio; no se etiqueta como retención de la plataforma. [LISR, artículos 113-A a 113-C](https://www.diputados.gob.mx/LeyesBiblio/pdf/LISR.pdf).
- **IVA**: servicio con IVA de 16% incluido; base = importe / 1.16. En cobros intermediados se retiene la mitad del IVA cobrado si se proporciona RFC y el IVA completo sin RFC. La comisión tiene su propio IVA, separado del IVA del viaje. [LIVA, artículos 1, 15-V y 18-J](https://www.diputados.gob.mx/LeyesBiblio/pdf/LIVA.pdf).
- **Ejercicio 2026**: el reemplazo a 2.5% de la LIF se refiere a la fracción III del 113-A; no modifica la tasa de transporte de la fracción I. Las personas morales que reciben ingresos por plataformas tienen retención de ISR de 2.5%, con 20% sin RFC, y quedan incluidas en las reglas de retención de IVA. Las cuentas configuradas son mexicanas; no se admiten destinos bancarios extranjeros. [LIF 2026, artículo 25, VI y IX](https://sidof.segob.gob.mx/notas/docFuente/5772357).
- **Chihuahua**: aportación de ERT de 1.5% del monto efectivamente cobrado por viajes iniciados en el estado, conforme al convenio y Fondo de Movilidad. Se registra como obligación de Yavoi!, separada del pago del conductor. Deben confirmarse convenio, autorización estatal y liquidación administrativa. [Ley de Transporte, artículo 128, fuente gubernamental](https://portalair.chihuahua.gob.mx/media/archivos/74505_LEY-DE-TRANSPORTE.-2020..pdf).
- **Propinas**: voluntarias, sin comisión comercial; se consideran para ISR cuando se perciben por plataforma. Se separan del precio del servicio y de su IVA. El criterio de propinas requiere que la plataforma no participe en ellas. [SAT, criterio de propinas](https://www.sat.gob.mx/cs/Satellite?blobcol=urldata&blobkey=id&blobtable=MungoBlobs&blobwhere=1461173495102&ssbinary=true). La fiscalidad de plataformas se mantiene con la reforma laboral; nómina, IMSS y obligaciones laborales requieren su cumplimiento adicional, sin aplicar automáticamente porcentajes de otra empresa. [SAT y STPS](https://www.gob.mx/sat/prensa/brindan-sat-y-stps-certeza-juridica-a-trabajadores-de-plataformas-digitales-033-2025).

## Fórmula comercial de Yavoi!

Tarifa base + kilómetros estimados × precio/km + minutos estimados × precio/min + ajuste a tarifa mínima + cargos anunciados + demanda configurada − recompensa = precio del servicio. La propina voluntaria se agrega por separado.

Se conserva el precio anticipado del recorrido confirmado. La distancia de recogida no se cobra como kilómetros de traslado del pasajero. No se agregan cargos nuevos de espera, peajes o variación de ruta sin información y autorización previa. Los actuales cargos y plazos de cancelación permanecen; la conciliación usa únicamente el importe retenido o confirmado.

Demanda dinámica desactivada inicialmente: cuando se habilita en Operaciones, usa solicitudes pendientes frente a conductores disponibles, con límite de 2× y muestra el incremento antes de confirmar. No replica un algoritmo privado de Uber. Referencia de estructura y comisión variable: [Uber](https://www.uber.com/mx/es/blog/tasa-de-servicio-variable/).

Los niveles actuales de Yavoi! (Activo, Destacado, Élite y Referente) permanecen. Operaciones puede configurar reducciones de comisión por nivel, congeladas al asignarse el viaje. No se cambia a Oro/Plata/Diamante ni se promete un bono sin financiación. Los incentivos de transporte se registran brutos con sus retenciones; otros ajustes necesitan soporte contable.

## Ejemplo, persona física con RFC

Viaje $116.00 IVA incluido + propina $10.00. Comisión comercial del 20% sobre tarifa: $23.20, integrada por $20.00 + IVA $3.20. Base del viaje $100.00, IVA $16.00. ISR: 2.1% de $110.00 = $2.31. IVA retenido: $8.00. Neto del cobro electrónico: $92.49. Aportación estatal de Yavoi!: $1.74, sin descuento adicional al conductor.

Los descuentos financiados se muestran como obligación de Yavoi! hasta su conciliación. Al financiarse la parte correspondiente, se registran su ingreso y sus retenciones; jamás se suma una promoción pendiente al saldo retirable.

## Billetera y controles

- Gráfica diaria y acumulado semanal, hora de Chihuahua. Efectivo recibido, saldo confirmado, deuda, reservas y promociones visibles por separado.
- Comisiones de efectivo se registran como adeudo y se compensan con los siguientes abonos electrónicos; las liquidaciones históricas permanecen en su módulo original.
- No se acredita dos veces una comisión o promoción. Referencias únicas, registros inmutables y asientos de reversión para reembolsos.
- Un pago aprobado pero sin fecha de liberación comprobada queda retenido. No se puede retirar efectivo recibido ni dinero ya transferido.
- Retiro diario: un retiro al día, 3% total con IVA incluido en el cargo. Semanal: sin cargo, lunes desde 7:00 a.m. La opción automática reserva el saldo y crea solicitudes; el envío depende del proveedor habilitado.
- CLABE con dígito verificador y titularidad validada por Operaciones. Cambiar la cuenta exige nueva validación. El destino de cada retiro queda congelado.
- Los cambios fiscales, financiación y conciliación de retiros exigen Operaciones con MFA y quedan en auditoría. Ninguna interfaz puede escribir directamente en la billetera.

## Activación de transferencias y CFDI

El adaptador `driver-payouts` firma las solicitudes y utiliza idempotencia. Sólo considera pago realizado los estados finales acreditados, no `created`, `approved` ni `success/in_progress`. Ante una respuesta incierta conserva la reserva. [Estados oficiales de Payouts](https://www.mercadopago.com.mx/developers/es/docs/payouts/resources/transaction-status-and-errors).

Para producción, Mercado Pago debe habilitar Payouts y registrar la clave pública Ed25519 de Yavoi!. La clave privada se guarda exclusivamente en secretos de Supabase. Después de confirmar pruebas y saldo de origen: configurar `MP_PAYOUTS_ENABLED=true` y elegir Mercado Pago en Operaciones. [Requisitos de producción](https://www.mercadopago.com.mx/developers/es/docs/payouts/go-to-production?scope=prod).

La facturación de ingresos, comisión y retenciones requiere RFC/razón social/regímenes correctos, un PAC y timbrado CFDI. El registro contable, recibo de servicio y resumen fiscal no afirman que ya se haya timbrado o enterado dinero al SAT. La habilitación legal de Yavoi! como ERT y sus obligaciones laborales no se completan mediante este cambio de software.

## Despliegue y conciliación

- Los importes vigentes quedan congelados en nuevas cotizaciones y viajes. El histórico mantiene sus condiciones y requiere conciliación para trasladar saldos previos.
- La gráfica semanal incluye bonos y propinas adicionales netos. Las barras muestran pesos redondeados; tocar un día abre el importe exacto.
- Conductor y Operaciones pueden descargar movimientos mensuales CSV completos, con referencias y enlaces por viaje en la pantalla.
- El recibo al pasajero desglosa tarifa, descuento, servicio sin IVA, IVA incluido y propina. La notificación al conductor muestra el neto estimado de la misma oferta.
- Se monitorean transferencias confirmadas durante siete días para detectar devoluciones bancarias completas, con restitución idempotente. Devoluciones parciales requieren conciliación del proveedor.
- La clave pública para registrar en Mercado Pago está en `docs/mercado-pago-payouts-public.pem`. La firma privada y token del trabajador están protegidos en Supabase; el interruptor de Payouts permanece desactivado hasta la habilitación externa. También deben configurarse `MP_ACCESS_TOKEN` y `MP_WEBHOOK_SECRET` de producción para el cobro electrónico.
- Los retiros están habilitados para solicitud y conciliación bancaria por Operaciones, con CLABE validada. El sistema no ejecuta una transferencia bancaria manual ni declara pagada una solicitud sin referencia confirmada.

## Revisión técnica

Las pruebas financieras validan retenciones por perfil, separación del efectivo, fondos retenidos por el proveedor, compensación de adeudos, autorización, CLABE, reservas, idempotencia, estados intermedios y devoluciones. Se conserva la liquidación histórica de comisiones. Las suites de base de datos se ejecutan consecutivamente para evitar competencia de memoria y caducidades artificiales de ofertas de ocho segundos.

La revisión de Supabase no agrega avisos de seguridad para las nuevas tablas; su acceso directo está denegado y sus cambios se realizan por funciones autorizadas. Permanecen avisos previos: [protección de contraseñas filtradas](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection) e [índices de referencias de tablas anteriores](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys).

Estado del despliegue: billetera, retenciones, cotizaciones, aviso de oferta y conciliación publicados en Supabase y Vercel. La actualización de recibos Gmail quedó preparada en el repositorio, pendiente de autorización específica por revisión automática de permisos; la función anterior sigue activa. Solicitudes del lunes antes de las 7:00 a.m. se reservan para ese mismo lunes.
