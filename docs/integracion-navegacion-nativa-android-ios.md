# Integración nativa de navegación para Yavoi! Drive

**Estado:** Android integrado y compilado; activación en dispositivo pendiente de clave Android restringida. iOS pendiente.
**Última actualización:** 8 de octubre de 2026.

## Objetivo

Mantener al conductor dentro de Yavoi! Drive durante todo el servicio y mostrar navegación guiada en el mapa de la aplicación, con instrucciones por voz, ubicación en tiempo real, notificaciones de nuevos viajes y controles de operación visibles.

La PWA ya ofrece el flujo equivalente para pruebas web:

- Al aceptar una solicitud, abre el viaje en Yavoi! y muestra la navegación hacia la recolección.
- Al llegar, permite avisar que llegó e iniciar el viaje.
- Al iniciar, cambia el destino al punto de entrega.
- Al llegar, permite finalizar el servicio y cobrar cuando el método es efectivo.
- El conductor puede abrir Google Maps desde un botón si requiere navegación por voz durante las pruebas web.

## Límite de la PWA

El Navigation SDK de Google Maps no puede ejecutarse dentro de una PWA. Google lo distribuye para Android e iOS nativos. Por ello, la navegación dentro de la app debe incorporarse a los proyectos Capacitor cuando se compilen Yavoi! Drive para cada plataforma.

## Proyecto y credenciales de Google Cloud

Proyecto de Google Cloud: `yavoi-508302`.

Servicios ya habilitados o previstos:

- Navigation SDK for Android.
- Navigation SDK for iOS.
- Maps SDK for Android.
- Maps SDK for iOS.
- Places API.
- Routes API.

### Claves

- La clave de iOS se creó con restricción para el bundle `mx.yavoi.conductor`.
- Antes de publicar, reducir sus APIs permitidas a Navigation SDK for iOS y Maps SDK for iOS.
- La clave Android debe restringirse por el certificado SHA-1 de **Play App Signing** y por el paquete `mx.yavoi.conductor`.
- Nunca guardar claves de Google en el repositorio ni mostrarlas en la interfaz.

## Android: integrado en Yavoi! Drive

La versión `1.0.3` (`versionCode` 4) incorpora el Navigation SDK for Android en el contenedor Capacitor de Yavoi! Drive.

- `YavoiNavigationPlugin` recibe la etapa, el viaje y las coordenadas desde la interfaz web.
- `YavoiNavigationActivity` muestra `SupportNavigationFragment` de Google: guía giro a giro, voz, ETA, trayecto, indicador de velocidad y recálculo de ruta nativos.
- Una tarjeta Yavoi! superpuesta conserva los controles **Avisar que ya llegué**, **Iniciar viaje**, **Finalizar y recolectar dinero** o **Finalizar viaje**, según la etapa y método de pago.
- Al terminar cada interacción se devuelve a la interfaz de Yavoi! para aplicar la transición que valida el servidor.
- Las notificaciones existentes siguen disponibles mientras está abierta la navegación.
- El paquete firmado se genera en `mobile/driver/android/app/build/outputs/bundle/release/app-release.aab`.

### Configuración aplicada y cierre de seguridad pendiente

Se creó `Yavoi Drive Android Navigation` con acceso limitado a **Navigation SDK** y **Maps SDK for Android**. La clave se agregó al equipo de compilación sin incluirla en Git.

1. En Play Console, abrir la versión que se firme con Play y copiar el SHA-1 del **certificado de firma de la aplicación** (no el de carga).
2. Editar esta misma clave en Google Cloud y restringirla a `mx.yavoi.conductor` y a ese SHA-1.
3. La clave ya está guardada sin comillas en `mobile/driver/android/local.properties`:

   ```properties
   YAVOI_NAVIGATION_API_KEY=clave_android_restringida
   ```

   También se admite la variable de entorno `YAVOI_NAVIGATION_API_KEY` durante la compilación. El archivo está ignorado por Git.
4. Se recompiló el AAB firmado con esta clave. Tras publicar la versión interna, aplicar la restricción de aplicación indicada en los pasos 1 y 2.

### Clave de carga

La nueva clave de carga de Drive coincide con la configuración `release` y se verificó al firmar el AAB de versión 4. Su certificado SHA-1 es `24:5B:EF:5A:35:BE:37:34:D6:9B:F3:C4:AF:78:4D:AF:99:0D:5C:90`.

El 8 de octubre de 2026 se solicitó en Play Console el restablecimiento de la clave de carga porque la clave anterior no está disponible. La consola confirma que la solicitud está pendiente. Hasta que Google la active, Play rechazará AAB firmados con la nueva clave; no hay una corrección local que sustituya esa aprobación. Tras su activación, se descarta el borrador que contiene el AAB firmado con una clave ajena y se carga el AAB de versión 4. Esta huella sirve para la carga local; para la clave de Maps distribuida por Play se utiliza la huella de **firma de la aplicación** mostrada por Play Console.

### Android Auto

La integración de teléfono queda preparada para compartir el mismo contrato de viaje y las transiciones validadas por el servidor. Android Auto requiere una integración adicional de Google en vista previa: `CarAppService`, la biblioteca Android for Cars y `NavigationViewForAuto`, además de la aprobación específica de Google para apps de navegación. No se declara soporte de Android Auto en esta compilación hasta completar esa revisión, para que las pruebas internas no presenten una función incompleta.

## iOS: trabajo pendiente

1. Abrir `mobile/driver/ios` con Xcode.
2. Confirmar bundle ID `mx.yavoi.conductor` y el equipo de Apple Developer.
3. Agregar Navigation SDK for iOS con Swift Package Manager o CocoaPods, según la versión compatible seleccionada.
4. Añadir la clave iOS restringida en configuración local de Xcode, sin incluirla en Git.
5. Implementar el mismo puente `YavoiNavigation` que Android y el mismo contrato de datos.
6. Configurar permisos de ubicación:
   - Al usar la app.
   - Siempre, sólo cuando sea indispensable para seguimiento de trayectos y con explicación clara.
7. Validar funcionamiento en iPhone físico, incluida la recuperación al volver desde segundo plano.

## Contrato funcional del puente nativo

La capa web debe poder iniciar la navegación con una interfaz equivalente a esta:

```text
startNavigation({
  tripId,
  stage: "pickup" | "destination",
  destination: { lat, lng, label },
  passengerName,
  paymentMethod,
  tripSummary
})
```

Y recibir eventos nativos:

```text
arrivalDetected({ tripId, stage })
navigationError({ tripId, message })
navigationClosed({ tripId })
```

El servidor sigue siendo la fuente de verdad: la app debe solicitar la transición de viaje a Supabase y actualizar la interfaz sólo después de que la transición sea aceptada.

## Notificaciones durante navegación

- Firebase Cloud Messaging mantiene las notificaciones de solicitudes de viaje y mensajes.
- En iOS, configurar APNs y cargar `GoogleService-Info.plist` en el proyecto de conductor.
- En Android, usar el canal `yavoi_trips` con prioridad alta para solicitudes de viaje.
- Si hay un viaje en curso, las solicitudes en cola no deben ocultar la navegación ni modificar la etapa actual.
- Sólo presentar opciones de aceptar viajes adicionales cuando el conductor sea elegible conforme a las reglas operativas vigentes.

## Flujo de validación previo a producción

1. Aceptar un viaje y confirmar que inicia navegación hacia recolección dentro de Yavoi! Drive.
2. Recibir una solicitud adicional sin perder la navegación actual.
3. Detectar llegada o usar **Avisar que ya llegué** y confirmar transición a `arrived`.
4. Iniciar viaje y comprobar que se actualiza el destino sin abandonar la navegación.
5. Completar viaje en efectivo y confirmar monto final, cambio y conciliación.
6. Completar viaje electrónico y confirmar estado del cobro y recibo.
7. Minimizar y restaurar la aplicación: verificar ubicación, navegación y notificaciones.
8. Probar pérdida temporal de señal, cancelación y cierre de navegación.

## Archivos web relacionados

- `src/portal.js`: flujo PWA, transiciones de viaje y botón de Google Maps.
- `src/portal.css`: controles superpuestos de navegación dentro del mapa.
- `mobile/driver/`: contenedor Capacitor que recibirá el plugin nativo.

## Referencia de cambio web

El flujo PWA se incorporó al repositorio en el commit `8ab0896` (`Keep PWA driver navigation in app`).
