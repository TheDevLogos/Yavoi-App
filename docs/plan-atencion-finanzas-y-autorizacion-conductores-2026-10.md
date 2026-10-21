# Plan de atención: finanzas, liquidación semanal y permisos de conducción

Fecha de revisión: 20 de octubre de 2026
Zona horaria operativa: Chihuahua, México

## Objetivo

Dejar una conciliación semanal auditable, fácil de revisar en Operaciones y consistente con los importes que consulta cada conductor; después, verificar que el permiso de conducción dependa de un expediente vigente, las políticas aceptadas y la liquidación que corresponda.

Los viajes de demostración se conservarán. No es necesario borrarlos para este trabajo y conservarlos permite rastrear cómo se formó cada cálculo.

## Fases

| Fase | Trabajo | Resultado que se debe poder comprobar | Estado |
|---|---|---|---|
| 1. Bandeja de Finanzas | Alertar diferencias de cobro, cortes vencidos, documentos incompletos, validaciones fiscales y determinaciones/pagos registrables. Mostrar periodo y fecha límite conocida; no inventar fechas fiscales. | Cada aviso enlaza con el módulo de atención. Las fechas no disponibles se identifican como pendientes de confirmar. | Implementada en código local; requiere desplegar el cliente y aplicar la migración antes de usarla en producción |
| 2. Filtros de Pagos y Cuotas | Unificar periodo, fecha de referencia, conductor y estado para tarjetas, gráficas, resúmenes por conductor y liquidaciones. Los cortes son semanales y se muestran cuando su semana intersecta el periodo consultado. | Una respuesta del servidor calcula todos los componentes filtrados; la lista y sus cifras conservan el alcance de esos filtros. | Implementada en código local y migración; pendiente desplegar/aplicar |
| 3. Exportación PDF | Generar resumen filtrado de Pagos y Cuotas y PDF individual de cada liquidación, con componentes por viaje y una nota que separa conceptos contractuales de pagos fiscales reales. | Cada PDF refleja los filtros visibles o un corte individual y conserva espacio para sus notas. | Implementada local; pendiente desplegar/aplicar |
| 4. Banco y CLABE | Capturar banco y CLABE desde Operaciones; validar formato y dígito verificador antes de crear cortes o instrucciones. | Sin destino válido, no se generan cortes cobrables, vencimientos ni suspensiones por deuda nueva. | Bloqueado por decisión del titular hasta configurar y validar la cuenta |
| 5. Etiquetas y alcance de liquidación | Separar la comisión contractual y conceptos de referencia de cualquier retención fiscal; clasificar ISR/IVA heredados como históricos. Incluir en el corte sólo efectivo cobrado directamente por el conductor hasta contar con cobro digital conciliado. | No se solicita transferir dinero que la plataforma ya cobró; los datos históricos no se presentan como enteros al SAT. | Revisión y ajustes locales completados; la aceptación fiscal/contractual aún debe revisarse con asesoría y datos reales |
| 6. Primer corte de prueba real | Completar perfil fiscal, aceptación, viaje efectivo, aviso, comprobante, conciliación y reflejo en Finanzas en un entorno controlado. | Evidencia del flujo completo y de importes coincidentes en Operaciones y la app del conductor. | No ejecutable aún: no hay datos de producción para ese flujo y el destino bancario está bloqueado. No se simulará como si fuera una conciliación real |

## Reglas de integridad

1. El pago semanal es una obligación contractual a Yavoi!, no una retención fiscal.
2. ISR, IVA y aportación estatal de referencia se muestran separados de impuestos efectivamente pagados a la autoridad.
3. La aportación estatal permanece desactivada hasta validar autorización y convenio aplicables.
4. Una misma liquidación no puede cambiar de fecha de vencimiento en cada ejecución automática ni contabilizarse dos veces como ingreso.
5. La revisión de Operaciones y el servidor deben impedir autorizar a un conductor con expediente incompleto, documento vencido, perfil suspendido, aceptación fiscal desactualizada o pago semanal vencido/en revisión.
6. No se borran viajes de prueba, liquidaciones, comprobantes ni cierres como parte de esta mejora. Sólo se corrigen reglas futuras; todo cambio queda en auditoría.

## Pendientes externos que no se pueden suplir con código

- Registrar desde Operaciones el banco receptor y una CLABE válida de Yavoi!. No compartir esos datos por el chat. Hasta que se registren, el sistema debe mantener pausada la emisión de obligaciones cobrables.
- Validar con asesor fiscal que las tasas de referencia correspondan a cada conductor y que los importes que Yavoi! debe declarar sean los que se calculan en Finanzas.
- Registrar la autorización y convenio estatal antes de activar el 1.5%.
- Revisar la formalización de la S.A.S. y demás documentos societarios ya listados en `docs/pendientes-formalizacion-sas.md`.

## Registro de acciones

- 2026-10-20: se confirmó que el panel de validación fiscal existe pero no estaba montado desde la pantalla de Finanzas; la lista de liquidaciones no está acotada por periodo/estado; el vencimiento puede desplazarse en cada conciliación automática; falta destino bancario; el permiso y la conciliación no verifican exactamente el mismo conjunto de vigencias.
- 2026-10-20: se creó el archivo de migración `weekly_liquidation_controls_and_operations_readiness` para implementar las protecciones de la fase 1 y alinear el permiso. La migración todavía debe revisarse, aplicarse y verificarse antes de marcar la fase como terminada.
- 2026-10-20: se montó el tablero de alertas financieras en Finanzas, se agregaron filtros de cortes y exportación imprimible/PDF, y el perfil del conductor muestra 48 horas desde el primer aviso. No se borraron viajes ni comprobantes.
- 2026-10-20: la CLABE/banco no están configurados; el proyecto en producción tiene 0 liquidaciones y 1 conductor activo. No se ejecutó migración ni se crearon obligaciones. El registro debe seguir bloqueado hasta que Operaciones configure una cuenta validada.
- 2026-10-20: la bandeja se afinó para no convertir los renglones históricos de ISR/IVA del conductor ni la aportación estatal no autorizada en supuestos pagos fiscales vencidos. Las fechas fiscales faltantes se muestran como pendientes de confirmar.
- 2026-10-20: el RPC de Pagos y Cuotas ahora devuelve tarjetas, serie, resumen por conductor y cortes con periodo, conductor y estado aplicados en servidor. Los PDF resumen e individual incluyen sólo cortes visibles y evitan que la nota de aclaración se encime con las tablas.
- 2026-10-20: la liquidación semanal sigue siendo contractual a Yavoi!. Sólo abarca efectivo cobrado directamente por el conductor; los viajes electrónicos se excluyen hasta que exista proveedor de cobro y conciliación que eviten un doble cobro.
- 2026-10-20: la prueba integral de un primer corte real sigue pendiente. Los datos actuales no aportan un corte de producción comprobable y no se crearán avisos, saldos ni pagos reales de prueba.
- 2026-10-20: validación local: 108 pruebas existentes aprobadas, compilación de producción correcta y ejecución aislada del RPC con datos ficticios en memoria. Esto no sustituye la prueba de producción. La compilación conserva una advertencia de paquete JavaScript grande.

## Revisión de la autorización del conductor

El perfil web/PWA presenta siete requisitos claros: fotografía de perfil, INE, licencia, tarjeta de circulación, póliza, aceptación de Privacidad y aceptación de Términos. El servidor verifica que los cuatro archivos estén en el almacenamiento privado y registra ambas aceptaciones. La aprobación interna depende además de revisión de Operaciones y de vigencias oficiales.

La puerta de pago semanal todavía no es operable ni vinculante en producción: falta la cuenta receptora y no hay liquidaciones abiertas. Por instrucción del titular, no se deben generar cortes, vencimientos ni suspensiones hasta configurar banco y CLABE válidos. El permiso y los requisitos documentales pueden revisarse por separado, pero no se debe presentar la liquidación como habilitada.

La pantalla de aprobación de Operaciones captura tipo de conductor, categoría, datos básicos del vehículo, licencia, seguro, tarjeta de circulación y tarjetón. No captura ni deja evidencia completa de todas las condiciones regulatorias que el código legal del estado contempla para vehículo/conductor. La ley estatal enumera, entre otros, afiliación y registro, tarjetón anual, seguro, circulación/placas/holograma/NIV, verificación cuando aplique, inspección mecánica y de seguridad, antigüedad, equipo del vehículo y obligaciones fiscales. También exige autorización estatal de la empresa, convenio y póliza de cobertura de la plataforma. Estos puntos deben quedar como campos y verificaciones de Operaciones antes de afirmar que la autorización es legalmente completa; no se deben convertir en archivos extra que el conductor tenga que cargar desde su perfil sin una decisión expresa.

La lectura de producción encontró: 1 conductor aprobado/activo; ese registro tiene presentes los controles de vehículo actualmente guardados; preparación de cumplimiento empresarial=false y modo de aplicación `monitor`; cuenta receptora no configurada y 0 liquidaciones. Tampoco aparecen capturados razón social, RFC, autorización estatal vigente, convenio de colaboración ni metadatos/vigencia/cobertura de la póliza empresarial. El estado activo refleja autorización interna en la app, no certifica por sí mismo que Yavoi! ya tenga autorización estatal, convenio y póliza empresarial completos.

La base legal revisada es la [Ley de Transporte del Estado de Chihuahua](https://portalair.chihuahua.gob.mx/media/archivos/74505_LEY-DE-TRANSPORTE.-2020..pdf), especialmente artículos 128–139, junto con el [decreto oficial de reforma publicado el 16 de julio de 2022](https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/161.pdf). Ese decreto modificó, entre otros, los artículos 128, 129 y 139 y reasignó competencias de transporte; por eso no debe tratarse el PDF base de 2020 como una consolidación vigente completa. Antes de activar enforcement hay que validar el texto consolidado, reglamento aplicable y el convenio concreto con asesoría local y la autoridad competente.

## Criterio para continuar

1. No aplicar la migración a producción todavía. Primero revisar la puerta de autorización contra la lista regulatoria completa y comprobar la pantalla de Operaciones; una modificación de funciones de permiso debe ser reversible y probarse con casos que no cambien el conductor activo.
2. Mantener congelada la emisión/cobro de liquidaciones hasta que Operaciones registre banco y CLABE con dígito verificador correcto.
3. No borrar viajes de demostración; preservar los detalles para auditoría y conciliación.
4. Después de registrar el destino, aplicar la migración, ejecutar el corte controlado en ambiente de pruebas, revisar una liquidación de efectivo y aprobar/rechazar comprobantes antes de publicar.
