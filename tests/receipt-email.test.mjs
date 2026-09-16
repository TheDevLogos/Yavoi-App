import { test } from "node:test";
import assert from "node:assert/strict";
import { buildReceiptContent } from "../supabase/functions/send-trip-receipts/template.js";

test("emailed trip receipt contains every required transport datum", () => {
  const receipt = buildReceiptContent({
    trip_id: "10000000-0000-4000-8000-000000000999",
    receipt_number: "YV-TEST00000999",
    recipient_email: "pasajero@example.test",
    trip: {
      started_at: "2026-09-16T14:00:00Z",
      completed_at: "2026-09-16T14:18:00Z",
      total_cents: 6500,
      duration_minutes: 18,
      distance_km: 5.25,
      distance_source: "gps",
      origin: "Calle 11 1/2 #1108",
      destination: "Hotel Baeza",
    },
    driver: { name: "Conductor Yavoi", photo_path: "driver/avatar.jpg" },
  });
  assert.equal(receipt.email, "pasajero@example.test");
  assert.match(receipt.subject, /YV-TEST00000999/);
  for (const value of ["16 de septiembre de 2026", "$65.00", "18 min", "5.25 km", "Calle 11 1/2 #1108", "Hotel Baeza", "Conductor Yavoi", "cid:driver-photo"])
    assert.match(receipt.html, new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("receipt template rejects missing identity and escapes untrusted addresses", () => {
  assert.throws(() => buildReceiptContent({ trip_id: "x" }), /incompleto/);
  const receipt = buildReceiptContent({
    trip_id: "10000000-0000-4000-8000-000000000999",
    recipient_email: "safe@example.test",
    trip: { started_at: "2026-09-16T14:00:00Z", completed_at: "2026-09-16T14:18:00Z", origin: "<b>Origen</b>", destination: "Destino", total_cents: 1 },
    driver: { name: "Nombre <script>", photo_path: "photo.jpg" },
  });
  assert.doesNotMatch(receipt.html, /<script>/);
  assert.match(receipt.html, /&lt;script&gt;/);
  assert.match(receipt.html, /&lt;b&gt;Origen&lt;\/b&gt;/);
});
