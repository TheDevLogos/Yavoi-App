import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const root = new URL("..", import.meta.url);
const read = (file) => readFile(new URL(file, root), "utf8");

test("mobile builds use production Maps settings and keep the app role explicit", async () => {
  const manifest = JSON.parse(await read("package.json"));
  assert.match(manifest.scripts["build:driver"], /scripts\/build-mobile\.mjs driver/);
  assert.match(manifest.scripts["build:passenger"], /scripts\/build-mobile\.mjs passenger/);
  const script = await read("scripts/build-mobile.mjs");
  assert.match(script, /--mode", "production/);
  assert.match(script, /VITE_YAVOI_APP_TARGET: target/);
});

test("driver asks permissions deliberately and can request its optional alert window", async () => {
  const portal = await read("src/portal.js");
  const manifest = await read("mobile/driver/android/app/src/main/AndroidManifest.xml");
  const plugin = await read("mobile/driver/android/app/src/main/java/mx/yavoi/conductor/YavoiDevicePermissionsPlugin.java");
  assert.match(portal, /showFirstRunPermissionGuide/);
  assert.match(portal, /yavoi:device-permissions:\$\{S\.profile\?\.role \|\| "guest"\}:v3/);
  assert.match(portal, /enableDriverPushNotifications\(\)/);
  assert.match(portal, /requestOverlay\(\)/);
  assert.match(manifest, /SYSTEM_ALERT_WINDOW/);
  assert.match(plugin, /ACTION_MANAGE_OVERLAY_PERMISSION/);
});

test("native builds use Yavoi's secure host for Maps and recover from rejected map keys", async () => {
  const portal = await read("src/portal.js");
  const driverConfig = await read("mobile/driver/capacitor.config.json");
  const passengerConfig = await read("mobile/passenger/capacitor.config.json");
  assert.match(driverConfig, /"hostname": "yavoi-app\.vercel\.app"/);
  assert.match(passengerConfig, /"hostname": "yavoi-app\.vercel\.app"/);
  assert.match(portal, /window\.gm_authFailure/);
  assert.match(portal, /googleMapsAuthenticationFailed/);
});

test("legacy data cannot break navigation, rewards, or the driver income screen", async () => {
  const portal = await read("src/portal.js");
  assert.match(portal, /function wallet\(\)/);
  assert.match(portal, /lucideName/);
  assert.match(portal, /circle-alert/);
  assert.match(portal, /rewardFaqButton\) rewardFaqButton\.onclick/);
  assert.match(portal, /\$\("#share-referral-whatsapp"\)\?\.addEventListener/);
});

test("navigation and profile entry points avoid the unstable wallet icon alias", async () => {
  const portal = await read("src/portal.js");
  const domain = await read("src/domain.js");
  assert.doesNotMatch(portal, /I\("wallet"\)/);
  assert.match(portal, /YavoiNavigation/);
  assert.match(domain, /\["wallet", "circle-dollar-sign", "Mis ingresos"\]/);
});

test("driver navigation remains native through pickup, trip completion, and queued offers", async () => {
  const portal = await read("src/portal.js");
  const activity = await read("mobile/driver/android/app/src/main/java/mx/yavoi/conductor/YavoiNavigationActivity.java");
  const plugin = await read("mobile/driver/android/app/src/main/java/mx/yavoi/conductor/YavoiNavigationPlugin.java");
  assert.match(portal, /nativeNavigationActive/);
  assert.match(portal, /prepareNativeNavigationEvents/);
  assert.match(portal, /showNativeNavigationOffer/);
  assert.match(activity, /ACTION_EVENT/);
  assert.match(activity, /dispatchEvent\("arrive"/);
  assert.match(activity, /dispatchEvent\("start"/);
  assert.match(activity, /dispatchEvent\("complete"/);
  assert.match(activity, /switchTrip/);
  assert.match(activity, /TextToSpeech/);
  assert.match(activity, /Ver por/);
  assert.match(plugin, /notifyListeners\("event"/);
  assert.match(plugin, /nextTrip/);
  assert.match(portal, /nativeNavigationTripPayload/);
  assert.match(portal, /YavoiNavigation\.nextTrip/);
});

test("native navigation maps each button to the server trip state", async () => {
  const portal = await read("src/portal.js");
  assert.match(portal, /arrive: \{ status: "arrived"/);
  assert.match(portal, /start: \{ status: "in_progress"/);
  assert.match(portal, /complete: \{ status: "completed", cash_received: true/);
  assert.match(portal, /nativeNavigationEventQueue = nativeNavigationEventQueue\.catch/);
  assert.match(portal, /S\.data = await rpc\("dashboard"\)/);
  assert.match(portal, /location\.hash = "home";[\s\S]{0,80}YavoiNavigation\.close/);
  assert.doesNotMatch(portal, /rpc\("transition", \{ trip_id: tripId, action:/);
});

test("cash completion asks for confirmation inside the native navigation surface", async () => {
  const activity = await read("mobile/driver/android/app/src/main/java/mx/yavoi/conductor/YavoiNavigationActivity.java");
  assert.match(activity, /if \("collect"\.equals\(stage\) && "cash"\.equals\(paymentMethod\)\)/);
  assert.match(activity, /new AlertDialog\.Builder\(this\)/);
  assert.match(activity, /Llegada y pago en efectivo/);
  assert.match(activity, /Total a recolectar/);
  assert.match(activity, /Recibí el pago y entregué el cambio correspondiente/);
  assert.match(activity, /finalFareReady && cashAcknowledgement/);
  assert.match(activity, /dispatchEvent\("complete", null\)/);
});

test("drop-off is recorded before cash confirmation and shown to the passenger", async () => {
  const portal = await read("src/portal.js");
  const activity = await read("mobile/driver/android/app/src/main/java/mx/yavoi/conductor/YavoiNavigationActivity.java");
  const migration = await read("supabase/migrations/20261012210000_destination_arrival_trip_event.sql");
  assert.match(activity, /if \("destination"\.equals\(stage\)\) reachDestination\(\)/);
  assert.match(activity, /dispatchEvent\("destination_reached", null\)/);
  assert.match(portal, /rpc\("destination_reached", \{ trip_id: tripId \}\)/);
  assert.match(portal, /event === "destination_reached" && S\.profile\?\.role === "passenger"/);
  assert.match(portal, /destinationReached \? "Llegué a Destino"/);
  assert.match(migration, /trip_value\.status<>'in_progress'/);
  assert.match(migration, /event='destination_reached'/);
});

test("passengers receive the final fare and every accepted trip adjustment", async () => {
  const portal = await read("src/portal.js");
  assert.match(portal, /function passengerFinalFareSummary/);
  assert.match(portal, /function passengerFinalFareMarkup/);
  assert.match(portal, /Demanda aplicada · incluida en tarifa/);
  assert.match(portal, /Espera después de 2 min de cortesía/);
  assert.match(portal, /Desvíos, ruta o recolecciones aceptados/);
  assert.match(portal, /event === "completed" && S\.profile\?\.role === "passenger"/);
  assert.match(portal, /Llegaste a tu destino/);
});
