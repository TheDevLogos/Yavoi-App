import { test } from "node:test";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root));
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
  assert.equal(
    headers.find((header) => header.key === "Cross-Origin-Opener-Policy")?.value,
    "same-origin-allow-popups",
  );
});
