# Aplicaciones Android de Yavoi!

Dos aplicaciones nativas independientes comparten el portal, Supabase y las
reglas de negocio: `passenger` (`mx.yavoi.pasajero`) y `driver`
(`mx.yavoi.conductor`). El sitio web se mantiene universal para Operaciones.

Desde la raíz del repositorio ejecuta `npm run android:passenger:sync` o
`npm run android:driver:sync`. Antes de producción añade Firebase, claves
Android restringidas de Google Maps y Play App Signing.
