# Auditoría de paridad web, PWA y aplicaciones nativas — 7 de octubre de 2026

## Alcance

Se revisó el código que construye la aplicación web instalada (PWA), Yavoi! Pasajero (`mx.yavoi.pasajero`) y Yavoi! Drive (`mx.yavoi.conductor`). La revisión confirma la presencia de los controles en el repositorio; las configuraciones de Supabase, Firebase, Google Maps, Mercado Pago y las tiendas requieren comprobación directa antes de operar con personas o dinero reales.

## Resultado

| Área | Web/PWA | Pasajero nativa | Drive nativa | Evidencia en código |
| --- | --- | --- | --- | --- |
| Roles separados | Cuenta universal permitida | Sólo pasajero | Sólo conductor | `src/app-target.js`, `.env.passenger`, `.env.driver` |
| Cotización anticipada | Disponible | Misma compilación | Oferta y desglose | `finance_quote_v1`, `financial_terms` |
| Tarifa dinámica | Disponible por zona y horario | Misma compilación | Misma fuente de datos | migración `20261003055727` |
| Ajuste automático por espera | Disponible | Avisos y total final | Avisos, contador y total | migración `20261002190000` |
| Búsqueda persistente | Visible al pasajero | Misma compilación | Oferta de 8 s y reintento | migraciones `20260927`, `20260924` |
| Navegación y llegada | Ruta y seguimiento | Misma compilación | Navegación interna por etapas | `src/portal.js`, función Maps |
| Cobro en efectivo | Total final trazable | Misma compilación | Confirmación de dinero recibido | `transition`, pantalla de finalización |
| Detalle financiero | Mis viajes | Misma compilación | Comisión, IVA, ISR, billetera | `src/finance.js` |
| Notificaciones | Web Push | FCM si Firebase está configurado | FCM si Firebase está configurado | `public/sw.js`, `push-driver-alert` |

## Cambios incluidos en las tres variantes

La fuente funcional está centralizada en `src/portal.js`. Las compilaciones nativas no son una interfaz diferente: se generan con la misma fuente y un objetivo de cuenta que impide abrir el perfil equivocado. Esto reduce el riesgo de que una corrección aplicada a la web quede ausente en Pasajero o Drive.

- `npm run build:passenger` compila con `VITE_YAVOI_APP_TARGET=passenger`.
- `npm run build:driver` compila con `VITE_YAVOI_APP_TARGET=driver`.
- La PWA es universal: permite iniciar sesión como pasajero o conductor en la web instalada. Para iniciar operación web es el comportamiento esperado.

## Cobro y cotización

Cada cotización conserva términos financieros y versión de tarifa. El total aceptado mantiene separados base, distancia, tiempo, mínimo, descuentos y demanda. El precio sólo aumenta mediante eventos posteriores trazables: espera después de dos minutos de cortesía, desvío, cambio de ruta o recolección adicional aceptados.

La política dinámica del repositorio evalúa zonas de demanda y las ventanas 05:00–08:30 y 17:00–19:00, con tope de 1.50×. No se debe asumir que esté activa hasta verificar los valores efectivos de `finance_settings` y la ejecución de la migración en Supabase.

Los recibos y vistas de conductor separan cobro al pasajero, comisión, IVA de comisión, retenciones, propina, promociones, saldo electrónico, efectivo y retiro. Las tasas fiscales son datos operativos sujetos a validación contable; no sustituyen CFDI, timbrado ni declaración.

## Hallazgos que requieren verificación antes de iniciar operación

1. **Supabase:** confirmar que todas las migraciones hasta `20261003055727_scheduled_zone_demand_pricing.sql` fueron aplicadas en producción y que las Edge Functions de Maps, pagos, notificaciones y retiros están desplegadas.
2. **Maps:** comprobar claves separadas y restringidas para web, Android, iOS y servidor; probar rutas reales, geocodificación y llegada automática.
3. **Push:** los dos proyectos Android ya contienen `google-services.json` y la sincronización reconoce los plugins de ubicación y notificaciones. Falta comprobar en Firebase que esos archivos correspondan al proyecto productivo, confirmar `FIREBASE_SERVICE_ACCOUNT_JSON` en Supabase, y probar FCM con la app cerrada. Para PWA, configurar las claves VAPID. El archivo `GoogleService-Info.plist` aún falta para ambos proyectos iOS.
4. **Mercado Pago:** no habilitar tarjeta, reembolsos ni retiros hasta cargar secretos de producción, verificar webhook firmado y conciliar transacciones reales. `MP_PAYOUTS_ENABLED` debe mantenerse apagado hasta la autorización formal del proveedor.
5. **Fiscal:** validar por contador las retenciones, IVA, ISR, tratamiento de efectivo, aportación estatal y CFDI. El código conserva evidencia por viaje, pero no reemplaza la determinación fiscal.
6. **Publicación:** una compilación para Play debe ejecutarse nuevamente después de cualquier cambio web que deba estar incluida en el APK/AAB. PWA desplegada y AAB son entregables distintos. En este equipo no hay Java Runtime, por lo que el ensamblado `bundleRelease` no pudo ejecutarse; hay que instalar un JDK compatible o generar los AAB en Android Studio antes de subirlos a Play Console.

## Icono PWA

Se actualizó la PWA con el logotipo oficial de Yavoi! aportado para esta sesión:

- Iconos de 180, 192 y 512 px.
- Variante `maskable` de 512 px con zona segura para Android.
- Favicon y Apple touch icon alineados con el mismo arte.
- Caché del Service Worker elevada a `yavoi-shell-v8` para que la instalación descargue los nuevos recursos.

En Android e iOS, un acceso directo ya instalado puede conservar el icono anterior hasta que el navegador actualice la PWA o el usuario quite y vuelva a añadir el acceso directo.

## Conclusión de liberación

Los cambios de experiencia solicitados están presentes en la fuente compartida de la web, Pasajero y Drive. La aprobación para operación real depende de los seis controles externos enumerados arriba, especialmente secretos, despliegues y pruebas físicas. No se encontró una divergencia funcional intencional entre la PWA y los objetivos nativos.
