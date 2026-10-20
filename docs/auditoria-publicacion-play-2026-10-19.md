# Auditoría de publicación: Yavoi! y Yavoi! Drive

Fecha de revisión: 19 de octubre de 2026, zona horaria de Chihuahua.

## Resultado ejecutivo

Las dos aplicaciones están en estado **Borrador / Prueba interna**. Ninguna versión está actualmente enviada a revisión. El repositorio y la PWA superaron la suite completa de 107 pruebas y la compilación web de producción.

El rechazo de **Yavoi!** no se debe a una falla de cobro, mapas o autenticación: Play identificó previamente una función que requería cuenta de organización. La declaración de funciones financieras ya se corrigió a “Mi app no ofrece ninguna función financiera” y ahora la consola permite enviar sus cambios a revisión.

**Yavoi! Drive** tiene dos bloqueos de envío activos: faltan las declaraciones obligatorias de ubicación y de servicio en primer plano. Hasta resolverlos, Play mantiene deshabilitado el envío de sus cambios.

## Estado en Play Console

| Aplicación | Paquete | Estado | Bloqueo actual |
| --- | --- | --- | --- |
| Yavoi! | `mx.yavoi.pasajero` | Borrador, prueba interna, sin envío activo | La infracción histórica de requisitos de Play Console aparece rechazada el 6 de octubre. Los cambios correctivos ya pueden enviarse a revisión. |
| Yavoi! Drive | `mx.yavoi.conductor` | Borrador, prueba interna, sin envío activo | Declaración de permisos de ubicación incompleta y declaración de servicio en primer plano incompleta. |

### Yavoi! — requisitos de cuenta de Play Console

El Centro de Políticas muestra el rechazo “Infracción de los requisitos de Play Console”. Su explicación indica que una categoría o función declarada requiere cuenta de organización.

La declaración vigente, modificada el 9 de octubre, indica correctamente que la app no ofrece funciones financieras. Es consistente con el producto actual: el pasajero entrega efectivo al conductor y las aplicaciones no gestionan tarjetas, cuentas, CLABE, transferencias, retiros, ni billeteras.

La ficha aún conserva **14 cambios** sin enviar, incluyendo la declaración financiera corregida. Al cierre de esta auditoría, el botón **Enviar 14 cambios a revisión** está habilitado en Yavoi!.

### Yavoi! Drive — permisos bloqueantes

El manifiesto de Drive solicita ubicación precisa, notificaciones, ventana de alerta opcional y estos permisos de servicio en primer plano:

- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_LOCATION`

Play exige completar los dos formularios antes de permitir el envío.

La declaración de ubicación debe describir únicamente el uso real: ubicación precisa mientras el conductor se conecta, recibe una solicitud, llega al origen y navega durante un viaje activo. No debe declararse acceso continuo en segundo plano, porque el manifiesto no solicita `ACCESS_BACKGROUND_LOCATION`.

El permiso de servicio en primer plano requiere una decisión técnica antes de completar la declaración:

1. **Mantener navegación y seguimiento continuo fuera de la app:** implementar un servicio de ubicación en primer plano real, visible para el conductor y iniciado por él al conectarse o iniciar navegación. Después, declarar ese caso de uso con un video de demostración y la justificación correspondiente.
2. **No usar un servicio en primer plano:** quitar ambos permisos del manifiesto y conservar ubicación sólo mientras Yavoi! Drive está visible. La gracia de disponibilidad de un minuto y las notificaciones no sustituyen un servicio en primer plano.

Actualmente el proyecto declara los permisos, pero no contiene una implementación nativa de servicio en primer plano. Por integridad de la declaración, no se debe completar el formulario afirmando que ya existe ese servicio.

## Declaraciones que requieren corrección

| Área | Hallazgo | Corrección necesaria |
| --- | --- | --- |
| Seguridad de los datos, ambas apps | La consola publica “Los datos no están encriptados”. | Marcar cifrado de datos en tránsito si las comunicaciones se realizan por HTTPS/TLS, como las URLs de Vercel y Supabase configuradas. Verificar que cada SDK declarado mantenga TLS. |
| Detalles de acceso, ambas apps | Declara “Todas las funcionalidades se encuentran disponibles sin acceso especial”. | Proveer cuentas de prueba y pasos de acceso para revisor. El portal exige autenticación para viajes, perfil, solicitudes y funciones de conductor. |
| Funciones financieras, ambas apps | Ya indica que no ofrece funciones financieras. | Mantener esa respuesta. No describir conciliaciones internas, impuestos, comisión semanal o cobro en efectivo como producto financiero. |
| Permisos de ubicación, Drive | Formulario obligatorio pendiente. | Completarlo después de decidir el alcance real de primer plano. |
| Servicio en primer plano, Drive | Formulario obligatorio pendiente. | Implementar el servicio real o retirar los permisos antes de enviar. |
| Ventana sobre otras apps, Drive | Permiso especial `SYSTEM_ALERT_WINDOW`; no es bloqueante hoy. | Mantenerlo opcional, iniciado desde la pantalla de permisos y con alternativa de alertas normales. Probar que negar este permiso no bloquea conducir. |

## Coherencia funcional revisada

- El flujo de cotización, tarifa fija aceptada, ajustes posteriores, efectivo, detalle de viaje, navegación, llegada, cobro final y sincronización pasajero-conductor está cubierto por pruebas automatizadas.
- El módulo de conductor muestra un corte semanal y permite cargar comprobante para la conciliación de Operaciones; no ofrece transferencia, retiro, saldo disponible, CLABE ni billetera.
- El perfil de pasajero indica pago directo en efectivo al conductor y no solicita datos de tarjeta.
- Operaciones conserva cálculos de comisión, impuestos y conciliación para uso interno. Esta capacidad no debe presentarse como servicio financiero para los usuarios.
- Google Sign-In nativo, permisos de notificación, Mapas, navegación y la recuperación de intentos de inicio de sesión tienen pruebas de regresión en el repositorio.
- La página de privacidad, términos y eliminación de cuenta está publicada en el mismo dominio. La consola muestra la URL de eliminación de cuenta correctamente.

## Versiones y artefactos locales

| Aplicación | Configuración local | AAB local |
| --- | --- | --- |
| Yavoi! | `versionCode 15`, `versionName 1.0.14` | Generado el 12 de octubre. |
| Yavoi! Drive | `versionCode 19`, `versionName 1.0.18` | Generado el 13 de octubre. |

La consola aún muestra como lanzamiento pendiente la versión `2 (1.0.1)` en ambas aplicaciones. Por ello, antes del próximo envío debe subirse el AAB local más reciente de cada aplicación a su canal interno y revisarse que Play muestre los códigos 15 y 19, respectivamente.

## Evidencia técnica

- `npm test`: 107 pruebas aprobadas, sin fallos.
- `npm run build`: compilación de producción aprobada.
- La rama `main` está limpia al cerrar la auditoría.
- Producción/PWA se sirve desde `https://yavoi-app.vercel.app`.

## Secuencia segura para reanudar la publicación

1. Decidir e implementar el alcance real del servicio de ubicación en primer plano de Drive, o retirar sus permisos.
2. Completar la declaración de ubicación de Drive con el flujo real y consentimiento contextual.
3. Completar la declaración de servicio en primer plano de Drive sólo si existe el servicio nativo real.
4. Corregir Seguridad de los datos en ambas apps para indicar cifrado en tránsito, y revisar los ocho tipos de datos declarados contra privacidad y SDKs.
5. Sustituir los Detalles de acceso por dos cuentas de revisión y pasos reproducibles: una de pasajero y una de conductor autorizado.
6. Subir los AAB actuales, verificar sus códigos de versión, y enviar cada aplicación a revisión por separado.
7. Tras la aceptación de Play, ejecutar el guion de verificadores de Drive y el equivalente de pasajero en prueba interna.

## Límites de esta auditoría

Esta auditoría no envió formularios, no modificó declaraciones de Play Console y no publicó AABs. Esas acciones cambian el expediente oficial y deben realizarse una vez elegida la alternativa de servicio en primer plano y preparadas las cuentas de revisión.

