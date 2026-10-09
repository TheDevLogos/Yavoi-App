# Manual breve de operación y publicación

Este manual separa lo que puede prepararse en el proyecto de las credenciales
que sólo deben agregarse desde las cuentas oficiales de Yavoi!.

## 1. Preparar una versión

1. Actualizar la versión Android y el número de compilación iOS de cada app.
2. Ejecutar `npm test`, `npm run build:passenger` y `npm run build:driver`.
3. Sincronizar la plataforma correspondiente con `npm run android:passenger:sync`,
   `npm run android:driver:sync`, `npm run ios:passenger:sync` o
   `npm run ios:driver:sync`.
4. Generar un AAB firmado por cada app desde Android Studio. En macOS con Xcode,
   archivar y distribuir cada proyecto iOS de forma independiente.
5. Ejecutar el plan de `DEVICE_TEST_PLAN.md`, guardar evidencia y bloquear la
   promoción de versión si fallan asignación, cobro, cierre, notificaciones o
   eliminación de cuenta.

## 2. Firebase Cloud Messaging

1. Crear un proyecto Firebase de Yavoi! y registrar `mx.yavoi.pasajero` y
   `mx.yavoi.conductor` como apps Android; registrar los mismos dos identificadores
   de paquete en Apple Developer y Firebase para iOS.
2. Descargar los archivos nativos en las carpetas locales indicadas por
   `FIREBASE_SETUP.md`; nunca agregarlos a Git.
3. Crear la cuenta de servicio de Firebase y guardar su JSON únicamente como el
   secreto `FIREBASE_SERVICE_ACCOUNT_JSON` de Supabase.
4. Configurar APNs en Firebase antes de habilitar notificaciones de iPhone.
5. Probar en dispositivos reales el registro, recepción en primer plano, segundo
   plano y toque de notificación. Una oferta sólo se considera válida si abre el
   viaje que corresponde y respeta su vencimiento.

## 3. Google Maps Platform

1. Crear una clave web restringida al dominio de producción para la aplicación
   web y claves Android/iOS separadas para los binarios nativos.
2. Limitar cada clave por API: Maps JavaScript, Places y Routes sólo cuando la
   versión realmente las use.
3. Configurar presupuestos, alertas de cuota y restricciones por paquete,
   certificado y dominio.
4. Verificar origen, destino, búsqueda de direcciones, destinos frecuentes,
   rutas, tarifa y navegación en los recorridos de prueba.

## 4. Modelo de efectivo y corte semanal

1. El pasajero paga al conductor directamente en efectivo al finalizar el servicio.
2. La aplicación conserva la tarifa, ajustes, comisión e impuestos como detalle del viaje.
3. Operaciones realiza el corte semanal, comunica la cuota aplicable y autoriza la continuidad operativa del conductor.
4. No configurar ni usar cuentas bancarias, tarjetas, retiros, transferencias o proveedores de pago en esta versión.

## 5. Google Play y App Store

1. En Play Console, cargar por app su icono, gráfico destacado y capturas reales
   usando `store-assets/` y `SCREENSHOT_CAPTURE_GUIDE.md`.
2. Revisar los textos de `STORE_LISTING_COPY.md` y confirmar los datos reales
   antes de guardarlos.
3. Completar privacidad, seguridad de datos, clasificación, acceso de revisión y
   contacto de soporte con información verdadera de la versión enviada.
4. Mantener la prueba cerrada de Google Play con 12 verificadores durante 14
   días por aplicación antes de solicitar producción.
5. En App Store Connect, crear dos registros, cargar los iconos opacos de 1024
   px y realizar archivos firmados desde Xcode. No activar ubicación en segundo
   plano hasta contar con el servicio nativo visible y probado.

## 6. Operación diaria

- Operaciones autoriza conductores después de validar sus cuatro documentos.
- Conductores se conectan manualmente; la disponibilidad no inicia por defecto.
- Cada viaje conserva tarifa, ajustes, comisión y retenciones para conciliación interna. Finanzas revisa los cierres semanales y mensuales antes de declarar impuestos.
- Atención revisa reportes, cancelaciones y solicitudes de eliminación desde
  los canales definidos, respetando el plazo de conservación legal aplicable.
