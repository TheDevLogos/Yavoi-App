# Integración nativa de navegación para Yavoi! Drive

**Estado:** pendiente de integrar en los contenedores nativos Android e iOS.  
**Última actualización:** 7 de octubre de 2026.

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

## Android: trabajo pendiente

1. Abrir el proyecto de conductor en `mobile/driver/android` con Android Studio.
2. Confirmar el identificador de aplicación `mx.yavoi.conductor`.
3. Obtener la huella SHA-1 de Play App Signing desde Google Play Console tras cargar la primera compilación firmada.
4. Crear o restringir la clave Android con el paquete y esa huella.
5. Agregar Navigation SDK for Android y su clave mediante secretos locales o configuración de compilación; no en código fuente.
6. Crear un puente Capacitor, por ejemplo `YavoiNavigation`, que reciba:
   - `tripId`
   - etapa: `pickup` o `destination`
   - coordenadas y texto del destino
   - datos resumidos del pasajero y servicio
7. Presentar la navegación como pantalla o vista nativa sobre el mapa.
8. Mantener visibles estos controles nativos:
   - **Avisar que ya llegué** durante recolección.
   - **Iniciar viaje** cuando el conductor llegó.
   - **Finalizar y recolectar dinero** para viajes en efectivo.
   - **Finalizar viaje** para pago electrónico.
   - **Abrir detalle**, mensajes, seguridad y nuevas solicitudes.
9. En cada cambio de etapa, actualizar el destino de la sesión de navegación sin cerrar la vista.
10. Al detectar llegada mediante geocerca y GPS, regresar al panel operativo del viaje y conservar el estado que confirme el servidor.

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
