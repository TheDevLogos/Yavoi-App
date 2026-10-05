# Publicación Android de Yavoi!

## Aplicaciones creadas

| Aplicación | Paquete | Cuenta permitida |
| --- | --- | --- |
| Yavoi! Pasajero | `mx.yavoi.pasajero` | Pasajero |
| Yavoi! Conductor | `mx.yavoi.conductor` | Conductor |

Los perfiles, viajes, pagos y Operaciones siguen usando la misma instancia de
Supabase. Para separar usos, una persona puede registrar un correo como
pasajero y otro como conductor. Supabase conserva el tipo de cada perfil; cada aplicación solo permite
el tipo de cuenta que le corresponde.

## Estado de la primera versión Android

Ambas apps quedan preparadas para la primera publicación con versión `1.0.0`
(`versionCode` 1), firma de carga local independiente y `targetSdkVersion` 36.
Google Play exige API 36 para nuevas publicaciones desde el 31 de agosto de
2026. La firma y sus contraseñas permanecen en archivos ignorados por Git;
deben respaldarse en un almacén seguro de Yavoi! antes de publicar.

| Aplicación | SHA-1 de la firma de carga |
| --- | --- |
| Yavoi! Pasajero | `4E:F5:34:08:96:66:6B:F1:45:91:2E:38:61:5A:34:E1:29:AC:58:CC` |
| Yavoi! Conductor | `83:00:E6:9F:EB:9A:F0:F8:0C:DB:9A:34:71:2D:89:1D:96:4C:22:3D` |

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

1. Crear primero **Yavoi! Pasajero** como app de tipo Aplicación, gratuita,
   idioma español (México), paquete `mx.yavoi.pasajero`.
2. Activar Play App Signing y cargar el AAB de Pasajero en **Prueba interna**.
3. Completar la ficha de tienda, correo de soporte, política de privacidad,
   seguridad de datos, clasificación de contenido, acceso de revisión y
   eliminación de cuenta. Las dos últimas deben describir exactamente el
   registro, ubicación, pagos y documentos que ya usa Yavoi!.
4. Repetir el flujo para **Yavoi! Conductor** con el paquete
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
