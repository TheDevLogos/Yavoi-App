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
  assert.match(portal, /enableDriverPushNotifications\(\)/);
  assert.match(portal, /requestOverlay\(\)/);
  assert.match(manifest, /SYSTEM_ALERT_WINDOW/);
  assert.match(plugin, /ACTION_MANAGE_OVERLAY_PERMISSION/);
});

test("navigation and profile entry points avoid the unstable wallet icon alias", async () => {
  const portal = await read("src/portal.js");
  const domain = await read("src/domain.js");
  assert.doesNotMatch(portal, /I\("wallet"\)/);
  assert.match(portal, /YavoiNavigation/);
  assert.match(domain, /\["wallet", "circle-dollar-sign", "Mis ingresos"\]/);
});
