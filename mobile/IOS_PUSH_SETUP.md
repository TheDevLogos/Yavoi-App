# iOS: notificaciones push y Firebase

## Estado preparado en el proyecto

- Bundle IDs: `mx.yavoi.pasajero` y `mx.yavoi.conductor`.
- Entitlement `aps-environment` configurado como `development` en Debug y `production` en Release.
- Capacitor Push Notifications y Geolocation están incluidos en los dos proyectos iOS.

## Al contar con Apple Developer Program

1. Registra ambos Bundle IDs en Certificates, Identifiers & Profiles y habilita **Push Notifications**.
2. En Firebase Console, descarga el archivo de configuración de cada app iOS y colócalo en:
   - `mobile/passenger/ios/App/App/GoogleService-Info.plist`
   - `mobile/driver/ios/App/App/GoogleService-Info.plist`
3. En Xcode, añade cada archivo a su target `App` y verifica que se copie en el bundle.
4. En Firebase Console, configura una clave APNs de producción para el equipo de Apple. La clave `.p8` no se guarda en este repositorio.
5. Abre cada proyecto en Xcode, selecciona el equipo de firma, deja que Xcode cree los perfiles y prueba una notificación en un iPhone físico.
6. Confirma en Firebase que cada token de dispositivo se registra y envía una notificación de prueba en segundo plano y con la app cerrada.

No publiques una versión que prometa notificaciones persistentes hasta aprobar esas pruebas físicas.
