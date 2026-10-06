# Ficha y cumplimiento de Google Play

Este documento reúne los datos que ya pueden prepararse. Antes de guardar una
declaración en Play Console, la persona responsable de Yavoi! debe comparar
cada respuesta con la operación real y con los contratos vigentes.

## Datos públicos de ambas aplicaciones

| Campo | Yavoi! | Yavoi! Drive |
| --- | --- | --- |
| Nombre | Yavoi! | Yavoi! Drive |
| Categoría sugerida | Viajes y guías locales | Mapas y navegación |
| Correo de soporte | `admin.yavoi@gmail.com` | `admin.yavoi@gmail.com` |
| Política de privacidad | `https://yavoi-app.vercel.app/privacidad` | `https://yavoi-app.vercel.app/privacidad` |
| Eliminación de cuenta | `https://yavoi-app.vercel.app/eliminar-cuenta` | `https://yavoi-app.vercel.app/eliminar-cuenta` |
| Publicidad | No se integran SDK ni anuncios de terceros en esta versión | No se integran SDK ni anuncios de terceros en esta versión |

## Borrador de seguridad de datos

La declaración final debe reflejar únicamente datos que realmente se recopilan
en la versión publicada. El código y la Política de Privacidad indican estos
grupos a revisar:

| Grupo de Play | Uso en Yavoi! | Vinculado a identidad | Compartido |
| --- | --- | --- | --- |
| Nombre, correo y teléfono | Cuenta, soporte y seguridad | Sí | Sólo con los participantes necesarios del viaje y proveedores operativos |
| Foto de perfil | Identificación dentro del servicio | Sí | Pasajero y conductor asignados |
| Ubicación precisa | Origen, asignación, navegación, seguridad y seguimiento | Sí | Pasajero, conductor asignado y Operaciones durante el servicio |
| Historial de viajes y actividad en la app | Cotización, servicio, soporte, recibos, fraude y obligaciones legales | Sí | Proveedores necesarios y Operaciones |
| Mensajes y reportes de viaje | Comunicación, seguridad y soporte | Sí | Participantes del viaje y Operaciones |
| Datos de pago y transacciones | Cobro, reembolso, conciliación y recibos | Sí | Mercado Pago cuando se habilite; Yavoi! no almacena PAN ni CVV |
| Identificadores de dispositivo y token de notificación | Alertas de viaje y seguridad | Sí | Firebase Cloud Messaging cuando se configure |
| Documentos de conductor | Verificación, autorización y cumplimiento | Sí | Operaciones y almacenamiento privado de Yavoi! |

## Campos que requieren confirmación antes de enviarlos

1. Información de contacto visible para usuarios: correo, sitio web y, si Play
   lo solicita, teléfono y domicilio comercial reales.
2. Público objetivo y clasificación de contenido. La cuenta exige mayoría de
   edad; no declarar una edad distinta de la que aplique al registro real.
3. Instrucciones y cuentas de acceso para revisión. Deben ser cuentas de
   demostración aisladas, con datos ficticios y acceso activo durante la
   revisión.
4. Formulario de seguridad de datos: confirmar si la versión final activa
   Firebase, Mercado Pago y rastreo de ubicación en segundo plano antes de
   marcar cada práctica.
5. Formulario de anuncios: conservar “sin anuncios” únicamente mientras no se
   integre una red publicitaria o publicidad comportamental.

## Elementos necesarios antes de revisión de ficha

- Ícono de 512 × 512 píxeles por app: disponible en `mobile/store-assets/`.
- Gráfico destacado de 1024 × 500 píxeles por app: disponible en `mobile/store-assets/`.
- Entre 2 y 8 capturas de teléfono por app; se recomiendan cuatro de cada una.
- Revisión de textos de ficha ya guardados como borrador.
- Verificación de que la política y la URL de eliminación de cuenta estén
  disponibles públicamente en HTTPS.
