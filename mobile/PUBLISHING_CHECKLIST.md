# Publicación Android de Yavoi!

## Aplicaciones creadas

| Aplicación | Paquete | Cuenta permitida |
| --- | --- | --- |
| Yavoi! | `mx.yavoi.pasajero` | Pasajero |
| Yavoi! Drive | `mx.yavoi.conductor` | Conductor |

Los perfiles, viajes, pagos y Operaciones siguen usando la misma instancia de
Supabase. Para separar usos, una persona puede registrar un correo como
pasajero y otro como conductor. Supabase conserva el tipo de cada perfil; cada aplicación solo permite
el tipo de cuenta que le corresponde.

## Estado de versiones Android

Ambas apps tienen publicada la actualización de prueba interna `1.0.1`
(`versionCode` 2), firma de carga local independiente y `targetSdkVersion` 36.
Google Play exige API 36 para nuevas publicaciones desde el 31 de agosto de
2026. La firma y sus contraseñas permanecen en archivos ignorados por Git;
deben respaldarse en un almacén seguro de Yavoi! antes de publicar.

| Aplicación | SHA-1 de la firma de carga |
| --- | --- |
| Yavoi! | `4E:F5:34:08:96:66:6B:F1:45:91:2E:38:61:5A:34:E1:29:AC:58:CC` |
| Yavoi! Drive | `83:00:E6:9F:EB:9A:F0:F8:0C:DB:9A:34:71:2D:89:1D:96:4C:22:3D` |

## Estado en Google Play Console

Las dos fichas ya están creadas en la cuenta de desarrollador de Yavoi! y usan
los paquetes indicados arriba. La versión `1.0.1-internal` (código 2) de
**Yavoi!** y **Yavoi! Drive** ya está publicada en sus canales de prueba
interna. Ambas aparecen como disponibles para verificadores internos y sin
revisión; Google Play mostrará el nombre temporal del paquete hasta que se
complete la ficha y la revisión de cada aplicación.

La prueba interna admite hasta 100 personas, pero no queda disponible hasta
crear el segmento de verificadores. Para solicitar acceso a producción, Google
Play exige una prueba cerrada con al menos 12 verificadores inscritos durante
14 días continuos para cada aplicación.

## Avance hacia producción mientras se integran los verificadores

| Frente | Estado actual | Siguiente acción concreta |
| --- | --- | --- |
| Nombre visible | Versión `1.0.1` (`versionCode` 2) publicada en prueba interna: **Yavoi!** y **Yavoi! Drive** | Completar los recursos y la revisión de ficha para sustituir el nombre temporal que muestra Play durante las pruebas. |
| Textos de ficha | Listos y guardados como borrador en ambas apps | Revisarlos junto con los recursos visuales antes de enviar la ficha a revisión. |
| Recursos de Play | Pendiente | Preparar por cada app: ícono PNG/JPEG de 512×512, gráfico destacado de 1024×500 y entre 2 y 8 capturas de teléfono. Se recomienda usar 4 capturas de 1080 px o más por lado. |
| Ficha y cumplimiento | Pendiente | Confirmar correo y sitio de soporte, categoría, anuncios, datos de contacto, política de privacidad, seguridad de datos, clasificación de contenido, acceso de revisión y eliminación de cuenta. |
| Push nativo Android | Integración lista; envío pendiente | Cargar el secreto privado `FIREBASE_SERVICE_ACCOUNT_JSON` en Supabase y validarlo en teléfonos reales. Consultar `FIREBASE_SETUP.md`. |
| Mapas y pagos | Funcionalidad en desarrollo | Restringir claves de Maps para cada paquete y certificado de firma de Play; agregar credenciales productivas de Mercado Pago y validar webhooks antes de cobrar a público real. |
| Seguimiento del conductor | Pendiente de implementación nativa completa | Antes de solicitar ubicación en segundo plano, añadir el servicio visible de seguimiento, aviso previo y sus declaraciones en Play. |
| Prueba cerrada | En espera de verificadores | Crear dos listas de al menos 12 cuentas de Google, publicar las dos versiones de prueba cerrada y conservar la inscripción durante 14 días. |
| iOS | Pendiente de Xcode y Apple Developer | Crear ambos proyectos nativos, configurar APNs/Firebase, firma y pruebas físicas antes de App Review. |

No se debe solicitar producción ni publicar a usuarios generales hasta completar
los recursos obligatorios, las declaraciones de Play y las pruebas reales de
los recorridos, cobros, notificaciones y eliminación de cuenta.

## Antes de subir a Play Console

1. Instalar Android Studio y JDK 21.
2. Abrir `mobile/passenger/android` y `mobile/driver/android` por separado.
3. En cada proyecto, crear una aplicación independiente en Play Console con el
   paquete de esta tabla y activar Play App Signing. Después de la primera
   carga, añadir también a Firebase los certificados SHA-1 y SHA-256 que Play
   muestre como certificados de firma de la aplicación.
4. Crear dos clientes Android en Google Cloud sólo si se integra el SDK nativo
   de Maps, restringidos por paquete y certificado SHA-1 de firma de Play. No
   reutilizar la clave web.
5. Añadir el `google-services.json` de Firebase correspondiente a cada paquete.
   Nunca confirmar esos archivos al repositorio.
6. Configurar Firebase Cloud Messaging y las credenciales oficiales de Mercado
   Pago antes de abrir una prueba cerrada.

## Permisos actuales

Las dos apps solicitan red, ubicación aproximada/precisa y notificaciones.
La app de conductor todavía **no solicita ubicación en segundo plano**: se
agregará junto con el servicio nativo de seguimiento, su notificación visible,
el aviso previo y la declaración de Play Console. Esto evita pedir un permiso
sensible antes de tener la función nativa completa.

## Compilar, firmar y localizar los AAB

Desde la raíz del proyecto:

```sh
npm run android:passenger:sync
npm run android:driver:sync
```

En Android Studio, selecciona la variante `release` y genera un Android App
Bundle (`.aab`) por cada proyecto. También puedes ejecutar
`./gradlew :app:bundleRelease` dentro de cada carpeta `android`.

Los AAB de la primera versión quedan en:

- `mobile/passenger/android/app/build/outputs/bundle/release/app-release.aab`
- `mobile/driver/android/app/build/outputs/bundle/release/app-release.aab`

Conserva un `versionCode` estrictamente creciente en cada aplicación; ambas
pueden actualizarse por separado.

## Configuración de Play Console antes de enviar a revisión

1. Crear primero **Yavoi!** como app de tipo Aplicación, gratuita,
   idioma español (México), paquete `mx.yavoi.pasajero`.
2. Activar Play App Signing y cargar el AAB de Pasajero en **Prueba interna**.
3. Completar la ficha de tienda, correo de soporte, política de privacidad,
   seguridad de datos, clasificación de contenido, acceso de revisión y
   eliminación de cuenta. Las dos últimas deben describir exactamente el
   registro, ubicación, pagos y documentos que ya usa Yavoi!.
4. Repetir el flujo para **Yavoi! Drive** con el paquete
   `mx.yavoi.conductor`. Declarar ubicación precisa, notificaciones,
   cámara/archivos para documentos y la finalidad operativa de cada permiso.
5. Ejecutar la prueba cerrada de ambos perfiles antes de crear una versión de
   producción. No enviar a revisión hasta validar registro, cobro y alertas en
   dispositivos reales.

## Pruebas obligatorias antes de producción

- Pasajero: registro, ubicación, destino, cotización, tarjeta, efectivo,
  ajustes, cancelación, recibo y eliminación de cuenta.
- Conductor: autorización, conexión, oferta, notificación con la app cerrada,
  aceptación, navegación, llegada, espera, cobro, cierre y retiro.
- Dispositivos: Android de gama media y baja, ahorro de batería, sin señal,
  llamadas y aplicaciones superpuestas.
- Play Console: ficha, política de privacidad, seguridad de datos, eliminación
  de cuenta, clasificación de contenido, contacto de soporte y cuentas de
  prueba para revisores.
