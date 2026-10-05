# Firebase para las apps Android de Yavoi!

El proyecto Firebase `yavoi-4a7af` contiene estas apps:

| Aplicación | ID Android | Configuración local |
| --- | --- | --- |
| Yavoi! Pasajero | `mx.yavoi.pasajero` | `mobile/passenger/android/app/google-services.json` |
| Yavoi! Conductor | `mx.yavoi.conductor` | `mobile/driver/android/app/google-services.json` |

Cada archivo `google-services.json` se descarga desde la ficha de su app Android en Firebase Console. Se mantiene local y está excluido de Git; no lo elimines ni lo agregues al repositorio. El proyecto ya aplica Google Services Gradle Plugin y Capacitor Push Notifications al sincronizar las plataformas nativas.

## Flujo nativo implementado

1. En Perfil, al activar las alertas, Android solicita el permiso de notificaciones.
2. Firebase emite el token FCM del dispositivo y la app lo registra en Supabase mediante `yavoi_register_native_push`.
3. La función `push-driver-alert` envía las solicitudes de viaje a tokens FCM y sigue enviando Web Push a navegadores. La notificación nativa usa el canal `yavoi_trips`, prioridad alta y el vencimiento real de la oferta (8 segundos).
4. Al abrir una notificación, la app vuelve a consultar las ofertas vigentes para mostrar la solicitud y permitir aceptarla dentro de Yavoi!.

Los tokens FCM se guardan en una tabla privada con RLS y sin acceso directo desde el cliente. La función permite que cada perfil registre solamente su propio token.

## Estado de activación

| Componente | Android Pasajero | Android Conductor | iPhone Pasajero | iPhone Conductor |
| --- | --- | --- | --- | --- |
| App nativa y registro de token | Preparado | Preparado | Pendiente de Xcode | Pendiente de Xcode |
| `google-services.json` | Local | Local | No aplica | No aplica |
| Envío desde Supabase | Pendiente de secreto | Pendiente de secreto | Pendiente de APNs y secreto | Pendiente de APNs y secreto |
| Prueba real en dispositivo | Pendiente | Pendiente | Pendiente | Pendiente |

## Preparación de la cuenta de servidor FCM

Para habilitar el envío FCM desde Supabase, en Google Cloud del proyecto `yavoi-4a7af`:

1. Habilita **Firebase Cloud Messaging API**.
2. Crea una cuenta de servicio dedicada para Yavoi! y otórgale el rol **Firebase Cloud Messaging API Admin**.
3. Genera una clave JSON de esa cuenta de servicio. Consérvala privada: nunca va en el APK, en el frontend ni en Git.
4. Guarda el JSON completo en los secretos de Supabase con el nombre `FIREBASE_SERVICE_ACCOUNT_JSON`.
5. La migración `20261004051441_native_firebase_push_tokens.sql` y la versión 6 de la función `push-driver-alert` ya están desplegadas en el proyecto Supabase `asjlyureqokifjkpdwgc`.

### Pendiente único para activar los avisos Android

El backend y las dos apps ya están preparados. Falta cargar **una única**
credencial oficial de la cuenta de servicio en el secreto de Supabase. Al
guardar `FIREBASE_SERVICE_ACCOUNT_JSON`, hacer esta comprobación en un teléfono
Android real:

1. Instalar el AAB mediante la prueba interna de Google Play.
2. Iniciar sesión como conductor, aceptar el permiso de notificaciones y
   activar Alertas persistentes desde el Perfil.
3. Confirmar que se creó un registro activo en `native_push_tokens`.
4. Crear una solicitud de viaje de pasajero y comprobar que la alerta llega,
   abre Yavoi! y muestra una oferta vigente.

No se debe generar otra clave ni copiar el JSON al repositorio. Si se rota la
credencial, actualizar el secreto primero y revocar después la clave anterior
en Google Cloud.

La función valida que el `project_id` de la credencial sea `yavoi-4a7af`. Mientras falte el secreto, las solicitudes siguen usando Web Push donde exista una suscripción; la ruta nativa se habilitará cuando el secreto esté guardado.

## Generar los APK de prueba

Ejecuta desde la raíz del proyecto:

```sh
npm run android:passenger:sync
npm run android:driver:sync
```

Después abre cada proyecto Android en Android Studio y genera su APK. Para publicar, usa una compilación firmada de tipo **Android App Bundle (AAB)** distinta por aplicación. En Android 13 o posterior, concede el permiso de notificaciones en el dispositivo y activa alertas desde Yavoi!.

## iPhone

El registro Firebase realizado hasta ahora es para Android. La integración push
de iOS requiere estos pasos antes de enviar a App Review:

1. Instalar Xcode completo y agregar `@capacitor/ios` al proyecto.
2. Crear los proyectos nativos para `mx.yavoi.pasajero` y
   `mx.yavoi.conductor`.
3. Registrar ambos Bundle ID en Apple Developer, habilitar **Push
   Notifications** y crear la clave APNs para Firebase.
4. Añadir cada app iOS a Firebase y colocar su `GoogleService-Info.plist`
   dentro de su proyecto iOS, sin versionarlo.
5. Configurar el equipo de firma, perfiles de aprovisionamiento, iconos,
   permisos de ubicación y textos de privacidad en Xcode.
6. Probar registro de token, alerta en primer plano, en segundo plano y al
   tocar una notificación desde un iPhone real.
