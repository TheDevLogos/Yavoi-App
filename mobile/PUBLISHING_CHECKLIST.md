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

## Antes de compilar

1. Instalar Android Studio y JDK 21.
2. Abrir `mobile/passenger/android` y `mobile/driver/android` por separado.
3. En cada proyecto, crear una aplicación independiente en Play Console con el
   paquete de esta tabla y activar Play App Signing.
4. Crear dos clientes Android en Google Cloud, restringidos por paquete y el
   certificado SHA-1 de firma de Play. No reutilizar la clave web.
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

## Compilar y sincronizar

Desde la raíz del proyecto:

```sh
npm run android:passenger:sync
npm run android:driver:sync
```

En Android Studio, selecciona la variante `release` y genera un Android App
Bundle (`.aab`) por cada proyecto. Conserva el `versionCode` creciente en cada
app; ambas pueden tener calendarios de actualización independientes.

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
