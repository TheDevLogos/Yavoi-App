import { test } from "node:test";
import assert from "node:assert/strict";
import { createGoogleNonce, validGoogleClientId } from "../src/google-auth.js";

test("only a real-looking Google web client ID can activate the button", () => {
  assert.equal(
    validGoogleClientId("123456789012-abcdefghijklmnopqrstuvwxyz123456.apps.googleusercontent.com"),
    true,
  );
  assert.equal(validGoogleClientId("TU_ID_DE_CLIENTE_DE_GOOGLE"), false);
  assert.equal(validGoogleClientId("https://accounts.google.com"), false);
  assert.equal(validGoogleClientId("123.apps.googleusercontent.com"), false);
});

test("Google sign-in nonce is random and sent to Supabase only after hashing", async () => {
  const first = await createGoogleNonce();
  const second = await createGoogleNonce();
  assert.match(first.raw, /^[a-f0-9]{64}$/);
  assert.match(first.hashed, /^[a-f0-9]{64}$/);
  assert.notEqual(first.raw, first.hashed);
  assert.notEqual(first.raw, second.raw);
  const digest = await globalThis.crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(first.raw),
  );
  const expected = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  assert.equal(first.hashed, expected);
});

test("portal exchanges the Google credential directly with Supabase", async () => {
  const portal = await import("node:fs/promises").then(({ readFile }) =>
    readFile(new URL("../src/portal.js", import.meta.url), "utf8"),
  );
  assert.match(portal, /accounts\.id\.renderButton/);
  assert.match(portal, /signInWithIdToken/);
  assert.match(portal, /provider:\s*"google"/);
  assert.match(portal, /nonce:\s*raw/);
  assert.match(
    portal,
    /903354099441-4la2ivgqknn9q8kj1ghku6caebc1a4ar\.apps\.googleusercontent\.com/,
  );
  assert.doesNotMatch(portal, /Continuar con (Microsoft|Apple)/);
  assert.match(portal, /Servicio para personas con alguna discapacidad/);
  assert.doesNotMatch(portal, />Reservación</);
  assert.match(portal, /Reportar viaje/);
  assert.match(portal, /Emergencias 911/);
  assert.match(portal, /weeklyProfileMarkup/);
  assert.match(portal, /Autorizar edición 24 h/);
  assert.doesNotMatch(portal, /weekly:\s*weeklyView/);
});
