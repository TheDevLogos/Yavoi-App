# Tarifario vigente y reglas de cotización

**Propósito:** línea base operativa para revisar precios sin cambiar importes por accidente.

Todos los importes están expresados en MXN e incluyen IVA en la cotización al pasajero. Esta hoja refleja la configuración vigente en el código a octubre de 2026 y debe actualizarse mediante una versión tarifaria aprobada antes de cambiar cualquier valor.

## Tarifas vigentes por servicio

| Servicio | Base | Por km | Por minuto | Mínimo | Cargo de reserva |
| --- | ---: | ---: | ---: | ---: | ---: |
| Yavoi! Básico | $23.00 | $6.30 | $0.75 | $49.00 | $0.00 |
| Yavoi! Grande | $33.00 | $8.40 | $1.00 | $69.00 | $0.00 |
| Yavoi! Comercial | $78.00 | $9.80 | $1.20 | $130.00 | $0.00 |
| Yavoi! Plus | $39.00 | $9.10 | $1.10 | $79.00 | $0.00 |
| Yavoi! Pickup | $96.00 | $11.90 | $1.50 | $174.00 | $0.00 |

## Fórmula vigente

```text
subtotal = tarifa base + (kilómetros viales × precio/km) + (minutos estimados × precio/min)
          + suplemento regional aplicable + suplemento de accesibilidad aplicable
tarifa antes de demanda = máximo(subtotal, tarifa mínima)
cotización = tarifa antes de demanda + ajuste de demanda dinámica
total por pagar = cotización − descuentos aplicados + propina voluntaria
```

La distancia de recogida sirve para estimar llegada y para la operación de asignación. Su recargo, cuando exista, debe aparecer como concepto propio y nunca quedar integrado sin nombre dentro de la tarifa.

## Conceptos que deben conservarse en cada cotización

- Versión del tarifario y fecha de creación.
- Servicio seleccionado, kilómetros y minutos estimados.
- Base, distancia, tiempo, mínimo, zona, accesibilidad, recogida, peajes y espera cuando correspondan.
- Multiplicador y monto de demanda dinámica cuando esté aprobado y habilitado.
- Descuento, puntos y promoción con quién absorbe su costo.
- Tarifa anticipada aceptada, propina y precio final.

## Estado de reglas comerciales

| Regla | Estado actual |
| --- | --- |
| IVA incluido en cotización | Activo |
| Cargo de reserva | $0.00 en las categorías activas |
| Demanda dinámica | Preparada, desactivada |
| Tope técnico de demanda | 1.50×, no aplicable mientras esté desactivada |
| Peajes y espera | Campos preparados; requieren integración con datos reales antes de cobrarse |
| Promociones | Se registran y se concilian por separado del ingreso contractual del conductor |
| Propinas | Concepto independiente, sin comisión comercial de Yavoi! |

## Regla de publicación de cambios

1. Operaciones documenta el motivo, zona, categorías afectadas y vigencia.
2. Se crea una nueva versión tarifaria; las cotizaciones ya aceptadas no cambian.
3. Se prueba una matriz de rutas cortas, mínimas, medianas, largas, con descuento y con efectivo/electrónico.
4. Se valida que usuario, conductor y Finanzas muestren los mismos componentes y total.
5. Se publica el cambio y se conserva el historial para conciliación.

## Pendiente fiscal relacionado

Las retenciones se guardan por viaje, pero las tasas y el tratamiento de conductor sin RFC deben confirmarse con contador antes de convertir esta hoja en una política fiscal automática. Esta revisión no altera el tarifario ni cargos existentes.
