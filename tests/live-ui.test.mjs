import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const portal = await readFile(new URL("../src/portal.js", import.meta.url), "utf8");
const css = await readFile(new URL("../src/portal.css", import.meta.url), "utf8");
const domain = await readFile(new URL("../src/domain.js", import.meta.url), "utf8");
const paymentFunction = await readFile(new URL("../supabase/functions/mercado-pago-payment/index.ts", import.meta.url), "utf8");
const mapsFunction = await readFile(new URL("../supabase/functions/maps/index.ts", import.meta.url), "utf8");

test("live map refreshes markers without recreating or refocusing the map", () => {
  assert.match(portal, /updateOperationsMapLayers\(\{ fit: false \}\)/);
  assert.match(portal, /updateTripMap\(\)/);
  assert.match(portal, /S\.view === "opsmap"[\s\S]{0,120}refreshOperationsMap\(\)/);
  assert.doesNotMatch(portal, /S\.mapLiveLayer\.clearLayers\(\)/);
  assert.match(portal, /S\.opsMarkers\.get\(id\)/);
  assert.match(portal, /marker\.setLatLng\(point\)/);
  assert.doesNotMatch(portal, /marker\.setIcon\(vehicleIcon/);
  assert.match(portal, /image\.style\.transform = `rotate\(\$\{heading\}deg\)`/);
  assert.match(portal, /signature !== S\.opsListSignature/);
  assert.match(portal, /data-unit-signal/);
});

test("vehicle markers stay attached to Operations, passenger and driver maps", () => {
  assert.match(css, /\.leaflet-marker-icon\.vehicle-icon-wrap\{transition:none!important;will-change:auto!important\}/);
  assert.doesNotMatch(css, /\.leaflet-marker-icon\.vehicle-icon-wrap\{transition:transform/);
  assert.match(portal, /const livePosition = Boolean\(unit\.online && unit\.presence_fresh\)/);
  assert.match(portal, /if \(livePosition\) marker\.setLatLng\(point\)/);
  assert.match(portal, /function updateTripMap\(\)/);
  assert.match(portal, /if \(!stale\) S\.tripVehicleMarker\.setLatLng\(point\)/);
  assert.match(portal, /marker\.getElement\(\)\?\.querySelector\("img"\)/);
  assert.match(portal, /vehicleHeading\(marker, unit\.heading, point\)/);
  assert.match(portal, /if \(livePosition\) rotateVehicle\(marker, heading\)/);
  assert.doesNotMatch(portal, /drawPoints\(next\.trip, \{ fit: false \}\)/);
});

test("vehicle markers use service-specific silhouettes and adapt to map zoom", () => {
  assert.match(portal, /function vehicleScaleForZoom\(zoom\)/);
  assert.match(portal, /--vehicle-marker-scale/);
  assert.match(portal, /S\.map\?\.on\("zoomend", syncVehicleScale\)/);
  assert.match(portal, /map-vehicles\/\$\{/);
  assert.match(portal, /unit\.category \|\| requestedCategory/);
  assert.match(portal, /vehicleIcon\(heading, false, t\.category\)/);
  assert.match(portal, /vehicleIcon\(heading, !!unit\.trip_id, unit\.category\)/);
  assert.match(portal, /image\.dataset\.vehicleCategory !== category/);
  assert.match(css, /transform:scale\(var\(--vehicle-marker-scale,1\)\)/);
  assert.match(css, /\.leaflet-marker-icon\.vehicle-icon-wrap\{transition:none!important/);
});

test("passenger unit search expands progressively and protects driver identity until acceptance", () => {
  assert.match(portal, /dentro de \$\{radius\} km/);
  assert.match(portal, /Sólo mostramos el tipo de servicio antes de confirmar/);
  assert.match(portal, /Yavoi! \$\{e\(serviceName\)\} · \$\{index === 0/);
  assert.doesNotMatch(portal, /bindTooltip\(`\$\{index === 0 \? "Recomendada por cercanía"[\s\S]*pickup_km/);
  assert.match(portal, /Cuando un conductor acepte, recibirás su nombre, fotografía, vehículo, color, modelo, placas y calificación/);
  assert.match(portal, /refreshAvailableUnits\(\{ fit: false \}\)/);
});

test("street routing provides a visual guide and opens driving navigation", () => {
  assert.match(mapsFunction, /steps=true&alternatives=true/);
  assert.match(mapsFunction, /instructions/);
  assert.match(mapsFunction, /route:v2:/);
  assert.match(portal, /Guía por calles/);
  assert.match(portal, /routeStepText/);
  assert.match(portal, /dir_action: "navigate"/);
  assert.match(portal, /Navegar al destino/);
  assert.match(css, /\.route-guide-summary/);
});

test("Operations modules share compact searchable and collapsible organization", () => {
  assert.match(portal, /enhanceOperationsLayout\(\)/);
  assert.match(portal, /Filtrar información visible/);
  assert.match(portal, /data-ops-layout="open"/);
  assert.match(portal, /data-ops-layout="close"/);
  assert.match(portal, /yavoi:operations:/);
  assert.match(css, /\.operations-layout-tools/);
  assert.match(css, /\.ops-section>summary/);
  assert.match(css, /\.role-admin \.workspace main/);
  assert.match(portal, /class="offer dossier-card driver-admin-card"/);
  assert.match(portal, /item\.matches\("details"\)/);
});

test("trip communication, ratings and mobile identity remain visible", () => {
  assert.match(portal, /Mensajear con mi conductor/);
  assert.match(portal, /Mensajear con mi pasajero/);
  assert.match(portal, /Nuevo mensaje del viaje/);
  assert.match(portal, /Valoraciones de este viaje/);
  assert.match(portal, /class="mobile-brand"/);
  assert.match(css, /@media\(max-width:760px\)\{\.mobile-brand\{display:block/);
});

test("passenger safety is integrated into each trip and cancellation is transparent", () => {
  assert.doesNotMatch(domain, /passenger:[^\n]+\["help"/);
  assert.match(portal, /Reportar este viaje/);
  assert.match(portal, /Reportar este servicio/);
  assert.match(portal, /Emergencias 911/);
  assert.match(portal, /rating_and_report/);
  assert.match(portal, /cancellation_quote/);
  assert.match(portal, /settle_cancellation_fee/);
  assert.match(portal, /cancellation_fee_paid/);
  assert.match(paymentFunction, /original_amount_cents/);
  assert.match(paymentFunction, /partialRefund = Number\(refundData\.amount_cents\) < Number\(refundData\.original_amount_cents/);
  assert.match(paymentFunction, /body: partialRefund \? JSON\.stringify/);
});

test("Operations exposes both per-driver commercial modes", () => {
  assert.match(portal, /Aportación semanal/);
  assert.match(portal, /Comisión por viaje/);
  assert.match(portal, /set_driver_billing/);
  assert.match(portal, /submit_driver_settlement/);
  assert.match(portal, /review_driver_settlement/);
});

test("approved destinations, legal consents and women-driver availability are explicit", () => {
  assert.match(portal, /id="destinations"/);
  assert.match(portal, /Sujeto a disponibilidad de conductoras conectadas/);
  assert.match(portal, /Política de Privacidad/);
  assert.match(portal, /Términos de Servicio/);
  assert.match(portal, /accept_privacy_policy/);
  assert.match(portal, /accept_terms/);
});

test("Operations can manage reward availability and photo advertising campaigns", () => {
  assert.match(portal, /Recompensas y publicidad/);
  assert.match(portal, /set_marketing_settings/);
  assert.match(portal, /set_reward_active/);
  assert.match(portal, /upsert_campaign/);
  assert.match(portal, /set_campaign_active/);
  assert.match(portal, /yavoi-marketing/);
  assert.match(portal, /maybeShowCampaignPromo/);
  assert.match(css, /\.campaign-grid/);
  assert.match(css, /\.campaign-modal/);
});
