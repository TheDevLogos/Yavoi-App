import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const [landing, privacy, terms, portal, vite] = await Promise.all([
  readFile(new URL("../index.html", import.meta.url), "utf8"),
  readFile(new URL("../privacidad.html", import.meta.url), "utf8"),
  readFile(new URL("../terminos.html", import.meta.url), "utf8"),
  readFile(new URL("../src/portal.js", import.meta.url), "utf8"),
  readFile(new URL("../vite.config.js", import.meta.url), "utf8"),
]);

test("landing publishes same-domain privacy and terms links for Google branding", () => {
  assert.match(landing, /href="\/privacidad">Política de Privacidad/);
  assert.match(landing, /href="\/terminos">Condiciones del Servicio/);
  assert.match(vite, /privacy:resolve\(import\.meta\.dirname,'privacidad\.html'\)/);
  assert.match(vite, /terms:resolve\(import\.meta\.dirname,'terminos\.html'\)/);
});

test("privacy page discloses Google data, location, payments, retention and user rights", () => {
  for (const disclosure of [
    "Uso de información obtenida de Google",
    "https://www.googleapis.com/auth/gmail.send",
    "requisitos de Uso Limitado",
    "Ubicación, mapas y expediente del viaje",
    "Pagos y datos financieros",
    "al menos cinco años",
    "Acceso, rectificación, cancelación y oposición",
    "admin.yavoi@gmail.com",
  ]) assert.match(privacy, new RegExp(disclosure.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"));
  assert.doesNotMatch(privacy, /alonsovl\.logos@gmail\.com/i);
});

test("terms page documents the complete passenger and driver service lifecycle", () => {
  for (const section of [
    "Elegibilidad y aceptación", "Cuentas, roles y verificación", "Servicios de movilidad",
    "Tarifas, métodos de pago y propinas", "Cancelaciones, espera y protección del servicio",
    "Viajes programados y recurrentes", "Seguridad y conducta durante el viaje",
    "Obligaciones de conductores", "Recompensas, promociones y publicidad",
  ]) assert.match(terms, new RegExp(section, "i"));
  assert.doesNotMatch(terms, /alonsovl\.logos@gmail\.com/i);
  assert.match(portal, /href="\/privacidad"/);
  assert.match(portal, /href="\/terminos"/);
});
