import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const portal = await readFile(new URL("../src/portal.js", import.meta.url), "utf8");
const css = await readFile(new URL("../src/portal.css", import.meta.url), "utf8");
const domain = await readFile(new URL("../src/domain.js", import.meta.url), "utf8");
const operationsReport = await readFile(new URL("../src/operations-report.js", import.meta.url), "utf8");
const paymentFunction = await readFile(new URL("../supabase/functions/mercado-pago-payment/index.ts", import.meta.url), "utf8");
const mapsFunction = await readFile(new URL("../supabase/functions/maps/index.ts", import.meta.url), "utf8");
const driverLetters = await readFile(new URL("../scripts/generate-driver-documents.py", import.meta.url), "utf8");
const schedulingMigration = await readFile(new URL("../supabase/migrations/20260913141001_trip_routes_and_scheduling.sql", import.meta.url), "utf8");
const bookingHardeningMigration = await readFile(new URL("../supabase/migrations/20260914010851_booking_flow_hardening.sql", import.meta.url), "utf8");
const scheduleCalendarMigration = await readFile(new URL("../supabase/migrations/20260914043000_saved_places_schedule_calendar_and_reports.sql", import.meta.url), "utf8");
const routeRecoveryMigration = await readFile(new URL("../supabase/migrations/20260914123000_trip_route_recovery.sql", import.meta.url), "utf8");
const actualTripTraceMigration = await readFile(new URL("../supabase/migrations/20260914124500_actual_trip_trace.sql", import.meta.url), "utf8");

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

test("Operations map returns to Delicias when no units have a live signal", () => {
  assert.match(portal, /const DELICIAS_MAP_CENTER = \[DEFAULT_ORIGIN\.lat, DEFAULT_ORIGIN\.lng\]/);
  assert.match(portal, /if \(livePosition\) connectedBounds\.push\(point\)/);
  assert.match(portal, /fit && hasLiveUnits/);
  assert.match(portal, /S\.opsHadLiveUnits === true && !hasLiveUnits/);
  assert.match(portal, /S\.map\.setView\(DELICIAS_MAP_CENTER, OPERATIONS_EMPTY_ZOOM\)/);
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
  assert.match(portal, /Los datos personales del conductor se muestran cuando acepte el viaje/);
  assert.match(portal, /refreshAvailableUnits\(\{ fit: false \}\)/);
});

test("street routing provides a visual guide and opens driving navigation", () => {
  assert.match(mapsFunction, /steps=true&alternatives=true/);
  assert.match(mapsFunction, /instructions/);
  assert.match(mapsFunction, /route:v2:/);
  assert.match(portal, /guía por calles/i);
  assert.match(portal, /routeStepText/);
  assert.match(portal, /dir_action: "navigate"/);
  assert.match(portal, /Navegar al destino/);
  assert.match(css, /\.route-guide-summary/);
});

test("passengers can search local exact addresses and place or drag either map point", () => {
  assert.match(mapsFunction, /\$\{query\}, Delicias, Chihuahua, México/);
  assert.match(mapsFunction, /precision: address\.house_number \? "exact"/);
  assert.match(mapsFunction, /type === "reverse"/);
  assert.match(mapsFunction, /nominatim\.openstreetmap\.org\/reverse/);
  assert.doesNotMatch(mapsFunction, /admin\.yavoi@gmail\.com/);
  assert.match(mapsFunction, /Yavoi\/1\.1 \(\+https:\/\/yavoi-app\.vercel\.app\/\)/);
  assert.match(portal, /if \(!S\.pick\) return/);
  assert.match(portal, /draggable: !t/);
  assert.match(portal, /placeRidePoint\(kind, event\.target\.getLatLng\(\), \{ resolveAddress: true \}\)/);
  assert.match(portal, /event\.key !== "Enter"/);
  assert.match(portal, /Dirección exacta/);
  assert.match(portal, /Colocar \$\{kind === "origin" \? "origen" : "destino"\} en el mapa/);
  assert.match(css, /\.map-placement/);
  assert.match(css, /\.leaflet-container\.placing-point/);
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

test("Operations edits and filters rewards while users receive shareable barcode coupons", () => {
  assert.match(portal, /id="reward-audience-filter"/);
  assert.match(portal, /data-reward-audience/);
  assert.match(portal, /function openRewardEditor/);
  assert.match(portal, /upsert_reward/);
  assert.match(portal, /image_path: values\.remove_image/);
  assert.match(portal, /function rewardBarcode/);
  assert.match(portal, /data-view-coupon/);
  assert.match(portal, /navigator\.share/);
  assert.match(portal, /Código individual e irrepetible/);
  assert.match(css, /\.reward-coupon/);
  assert.match(css, /\.coupon-barcode/);
});

test("driver commitment letters are branded, current and available in both portals", () => {
  assert.match(portal, /operations-letter-templates/);
  assert.equal((portal.match(/carta-compromiso-politicas-yavoi\.pdf/g) || []).length, 2);
  assert.equal((portal.match(/carta-aceptacion-vialidad-chihuahua\.pdf/g) || []).length, 2);
  assert.match(driverLetters, /YV-POL-CON-2026\.09\.12/);
  assert.match(driverLetters, /YV-VIAL-POE-2026\.08\.08-63/);
  assert.match(driverLetters, /drawImage\(str\(cropped_logo\)/);
  assert.match(driverLetters, /comisión por viaje/i);
  assert.match(driverLetters, /cancelación/i);
  assert.match(driverLetters, /1\.35 metros/);
  assert.match(driverLetters, /licencia digital/i);
  assert.match(driverLetters, /treinta metros/i);
});

test("passenger rewards refresh when opened and while the wallet changes", () => {
  assert.match(portal, /S\.view === "rewards"[\s\S]{0,100}S\.data = await rpc\("dashboard"\)/);
  assert.match(portal, /table: "reward_entries"/);
  assert.match(portal, /table: "reward_redemptions"/);
  assert.match(portal, /else if \(S\.view === "rewards"\) await refreshPage\(\)/);
});

test("passengers see the suggested route, live trace and actionable deviation status", () => {
  assert.match(portal, /function distanceToRouteMeters/);
  assert.match(portal, /Desviación pronunciada detectada/);
  assert.match(portal, /Preguntar al conductor por el chat/);
  assert.match(portal, /Ruta sugerida y guía por calles/);
  assert.match(portal, /S\.tripHistoryLine = L\.polyline/);
  assert.match(portal, /updateRouteMonitor\(\)/);
  assert.match(css, /\.route-monitor\.deviation/);
});

test("vehicle front photo is required, private and shown only after assignment", () => {
  assert.match(domain, /Fotografía frontal del vehículo y placa/);
  assert.match(portal, /yavoi-vehicle-photos/);
  assert.match(portal, /vehicle_front_path/);
  assert.match(portal, /Fotografía frontal del vehículo con placa visible/);
  assert.match(portal, /Unidad verificada · confirma que la placa visible coincida/);
  assert.match(portal, /data-vehicle-photo/);
  assert.doesNotMatch(portal, /Sólo mostramos el tipo de servicio antes de confirmar[\s\S]{0,300}vehicle_front_path/);
});

test("scheduled rides persist the planned route and present reminders, assignment and navigation", () => {
  assert.match(schedulingMigration, /planned_route jsonb/);
  assert.match(schedulingMigration, /scheduled_trip_series/);
  assert.match(schedulingMigration, /capture_trip_route_v1/);
  assert.match(schedulingMigration, /planned_route is null/);
  assert.match(schedulingMigration, /assign_scheduled_trip_v1/);
  assert.match(schedulingMigration, /coalesce\(auth\.jwt\(\)->>'aal','aal1'\)<>'aal2'/);
  assert.match(portal, /maybeShowSchedulePromo/);
  assert.match(portal, /data-schedule-slide/);
  assert.match(portal, /recurrence_count/);
  assert.match(portal, /assign-scheduled/);
  assert.match(portal, /driver-navigation/);
  assert.match(portal, /tripSuggestedCasing/);
  assert.match(portal, /color: "#153e63"/);
  assert.match(portal, /color: "#fff"/);
  assert.match(mapsFunction, /time_distance_balanced/);
  assert.match(mapsFunction, /0\.65 \* \(Number\(item\.duration\) \/ fastest\)/);
});

test("drivers receive an audible, visible and recoverable offer alert", () => {
  assert.match(portal, /function armOfferSound\(\)/);
  assert.match(portal, /function playOfferSound\(\)/);
  assert.match(portal, /navigator\.vibrate/);
  assert.match(portal, /function presentDriverOfferAlert\(offer\)/);
  assert.match(portal, /RESPONDE EN 60 SEGUNDOS/);
  assert.match(portal, /function syncDriverOffers/);
  assert.match(portal, /setInterval\(\(\) => syncDriverOffers\(\)\.catch\(\(\) => \{\}\), 8000\)/);
  assert.match(portal, /S\.pendingOfferIds\.add\(payload\.new\.id\)/);
  assert.match(portal, /syncDriverOffers\(\)\.catch\(\(\) => \{\}\);[\s\S]{0,80}safeRefresh\(\)/);
  assert.match(portal, /document\.addEventListener\("visibilitychange"/);
  assert.match(portal, /Activar sonido/);
  assert.match(portal, /Probar alerta/);
  assert.match(css, /\.driver-offer-alert/);
});

test("fast booking, recurring schedules, GPS and flexible street names are hardened", () => {
  assert.match(portal, /id="advanced-options-toggle"/);
  assert.match(portal, /id="schedule-enabled"/);
  assert.match(portal, /recurrence === "once" \? 1/);
  assert.match(portal, /name="confirm_terms" type="checkbox" required/);
  assert.doesNotMatch(portal, /La búsqueda comienza en 1 km/);
  assert.match(portal, /function requestInitialLocation\(\)/);
  assert.match(portal, /requestInitialLocation\(\);/);
  assert.match(portal, /gain\.gain\.exponentialRampToValueAtTime\(0\.95/);
  assert.match(mapsFunction, /addressQueryVariants/);
  assert.match(mapsFunction, /1\/2/);
  assert.match(mapsFunction, /y\\s\+media/);
  assert.match(mapsFunction, /\[1!il\]\\\/2/);
  assert.match(mapsFunction, /\\d\{3,6\}/);
  assert.match(mapsFunction, /nueve/);
  assert.match(bookingHardeningMigration, /if cadence_value='once' then\s+count_value:=1/);
  assert.match(bookingHardeningMigration, /'recurrence_count',count_value/);
  assert.match(css, /\.compact-details/);
});

test("passengers save Casa, Trabajo and Escuela inside the destination selector", () => {
  assert.match(domain, /Agenda de viajes/);
  assert.match(portal, /S\.data\.saved_places/);
  assert.match(portal, /Casa.*Trabajo.*Escuela/);
  assert.match(portal, /save_saved_place/);
  assert.match(portal, /delete_saved_place/);
  assert.match(portal, /Guardar destino/);
  assert.match(scheduleCalendarMigration, /create table public\.saved_places/);
  assert.match(scheduleCalendarMigration, /passenger_id=\(select auth\.uid\(\)\)/);
  assert.match(scheduleCalendarMigration, /private\.dashboard_v11/);
});

test("Operations manages scheduled trips from a calendar with WhatsApp and timed reminders", () => {
  assert.match(portal, /scheduleCalendarMarkup/);
  assert.match(portal, /data-schedule-day/);
  assert.match(portal, /minutes_before/);
  assert.match(portal, /https:\/\/wa\.me\//);
  assert.match(portal, /confirm_scheduled_trip/);
  assert.match(scheduleCalendarMigration, /private\.scheduled_operations_v1/);
  assert.match(scheduleCalendarMigration, /interval '30 minutes'/);
  assert.match(scheduleCalendarMigration, /interval '15 minutes'/);
  assert.match(scheduleCalendarMigration, /coalesce\(auth\.jwt\(\)->>'aal','aal1'\)<>'aal2'/);
});

test("Operations audit loads once and exports service and driver metrics", () => {
  assert.match(portal, /async function audit\(\)/);
  assert.match(portal, /await loadOperationsReport\(\);\s*renderAuditReport\(\);/);
  const auditBody = portal.match(/async function audit\(\) \{([\s\S]*?)\n\}/)?.[1] || "";
  assert.doesNotMatch(auditBody, /run\(/);
  assert.match(portal, /Servicios por categoría/);
  assert.match(scheduleCalendarMigration, /private\.operations_report_v2/);
  assert.match(scheduleCalendarMigration, /'service_mix'/);
  assert.match(operationsReport, /Servicios por categoría/);
  assert.match(operationsReport, /Ticket promedio/);
});

test("terminal trips release navigation and every trip renders both route layers", () => {
  assert.match(portal, /function syncTripSummary\(trip\)/);
  assert.match(portal, /syncTripSummary\(t\)/);
  assert.match(portal, /function requestRouteRender\(\)/);
  assert.match(portal, /if \(S\.busy\) return requestRouteRender\(\)/);
  assert.match(portal, /const routePlan = trip \? S\.trip\?\.route_plan : S\.roadRoute/);
  assert.match(portal, /mapFrame\("ride-map", e\(geo\), "trip"\)/);
  assert.match(portal, /Ruta sugerida/);
  assert.match(portal, /Recorrido real/);
  assert.match(portal, /rpc\("capture_trip_route"/);
  assert.match(routeRecoveryMigration, /private\.capture_visible_trip_route_v1/);
  assert.match(routeRecoveryMigration, /passenger_id is distinct from uid/);
  assert.match(actualTripTraceMigration, /private\.trip_v9/);
  assert.match(actualTripTraceMigration, /event='in_progress'/);
  assert.match(actualTripTraceMigration, /captured_at>=started_at/);
  assert.match(actualTripTraceMigration, /when 'trip' then private\.trip_v9/);
  assert.match(css, /\.map-route-legend/);
  assert.match(css, /border-top:5px solid #153e63/);
  assert.match(css, /border-top:5px solid #ff6a0a/);
  assert.match(css, /svg:not\(\.leaflet-zoom-animated\)\{width:20px;height:20px/);
  assert.doesNotMatch(css, /(?:^|})svg\{width:20px;height:20px/);
});

test("service vehicles receive enough vertical room to remain fully visible", () => {
  assert.match(css, /\.category-option \.car\{width:102px;height:76px/);
  assert.match(css, /overflow:visible/);
  assert.match(css, /grid-template-columns:92px minmax\(0,1fr\) auto/);
});
