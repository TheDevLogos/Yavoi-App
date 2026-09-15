# Matriz operativa de cumplimiento de transporte

Revisión técnica realizada el 15 de septiembre de 2026 sobre la Ley de Transporte del Estado de Chihuahua publicada por el H. Congreso del Estado, con atención especial al Título V, capítulos II, III y IV. Esta matriz sirve para operar y comprobar los controles de Yavoi!; la autorización, el convenio, las pólizas y los formatos oficiales deben validarse con la Subsecretaría y asesoría jurídica local.

Fuente oficial: [Ley de Transporte del Estado de Chihuahua](https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/1526.pdf).

## Flujo de un viaje y evidencia conservada

1. **Registro y acceso.** Supabase Auth identifica a la persona; el servidor obtiene el rol desde el perfil protegido. Operaciones exige verificación en dos pasos para acciones regulatorias.
2. **Perfil y autorización.** El pasajero completa identidad, contacto de emergencia, privacidad, términos y políticas de seguridad. El conductor completa identidad, mayoría de edad, licencia, afiliación, vehículo, documentos, vigencias y equipo. Operaciones verifica y autoriza.
3. **Cotización.** El servidor calcula categoría, origen, destino, distancia, tiempo, zona, tarifa, descuentos, propina y método de pago. La cotización tiene vencimiento y no acepta importes enviados libremente por el navegador.
4. **Consentimiento.** Cada solicitud registra la versión de términos de transporte y su fecha de aceptación. El usuario conoce la estimación y el tratamiento del expediente antes de contratar.
5. **Asignación.** El expediente captura al conductor, fotografía, afiliación, marca, modelo, color, placa, VIN y fotografía frontal de la unidad. Esa identidad se muestra al pasajero durante el servicio.
6. **Ejecución.** GPS, ruta sugerida, recorrido real, estados, mensajes y eventos quedan ligados al folio. Los participantes sólo consultan el viaje que les corresponde.
7. **Cobro y cierre.** Se conserva el desglose estimado y final, método, descuentos, propina, comisiones y conciliación. El cierre crea el recibo en la bandeja de entrega al correo registrado.
8. **Después del viaje.** Se guardan valoraciones, quejas, cancelaciones, incidentes y auditoría. El registro regulatorio no puede eliminarse antes de cinco años.

## Matriz de los artículos 130 a 139

| Artículo | Obligación | Control en Yavoi! | Estado operativo |
| --- | --- | --- | --- |
| 130 | Comunicación segura y protección de información | Chat interno por folio, RLS, documentos privados, enlaces temporales, roles de servidor y MFA para Operaciones | Implementado para mensajes y datos. La llamada enmascarada requiere contratar telefonía |
| 131 | Identidad del conductor, unidad, estimación, calificación, GPS y tiempo visibles durante el viaje | Ficha del conductor y vehículo, estimación, rating, mapa en vivo, ETA, ruta sugerida y recorrido real | Implementado |
| 132 | Póliza empresarial independiente, activa desde conexión hasta desconexión y con cobertura mínima | Centro de cumplimiento, carga privada de póliza, fechas, aseguradora, número, importe y control mínimo de 32 UMA por incidente | Control implementado. Deben cargarse y validar las condiciones de la póliza real |
| 133 | Extracto al correo al concluir | Expediente de cierre y bandeja de recibos con fecha, total, kilómetros, tiempos, origen, destino y conductor | Generación y seguimiento implementados. El envío automático requiere conectar el proveedor de correo |
| 134 | Informe mensual de conductores, vehículos y viajes | Informes por periodo, expedientes de flotilla, viajes, importes y exportación PDF | Implementado. El formato y canal final deben acordarse con la Subsecretaría |
| 135 | Colaboración y reporte automático de posibles delitos | Marca separada de posible delito, bandeja prioritaria, expediente del viaje, referencia de aviso y auditoría | Seguimiento implementado. La transmisión automática requiere el canal oficial del convenio |
| 136 | Registro digital durante un mínimo de cinco años | Instantáneas de solicitud, asignación y cierre; fecha de retención; bloqueo de borrado; índices de consulta | Implementado |
| 137 | Mayoría de edad, licencia y afiliación vigente | Fecha de nacimiento, licencia, número de afiliación emitido por Yavoi! y vigencia ligada a la licencia | Implementado. La carta de no antecedentes es voluntaria porque la fracción III fue invalidada por la SCJN |
| 138 | Responsabilidad solidaria hasta el límite de la póliza del vehículo | Datos de póliza particular y empresarial visibles en el expediente y controles de vigencia | Control implementado. La cobertura y redacción contractual requieren validación jurídica y de la aseguradora |
| 139 | Documentos, revisión y características de cada unidad | Identificación, tarjetón, seguro y recibo, circulación, placas, holograma, VIN, verificación, revisión mecánica, antigüedad, cinturones, bolsas de aire, ABS, herramientas, extinguidor ABC, cuatro puertas, polarizado, aire acondicionado, reflejantes y situación fiscal | Implementado para captura, vigencia y autorización. La autenticidad y revisión física corresponden a Operaciones y la autoridad |

El sistema calcula por separado una estimación de la aportación del 1.5% al Fondo de Movilidad prevista en el artículo 128. Ese cálculo no sustituye la liquidación ni el convenio con la autoridad.

## Controles de privacidad y seguridad

- Los permisos se validan en PostgreSQL; cambiar una pantalla o manipular el navegador no cambia el rol.
- Las tablas de datos personales usan Row Level Security. Documentos y fotografías se conservan en depósitos privados.
- Los archivos se aceptan sólo cuando pertenecen a la carpeta del usuario autenticado.
- Las acciones de Operaciones sobre cumplimiento requieren rol administrador y MFA AAL2.
- Las cotizaciones, solicitudes, cambios de estado, cobros, reembolsos, puntos y cierres aplican validaciones de estado e idempotencia.
- El registro regulatorio conserva instantáneas para que un cambio posterior del perfil no altere la evidencia del viaje ya realizado.
- Los reportes de posible delito se separan de una queja ordinaria y conservan su referencia de entrega a la autoridad.

## Activación en producción

Antes de activar **Obligatorio para nuevas asignaciones**, Operaciones debe:

1. Cargar la autorización estatal y convenio vigentes de la empresa.
2. Cargar la póliza empresarial real, verificar su periodo y confirmar al menos 32 UMA anuales por incidente.
3. Revisar cada expediente y, cuando corresponda, los documentos físicos contra los archivos cargados.
4. Formalizar con la Subsecretaría el formato y canal del informe mensual.
5. Contratar y configurar el proveedor de correo para recibos y la telefonía con números protegidos.
6. Formalizar el canal automático para los avisos del artículo 135; hasta entonces, registrar manualmente folio, autoridad y medio de presentación.
7. Revisar esta matriz al cambiar la ley, el reglamento, el convenio, las pólizas o el funcionamiento de la plataforma.
