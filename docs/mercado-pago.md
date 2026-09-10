# Activar Mercado Pago en Yavoi!

La integración ya contiene Checkout Bricks, creación idempotente de pagos, firma HMAC del webhook, consulta del pago al proveedor, conciliación, propinas y reembolsos. Hasta que existan credenciales, el servidor bloquea la tarjeta y la interfaz la muestra como lista para activar.

## Datos que se obtienen de Mercado Pago

1. Crear la aplicación de producción en la cuenta empresarial.
2. Copiar la **Public Key** y el **Access Token** de producción.
3. En Webhooks, configurar esta URL:

   `https://asjlyureqokifjkpdwgc.supabase.co/functions/v1/mercado-pago-webhook`

4. Activar las notificaciones de pagos y copiar la clave secreta de firma.

## Secretos de Supabase

En Supabase, abrir Edge Functions > Secrets y crear:

- `MP_ACCESS_TOKEN`: Access Token privado de producción.
- `MP_WEBHOOK_SECRET`: clave secreta de Webhooks.
- `APP_ORIGINS`: dominios permitidos separados por coma. Debe incluir el dominio final de Yavoi!.
- `ROUTING_BASE_URL`: opcional; URL de un servidor OSRM contratado para producción.

Las claves privadas nunca deben guardarse en GitHub, JavaScript del navegador o tablas visibles.

## Activación final

Después de probar con compradores y tarjetas de prueba, guardar la Public Key y activar el interruptor con una migración controlada:

```sql
update private.app_settings
set mercado_pago_public_key = 'PUBLIC_KEY_REAL',
    mercado_pago_enabled = true,
    updated_at = now()
where id = true;
```

Para detener nuevos pagos sin borrar la configuración:

```sql
update private.app_settings
set mercado_pago_enabled = false,
    updated_at = now()
where id = true;
```

## Prueba de aceptación

1. Crear pasajero y conductor de prueba; aprobar y conectar al conductor.
2. Solicitar un viaje con tarjeta y confirmar que no se asigna conductor antes del pago.
3. Completar el Brick con una tarjeta de prueba y confirmar que el webhook cambia el pago a aprobado.
4. Verificar la asignación automática, ficha del conductor y movimiento GPS.
5. Completar el viaje, agregar una propina y revisar ambos registros en Pagos y cuotas.
6. Cancelar otro pago aprobado y confirmar que el reembolso termina en `Reembolsado`.

Para producción conviene reemplazar el enrutador público por un servicio OSRM administrado o un proveedor con SLA y límites acordes al volumen de Yavoi!.
