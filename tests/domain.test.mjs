import { test } from "node:test";
import assert from "node:assert/strict";
import {
  cents,
  changeDue,
  allowedView,
  escapeHtml,
  active,
  mfaQrSource,
  serviceAsset,
  driverDossierStatus,
  passengerProfileStatus,
  profileEditState,
  rewardEligibleForTrip,
  rewardDiscountCents,
  navs,
  places,
  normalizeHeading,
  bearingDegrees,
} from "../src/domain.js";
test("cash amounts round to cents and invalid amounts are rejected", () => {
  assert.equal(cents("100.25"), 10025);
  assert.equal(changeDue(6850, 10000), 3150);
  assert.equal(changeDue(6850, 6850), 0);
  assert.throws(() => cents("-1"));
  assert.throws(() => cents("invalid"));
});
test("role navigation never grants passenger or driver admin views", () => {
  for (const role of ["passenger", "driver"])
    for (const view of ["fleet", "audit", "rates", "marketing"])
      assert.equal(allowedView(role, view), false);
  assert.equal(allowedView("admin", "fleet"), true);
  assert.equal(allowedView("admin", "marketing"), true);
  assert.equal(allowedView("passenger", "profile"), true);
  assert.deepEqual(
    navs.driver.map(([view]) => view),
    ["home", "trips", "wallet", "rewards", "profile"],
  );
});
test("completed profiles stay locked outside an active Operations window", () => {
  const now = Date.parse("2026-09-11T12:00:00Z");
  assert.equal(profileEditState({ role: "passenger" }, now).editable, true);
  assert.equal(
    profileEditState({ role: "passenger", profile_locked_at: "2026-09-11T10:00:00Z" }, now)
      .editable,
    false,
  );
  assert.equal(
    profileEditState(
      {
        role: "driver",
        profile_locked_at: "2026-09-11T10:00:00Z",
        profile_edit_allowed_until: "2026-09-12T10:00:00Z",
      },
      now,
    ).editable,
    true,
  );
  assert.equal(
    profileEditState(
      {
        role: "driver",
        profile_locked_at: "2026-09-10T10:00:00Z",
        profile_edit_allowed_until: "2026-09-11T11:59:59Z",
      },
      now,
    ).editable,
    false,
  );
  assert.equal(
    profileEditState({ role: "admin", profile_locked_at: "2026-09-11T10:00:00Z" }, now)
      .editable,
    true,
  );
});
test("untrusted content is escaped before rendering", () => {
  assert.equal(escapeHtml('<img onerror="alert(1)">'), "&lt;img onerror=&quot;alert(1)&quot;&gt;");
  assert.equal(escapeHtml("'&"), "&#39;&amp;");
});
test("only terminal trips are inactive", () => {
  assert.equal(active({ status: "completed" }), false);
  assert.equal(active({ status: "cancelled" }), false);
  assert.equal(active({ status: "in_progress" }), true);
});
test("vehicle heading follows GPS degrees and can be derived from movement", () => {
  assert.equal(normalizeHeading(null), null);
  assert.equal(normalizeHeading(360), 0);
  assert.equal(normalizeHeading(-90), 270);
  assert.ok(Math.abs(bearingDegrees({ lat: 28.19, lng: -105.47 }, { lat: 28.20, lng: -105.47 }) - 0) < 0.01);
  assert.ok(Math.abs(bearingDegrees({ lat: 28.19, lng: -105.47 }, { lat: 28.19, lng: -105.46 }) - 90) < 0.01);
  assert.equal(bearingDegrees({ lat: 28.19, lng: -105.47 }, { lat: 28.19, lng: -105.47 }), null);
});
test("MFA QR accepts Supabase data URIs without double encoding", () => {
  const dataUri = "data:image/svg+xml;utf-8,%3Csvg%3Eqr%3C/svg%3E";
  assert.equal(mfaQrSource(dataUri), dataUri);
  assert.match(mfaQrSource("<svg>qr</svg>"), /^data:image\/svg\+xml;charset=utf-8,/);
  assert.throws(() => mfaQrSource("javascript:alert(1)"), /código QR/);
});
test("service categories use dedicated professional vehicle assets", () => {
  assert.equal(serviceAsset("basic"), "/assets/services/basic.webp");
  assert.equal(serviceAsset("large"), "/assets/services/large.webp");
  assert.equal(serviceAsset("commercial"), "/assets/services/commercial.webp");
  assert.equal(serviceAsset("plus"), "/assets/services/plus.webp");
  assert.equal(serviceAsset("pickup"), "/assets/services/pickup.webp");
  assert.equal(serviceAsset("unknown"), "/assets/services/basic.webp");
});
test("driver dossier progress requires every current document and expiration", () => {
  const profile = { full_name: "Conductor Prueba", phone: "6391234567", avatar_path: "avatar.png" };
  const complete = {
    vehicle_make: "Nissan",
    vehicle_model: "Versa",
    vehicle_year: 2024,
    vehicle_color: "Gris",
    plate: "ABC123A",
    vehicle_front_path: "vehicle-front.jpg",
    license_number: "LIC123",
    license_expires: "2099-12-31",
    insurance_expires: "2099-12-31",
    license_path: "license.pdf",
    insurance_path: "insurance.pdf",
    criminal_record_path: "record.pdf",
    policy_commitment_path: "policy.pdf",
    traffic_law_commitment_path: "traffic.pdf",
  };
  assert.deepEqual(driverDossierStatus(profile, complete), {
    completed: 17,
    total: 17,
    percent: 100,
    missing: [],
  });
  const expired = driverDossierStatus(profile, {
    ...complete,
    license_expires: "2020-01-01",
    criminal_record_path: null,
  });
  assert.equal(expired.completed, 15);
  assert.equal(expired.percent, 88);
  assert.ok(expired.missing.includes("Vigencia de licencia"));
  assert.ok(expired.missing.includes("Carta de no antecedentes penales"));
});
test("passenger profile progress requires safety policy and emergency data", () => {
  const partial = passengerProfileStatus({ full_name: "Ana Pérez", phone: "6391234567" });
  assert.equal(partial.completed, 2);
  assert.equal(partial.percent, 25);
  const complete = passengerProfileStatus({
    full_name: "Ana Pérez",
    phone: "6391234567",
    avatar_path: "avatar.png",
    emergency_name: "Contacto Seguro",
    emergency_phone: "6397654321",
    passenger_policy_accepted_at: "2026-09-10T12:00:00Z",
    passenger_policy_version: "2026-09-11-cancelaciones",
    privacy_policy_accepted_at: "2026-09-11T12:00:00Z",
    privacy_policy_version: "2026-09-11",
    terms_accepted_at: "2026-09-11T12:00:00Z",
    terms_version: "2026-09-11",
  });
  assert.equal(complete.percent, 100);
  assert.deepEqual(complete.missing, []);
});
test("passenger destination suggestions contain only the approved names", () => {
  assert.deepEqual(
    places.map(({ name }) => name),
    [
      "Omnibus Delicias",
      "Rápidos Delicias",
      "Autobuses Chihuahuenses",
      "Hotel Baeza",
      "Hotel Oasis Suite",
      "Hotel El Dorado Inn",
      "Hotel Casa Grande",
      "Hotel Los Cedros Inn",
      "American Inn Hotel y Suites",
      "Hotel Comfort Inn",
    ],
  );
});
test("travel rewards are eligible and calculated transparently", () => {
  const quote = { category: "basic", service_zone: "local", fare_cents: 6500 };
  assert.equal(
    rewardDiscountCents({ kind: "fare_discount_fixed", value_cents: 2000 }, quote),
    2000,
  );
  assert.equal(
    rewardDiscountCents(
      { kind: "fare_discount_percent", value_percent: 15, max_discount_cents: 4000 },
      quote,
    ),
    975,
  );
  assert.equal(rewardDiscountCents({ kind: "free_local_trip" }, quote), 6500);
  assert.equal(
    rewardEligibleForTrip({ kind: "free_local_trip" }, { ...quote, service_zone: "regional" }),
    false,
  );
  assert.equal(
    rewardDiscountCents(
      { kind: "fare_discount_fixed", value_cents: 9000, eligible_category: "basic" },
      quote,
    ),
    6500,
  );
  assert.equal(
    rewardEligibleForTrip(
      { kind: "fare_discount_fixed", eligible_category: "plus" },
      quote,
    ),
    false,
  );
});
