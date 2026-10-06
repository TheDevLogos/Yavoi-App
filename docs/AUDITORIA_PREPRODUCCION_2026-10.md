# Auditoría de preparación para producción — 6 de octubre de 2026

## Alcance y criterio

Esta revisión cubre el código, migraciones, manuales y recursos disponibles en el repositorio. No sustituye una revisión de un contador, abogado, proveedor de pagos, Google, Apple ni la inspección directa de secretos y configuraciones en sus consolas. Un punto marcado **por verificar** requiere evidencia en la consola o una prueba con cuentas reales antes de autorizar producción.

## Resultado ejecutivo

Yavoi! tiene una base sólida para cotizar, registrar el viaje, inmovilizar términos financieros por viaje, mostrar desgloses, conciliar cierres y preparar pagos electrónicos. **No está listo para aceptar cobros reales ni para declarar impuestos automáticamente** hasta cerrar los bloqueos de pagos, fiscalidad, seguridad operativa y pruebas reales detallados abajo.

| Área | Estado | Motivo |
| --- | --- | --- |
| Cotización y tarifa anticipada | Preparada | Versión tarifaria, componentes y tarifa aceptada se conservan por viaje. |
| Tarifa dinámica | Preparada, desactivada | Tiene tope técnico de 1.50× y registro por cotización; requiere aprobación comercial y pruebas con oferta/demanda reales. |
| Efectivo | Preparado con conciliación pendiente | La comisión de efectivo se registra como saldo por cobrar; se necesita el proceso operativo de cobro y evidencia de conciliación. |
| Tarjeta / Mercado Pago | Bloqueado para producción | Faltan credenciales productivas, webhook firmado, homologación y conciliación real. |
| Retiros de conductores | Bloqueado para producción | Requiere habilitación de Payouts, cuenta de origen, firma y prueba de transferencia. |
| Retenciones y CFDI | Bloqueado para automatización | Requiere validación del contador, matriz fiscal, PAC/timbrado y pruebas de entero. |
| Cierres semanales y mensuales | Implementado como control interno | Necesita conciliación contra banco/Mercado Pago y aprobación contable. |
| Seguridad y privacidad | Parcial | Hay RLS en tablas financieras y una solicitud web de eliminación; faltan auditoría en consola, respaldo, proceso de atención y evidencia. |
| Android / iOS | En preparación | Android tiene expedientes y recursos en proceso; iOS sigue requiriendo firma, compilación y pruebas físicas. |

## Controles ya implementados

- El tarifario vigente usa valores en centavos y una versión explícita. La cotización del pasajero incluye IVA y conserva sus componentes, versión y demanda aplicable.
- Al asignar conductor, el viaje guarda comisión, modalidad, RFC declarado, nivel y términos financieros. Los viajes anteriores no se modifican al cambiar el tarifario.
- Las pantallas financieras separan tarifa, ajustes, promociones, propinas, comisión, IVA de comisión, retenciones, saldo de billetera y retiros.
- El cierre de Operaciones consolida cobrado, comisiones, descuentos, incentivos, retenciones, aportación estatal configurada, retiros y diferencias por revisar.
- Las tablas financieras usan RLS y las funciones administrativas exigen rol de Operaciones y segundo factor de autenticación.
- La integración de Mercado Pago verifica un secreto de webhook y usa idempotencia en el flujo de pagos; no se almacenan tarjetas en la aplicación.

## Bloqueos obligatorios antes de producción

### 1. Pagos y conciliación — **no activar tarjeta sin estos puntos**

1. Activar la aplicación productiva de Mercado Pago a nombre de Yavoi! y completar su evaluación.
2. Registrar en secretos productivos `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET` y orígenes autorizados. Nunca colocar estas claves en la app ni en Git.
3. Configurar la URL de webhook de producción con firma secreta; probar pago aprobado, rechazado, pendiente, duplicado, reembolso y reintento.
4. Definir quién es el cobrador contractual y el flujo de fondos: Yavoi!, conductor o modelo marketplace. Debe coincidir con contrato, CFDI, Mercado Pago y registros contables.
5. Comparar diariamente pagos de Mercado Pago, movimientos bancarios, viajes, reembolsos, propinas y cartera de conductores. Ningún cierre debe marcarse definitivo con diferencias abiertas.
6. Mantener Payouts apagado hasta que Mercado Pago habilite el producto, valide la cuenta de origen y una transferencia real a una CLABE haya sido conciliada.

### 2. Fiscal y contable — **validación profesional obligatoria**

1. Confirmar por escrito la figura fiscal y obligaciones efectivas de Yavoi! S.A.S.; el régimen y la obligación de retener no deben inferirse sólo desde la interfaz.
2. Validar con contador la regla por tipo de conductor: persona física/moral, RFC validado, método de pago, efectivo y electrónico. La tasa no puede quedar codificada como regla universal.
3. El código actual conserva `state_bps=150` como parámetro interno. Falta confirmar que la aportación estatal de 1.5% aplica a este modelo, su base, sujeto, periodo y declaración; no debe presentarse como impuesto exigible hasta tener fundamento y criterio contable.
4. Integrar PAC y el proceso para CFDI y CFDI de retenciones con el complemento de Plataformas Tecnológicas, así como folios, cancelaciones, XML/PDF y conservación documental.
5. Definir fecha de corte, responsable y aprobación de cierre; preparar papeles de trabajo para IVA propio, ISR propio, retenciones de terceros, aportaciones estatales, descuentos, incentivos y saldos de billetera.
6. Revisar el tratamiento de efectivo: el registro indica que el conductor recibe el efectivo y que la comisión queda pendiente. Debe existir una política firmada de cobranza, vencimientos, comprobante y suspensión por adeudo.

### 3. Datos, seguridad y continuidad

1. Ejecutar en Supabase los asesores de seguridad/performance, revisar políticas RLS y permisos de cada tabla/función con usuarios pasajero, conductor y Operaciones.
2. Configurar MFA obligatorio para Operaciones, revisión de miembros, rotación de claves, caducidad de sesiones, confirmación de correo y alertas de inicio de sesión.
3. Habilitar y probar respaldos/PITR; documentar restauración y responsable. Probar restaurar una copia sin exponer datos reales.
4. Mantener las claves de servicio, Maps, Firebase y Mercado Pago sólo en secretos de servidor o en el proveedor correspondiente; restringir las claves de Maps por aplicación/origen, API y cuota.
5. Convertir la solicitud de eliminación de cuenta en un caso trazable: autenticación/verificación de identidad, estatus, responsable, plazo, excepciones de conservación fiscal y comprobante de cierre.
6. Establecer monitoreo y alertas para errores de Edge Functions, webhooks fallidos, pagos sin conciliar, notificaciones fallidas, caídas y acceso administrativo.

### 4. Mapas, navegación y notificaciones

1. Configurar claves de Google Maps separadas para web, Android, iOS y servidor; limitar cada una por paquete/bundle/origen y por APIs necesarias.
2. Validar con rutas reales Places, Routes, geocodificación, cotización, seguimiento y llegada en dispositivos físicos.
3. Cargar `FIREBASE_SERVICE_ACCOUNT_JSON` como secreto de Supabase, probar FCM en Android con la app cerrada y validar reintento/idempotencia de ofertas.
4. Para iOS, completar APNs, Firebase iOS, certificados/profiles y las pruebas de alertas, sonido y deep links.
5. No prometer ubicación o notificaciones persistentes en segundo plano hasta comprobar permisos del sistema operativo, límites del proveedor y comportamiento en iPhone/Android reales.

### 5. Operación, movilidad y publicación

1. Definir autorización de conductores, vigencia documental, seguros, licencia, atención a incidentes y un responsable por turno.
2. Realizar pruebas de punta a punta: pasajero, conductor, Operaciones, efectivo, tarjeta, cancelación, ajuste por espera, promoción, propina, retiro, reembolso y cierre.
3. Recopilar evidencia de pruebas: folio, capturas, logs, resultado esperado, conciliación y responsable.
4. Completar Data Safety, privacidad, eliminación de cuenta, clasificación, acceso para revisor y ficha de Play. Mantener la URL pública de privacidad y eliminación.
5. Cerrar las pruebas requeridas de Google Play con los verificadores y preparar una versión posterior con código de versión mayor para cada nueva entrega.
6. Para iOS, generar builds firmadas desde Xcode, configurar App Store Connect, privacidad, permisos, TestFlight, soporte y revisión.

## Riesgo detectado en parámetros fiscales actuales

El motor financiero contempla escenarios de RFC, IVA, ISR y pago electrónico, pero no debe considerarse una determinación fiscal aprobada. En particular, la lógica actual usa una tasa especial cuando no hay RFC y una tasa distinta para entidad empresa. Estas decisiones necesitan el dictamen del contador y pruebas con CFDI antes de habilitar retenciones automáticas. Hasta entonces, mostrar el detalle como **estimación fiscal interna** y mantener la decisión final bajo revisión de Operaciones.

## Orden recomendado para autorizar producción

1. **Contador + abogado/regulador:** modelo contractual, matriz fiscal y obligación estatal.
2. **Mercado Pago:** credenciales, webhook firmado, cuentas de prueba, pruebas y conciliación.
3. **Supabase/Firebase/Maps:** secretos, restricciones, MFA, backups, monitoreo y pruebas reales.
4. **Prueba piloto controlada:** conductores y pasajeros identificados; sólo efectivo si tarjeta no está homologada.
5. **Cierre de prueba:** conciliación de cada viaje y aprobación contable.
6. **Publicación escalonada:** pruebas cerradas, después producción con monitoreo diario.

## Qué sí puede cambiarse después de publicar

Las fichas de tienda, recursos, textos legales, pantallas web, reglas tarifarias versionadas, funciones de servidor y nuevas versiones de la app pueden actualizarse después de publicar. Cada cambio que afecte cobro, privacidad, permisos, ubicación en segundo plano, datos o comportamiento de pagos debe pasar primero por pruebas, revisión de políticas y una nueva versión firmada cuando corresponda. Las tarifas ya aceptadas y los cierres ya aprobados no se deben recalcular retroactivamente.
