import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const portal = await readFile(new URL("../src/portal.js", import.meta.url), "utf8");
const css = await readFile(new URL("../src/portal.css", import.meta.url), "utf8");

test("live map refreshes markers without recreating or refocusing the map", () => {
  assert.match(portal, /updateOperationsMapLayers\(\{ fit: false \}\)/);
  assert.match(portal, /drawPoints\(next\.trip, \{ fit: false \}\)/);
  assert.match(portal, /S\.view === "opsmap"[\s\S]{0,120}refreshOperationsMap\(\)/);
  assert.match(portal, /S\.mapLiveLayer\.clearLayers\(\)/);
});

test("trip communication, ratings and mobile identity remain visible", () => {
  assert.match(portal, /Mensajear con mi conductor/);
  assert.match(portal, /Mensajear con mi pasajero/);
  assert.match(portal, /Nuevo mensaje del viaje/);
  assert.match(portal, /Valoraciones de este viaje/);
  assert.match(portal, /class="mobile-brand"/);
  assert.match(css, /@media\(max-width:760px\)\{\.mobile-brand\{display:block/);
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
