# Guion de prueba interna — Yavoi! Drive

Fecha de preparación: 13 de octubre de 2026.

## Paquete preparado

- Aplicación: `mx.yavoi.conductor` — **Yavoi! Drive**.
- Versión instalada de referencia: `1.0.18` (código `19`).
- El contenedor Android abre `https://yavoi-app.vercel.app/portal.html`; por ello carga los cambios vigentes del portal al abrir o recargar la aplicación.
- La compilación de validación se generó correctamente con Firebase, Google Sign-In, Maps y Navigation SDK incluidos.

## Antes de iniciar

1. Abrir el enlace de prueba interna y aceptar la invitación con la cuenta de Google registrada como verificador.
2. Instalar o actualizar Yavoi! Drive desde Google Play.
3. Iniciar sesión con una cuenta de conductor autorizada.
4. En el asistente inicial aceptar ubicación precisa y notificaciones. En Android, aceptar también **Mostrar sobre otras apps** si se desea ver avisos sobre otra aplicación.
5. Confirmar que la pantalla **Conducir** muestra el mapa de Google y no una pantalla de error.

## Recorrido de verificación

| Caso | Acción | Resultado esperado |
| --- | --- | --- |
| Inicio de sesión | Entrar con Google, cerrar y volver a entrar con otra cuenta autorizada | El selector de Google permite elegir otra cuenta y la app no queda detenida en la pantalla de acceso. |
| Permiso operativo | Abrir **Mi perfil** | Se muestra el estado del permiso, la causa específica si está bloqueado y la siguiente acción. |
| Corte semanal | Con un corte pendiente o vencido, abrir **Mi perfil** | Se muestra el importe de retención comercial y el botón **Cargar comprobante de pago**. |
| Comprobante | Subir un JPG, PNG o PDF menor a 5 MB | El corte cambia a **En revisión** y llega un aviso a la Bandeja de Entrada. |
| Conciliación | Desde Operaciones, abrir el comprobante, conciliar el importe exacto y marcar autorización | El conductor recibe un comprobante de conciliación y su permiso cambia a activo si su expediente sigue vigente. |
| Conexión | Mantener pulsado **Conectarme** durante un turno activo | La cuenta se conecta. Si existe un bloqueo, el mensaje identifica expediente, documento, corte o autorización. |
| Oferta | Enviar una solicitud de viaje al conductor | Llega alerta visible y sonora; al aceptarla se abre la navegación nativa hacia la recolección. |
| Recolección | Pulsar **Avisar que ya llegué** y después **Iniciar viaje** | El pasajero sólo pasa a viaje en curso después de iniciar el viaje. |
| Navegación | Llegar al destino y confirmar el efectivo | El total final incluye espera y ajustes aceptados; al confirmar, el viaje termina para ambas cuentas. |
| Cola | Aceptar una segunda oferta durante un viaje | Se agrega a la cola y, al terminar el primero, continúa la navegación hacia la nueva recolección. |
| Notificaciones | Minimizar Drive y enviar una oferta o aviso | La notificación abre la aplicación y lleva al viaje u opción indicada. |

## Criterio para reportar un defecto

Compartir captura de pantalla, hora aproximada, correo de prueba, modelo del dispositivo, versión de Android y los pasos exactos. No incluir contraseñas, comprobantes bancarios completos ni claves en el reporte.

## Límites de esta prueba

- La disponibilidad de ubicación en segundo plano y las alertas sobre otras aplicaciones dependen de los permisos que el verificador acepte y de la política de batería del dispositivo.
- La confirmación de una notificación real requiere un dispositivo físico registrado en Firebase; el emulador no sustituye esa validación.
- La navegación requiere conectividad, ubicación precisa y que la clave de Navigation SDK conserve las restricciones configuradas para el paquete y certificado de Drive.
