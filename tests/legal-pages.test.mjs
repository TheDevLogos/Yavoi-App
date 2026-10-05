import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const [landing, privacy, terms, accountDeletion, portal, vite] = await Promise.all([
  readFile(new URL("../index.html", import.meta.url), "utf8"),
  readFile(new URL("../privacidad.html", import.meta.url), "utf8"),
  readFile(new URL("../terminos.html", import.meta.url), "utf8"),
  readFile(new URL("../eliminar-cuenta.html", import.meta.url), "utf8"),
  readFile(new URL("../src/portal.js", import.meta.url), "utf8"),
  readFile(new URL("../vite.config.js", import.meta.url), "utf8"),
]);

test("landing publishes same-domain privacy and terms links for Google branding", () => {
  assert.match(landing, /href="\/privacidad">Política de Privacidad/);
  assert.match(landing, /href="\/terminos">Condiciones del Servicio/);
  assert.match(vite, /privacy:resolve\(import\.meta\.dirname,'privacidad\.html'\)/);
  assert.match(vite, /terms:resolve\(import\.meta\.dirname,'terminos\.html'\)/);
  assert.match(vite, /accountDeletion:resolve\(import\.meta\.dirname,'eliminar-cuenta\.html'\)/);
});

test("account deletion page states a direct request channel and retention scope", () => {
  for (const disclosure of [
    "Solicitud de eliminación de cuenta Yavoi!",
    "admin.yavoi@gmail.com",
    "No envíes contraseñas, datos de tarjetas ni documentos de identidad por correo",
    "pagos, facturación, seguridad, disputas, fraude, auditoría",
    "Política de Privacidad",
  ]) assert.match(accountDeletion, new RegExp(disclosure.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"));
  assert.match(privacy, /href="\/eliminar-cuenta"/);
  assert.match(terms, /href="\/eliminar-cuenta"/);
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
