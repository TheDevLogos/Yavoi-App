import { test } from "node:test";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root));
const serviceWorker = await read("public/sw.js").then(String);
const landing = await read("app.js").then(String);
const portal = await read("src/portal.js").then(String);
async function pngSize(path) {
  const bytes = await read(path);
  assert.equal(bytes.subarray(1, 4).toString(), "PNG");
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

test("PWA manifest and platform icons are complete", async () => {
  const manifest = JSON.parse(await read("public/manifest.webmanifest"));
  assert.equal(manifest.start_url, "/portal.html");
  assert.equal(manifest.display, "standalone");
  assert.ok(manifest.icons.some((icon) => icon.sizes === "192x192" && icon.purpose === "any"));
  assert.ok(manifest.icons.some((icon) => icon.sizes === "512x512" && icon.purpose === "any"));
  assert.ok(manifest.icons.some((icon) => icon.sizes === "512x512" && icon.purpose === "maskable"));
  for (const path of [
    "public/icons/apple-touch-icon.png",
    "public/icons/yavoi-192.png",
    "public/icons/yavoi-512.png",
    "public/icons/yavoi-maskable-512.png",
    "public/icons/yavoi-app-icon.svg",
  ]) await access(new URL(path, root));
  assert.deepEqual(await pngSize("public/icons/apple-touch-icon.png"), [180, 180]);
  assert.deepEqual(await pngSize("public/icons/yavoi-192.png"), [192, 192]);
  assert.deepEqual(await pngSize("public/icons/yavoi-512.png"), [512, 512]);
  assert.deepEqual(await pngSize("public/icons/yavoi-maskable-512.png"), [512, 512]);
});

test("installed PWA checks for releases and reloads after the new worker takes control", () => {
  assert.match(serviceWorker, /yavoi-shell-v7/);
  assert.match(landing, /updateViaCache:'none'/);
  assert.match(portal, /updateViaCache: "none"/);
  assert.match(landing, /controllerchange/);
  assert.match(portal, /controllerchange/);
  assert.match(landing, /registration => registration\.update\(\)/);
  assert.match(portal, /registration\) => registration\.update\(\)/);
});

test("landing and portal advertise the PWA and the new access call to action", async () => {
  const [landing, portal, worker] = await Promise.all([
    read("index.html").then(String),
    read("portal.html").then(String),
    read("public/sw.js").then(String),
  ]);
  for (const html of [landing, portal]) {
    assert.match(html, /manifest\.webmanifest/);
    assert.match(html, /apple-touch-icon/);
  }
  assert.match(landing, /¡Entra ya!/);
  assert.match(worker, /request\.method !== "GET"/);
  assert.match(worker, /request\.mode === "navigate"/);
  assert.match(worker, /addEventListener\("push"/);
  assert.match(worker, /addEventListener\("notificationclick"/);
  assert.match(worker, /offer_id/);
  assert.match(worker, /requireInteraction/);
});

test("driver push subscriptions preserve offer opening after a background wake", async () => {
  const [migration, pushFunction] = await Promise.all([
    read("supabase/migrations/20260927100000_driver_web_push_and_grace.sql").then(String),
    read("supabase/functions/push-driver-alert/index.ts").then(String),
  ]);
  assert.match(portal, /function enableDriverPushNotifications\(\)/);
  assert.match(portal, /registration\.pushManager\.subscribe/);
  assert.match(portal, /function openPushedOffer\(\)/);
  assert.match(migration, /driver_push_subscriptions/);
  assert.match(migration, /driver_push_jobs/);
  assert.match(migration, /interval '1 minute'/);
  assert.match(migration, /private\.bootstrap_v6/);
  assert.match(migration, /private\.offers_v10/);
  assert.match(pushFunction, /webpush\.sendNotification/);
  assert.match(pushFunction, /WEB_PUSH_VAPID_PRIVATE_KEY/);
});

test("all map markers and service vehicle illustrations exist", async () => {
  for (const path of [
    "public/assets/map-origin.svg",
    "public/assets/map-destination.svg",
    "public/assets/map-car-top.svg",
    "public/assets/map-vehicles/basic.svg",
    "public/assets/map-vehicles/large.svg",
    "public/assets/map-vehicles/plus.svg",
    "public/assets/map-vehicles/commercial.svg",
    "public/assets/map-vehicles/pickup.svg",
    "public/assets/services/basic.webp",
    "public/assets/services/large.webp",
    "public/assets/services/commercial.webp",
    "public/assets/services/plus.webp",
    "public/assets/services/pickup.webp",
  ]) await access(new URL(path, root));
});

test("production headers allow Google Identity without weakening page isolation", async () => {
  const config = JSON.parse(await read("vercel.json"));
  const headers = config.headers[0].headers;
  const csp = headers.find((header) => header.key === "Content-Security-Policy")?.value || "";
  assert.match(csp, /https:\/\/accounts\.google\.com\/gsi\/client/);
  assert.match(csp, /frame-src[^;]*https:\/\/accounts\.google\.com/);
  assert.match(csp, /connect-src[^;]*https:\/\/router\.project-osrm\.org/);
  assert.equal(
    headers.find((header) => header.key === "Cross-Origin-Opener-Policy")?.value,
    "same-origin-allow-popups",
  );
});
