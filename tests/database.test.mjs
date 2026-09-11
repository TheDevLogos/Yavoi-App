import { test } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readFile, readdir } from "node:fs/promises";
const db = new PGlite();
const ids = {
  rider: "10000000-0000-4000-8000-000000000001",
  other: "10000000-0000-4000-8000-000000000002",
  driver: "10000000-0000-4000-8000-000000000003",
  driver2: "10000000-0000-4000-8000-000000000004",
  admin: "10000000-0000-4000-8000-000000000005",
};
async function as(user, aal = "aal1") {
  await db.exec("reset role");
  await db.query("select set_config('request.jwt.claims',$1,false)", [
    JSON.stringify({ sub: user, role: "authenticated", aal }),
  ]);
  await db.exec("set role authenticated");
}
async function rpc(command, payload = {}) {
  return (
    await db.query("select public.yavoi($1,$2::jsonb) as result", [
      command,
      JSON.stringify(payload),
    ])
  ).rows[0].result;
}
async function expectError(fn, pattern) {
  await assert.rejects(fn, pattern);
}
test("Postgres security and complete ride lifecycle", async () => {
  await db.exec(
    `create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;create function auth.uid() returns uuid language sql stable as $$select nullif(auth.jwt()->>'sub','')::uuid$$;grant usage on schema auth to authenticated,anon;grant execute on function auth.uid(),auth.jwt() to authenticated,anon;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text);alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert on storage.objects to authenticated;create function storage.foldername(text) returns text[] language sql immutable as $$select (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1]$$;`,
  );
  const files = (await readdir(new URL("../supabase/migrations/", import.meta.url)))
    .filter((n) => n.endsWith(".sql"))
    .sort();
  for (const file of files) {
    const sql = (
      await readFile(new URL("../supabase/migrations/" + file, import.meta.url), "utf8")
    ).replace(/alter publication supabase_realtime add table[^;]+;/g, "");
    await db.exec(sql);
  }
  for (const [name, id] of Object.entries(ids))
    await db.query("insert into auth.users(id,email,email_confirmed_at)values($1,$2,now())", [
      id,
      name === "admin" ? "admin.yavoi@gmail.com" : name + "@example.test",
    ]);
  assert.deepEqual(
    (await db.query("select email,claimed_by from private.admin_enrollment order by email")).rows,
    [{ email: "admin.yavoi@gmail.com", claimed_by: ids.admin }],
  );
  assert.equal(
    (await db.query("select role from public.profiles where id=$1", [ids.admin])).rows[0].role,
    "admin",
  );
  assert.deepEqual(
    (await db.query("select id,base_cents,km_cents,booking_fee_cents from public.categories order by id")).rows,
    [
      { id: "basic", base_cents: 2300, km_cents: 630, booking_fee_cents: 0 },
      { id: "commercial", base_cents: 7800, km_cents: 980, booking_fee_cents: 0 },
      { id: "large", base_cents: 3300, km_cents: 840, booking_fee_cents: 0 },
      { id: "pickup", base_cents: 9600, km_cents: 1190, booking_fee_cents: 0 },
      { id: "plus", base_cents: 3900, km_cents: 910, booking_fee_cents: 0 },
    ],
  );
  await as(ids.rider);
  await rpc("onboard", { role: "passenger", name: "Pasajero Prueba", phone: "6391234567" });
  const riderAvatar = `${ids.rider}/avatar.png`;
  await db.exec("reset role");
  await db.query("insert into storage.objects(bucket_id,name) values('yavoi-avatars',$1)", [riderAvatar]);
  await as(ids.rider);
  const riderProfile = {
    name: "Pasajero Prueba",
    phone: "6391234567",
    emergency_name: "Contacto Pasajero",
    emergency_phone: "6397654321",
    avatar_path: riderAvatar,
    accept_passenger_policy: true,
    passenger_policy_version: "2026-09-11-cancelaciones",
    accept_privacy_policy: true,
    privacy_policy_version: "2026-09-11",
    accept_terms: true,
    terms_version: "2026-09-11",
  };
  await rpc("profile", riderProfile);
  assert.ok(
    (await db.query("select profile_locked_at from public.profiles where id=$1", [ids.rider])).rows[0]
      .profile_locked_at,
  );
  await expectError(() => rpc("profile", { ...riderProfile, name: "Cambio sin permiso" }), /protegido/);
  await expectError(
    () => rpc("authorize_profile_edit", { profile_id: ids.rider, allowed: true, note: "Intento propio" }),
    /Operaciones/,
  );
  await expectError(
    () =>
      rpc("review_driver", { driver_id: ids.driver, approved: true, note: "Intento ilegítimo" }),
    /Operaciones/,
  );
  await expectError(
    () => db.query("update public.profiles set role='admin' where id=$1", [ids.rider]),
    /permission denied/,
  );
  await as(ids.other);
  await rpc("onboard", { role: "passenger", name: "Otro Pasajero", phone: "6391234568" });
  await expectError(
    () => rpc("quote", {
      origin: "Centro",
      destination: "Tecnológico",
      origin_lat: 28.19065,
      origin_lng: -105.47045,
      dest_lat: 28.18415,
      dest_lng: -105.4593,
      category: "basic",
    }),
    /políticas de seguridad/,
  );
  for (const id of [ids.driver, ids.driver2]) {
    await as(id);
    await rpc("onboard", { role: "driver", name: "Conductor Prueba", phone: "6391234569" });
    await expectError(() => rpc("availability", { online: true }), /aprobado/);
  }
  await db.exec("reset role");
  await db.query("update public.profiles set role='admin',onboarding_complete=true where id=$1", [
    ids.admin,
  ]);
  await as(ids.admin);
  await expectError(() => rpc("dashboard"), /dos pasos/);
  assert.equal((await db.query("select * from public.trips")).rows.length, 0);
  await as(ids.admin, "aal2");
  const adminDashboard = await rpc("dashboard");
  assert.ok(adminDashboard.managed_profiles.some((profile) => profile.id === ids.rider));
  assert.equal(adminDashboard.marketing.rewards_enabled, true);
  assert.equal(adminDashboard.marketing.advertising_enabled, true);
  assert.ok(adminDashboard.marketing.reward_catalog.some((reward) => reward.id === "passenger_snack"));
  const campaignImage = `${ids.admin}/hotel-baeza.webp`;
  await db.exec("reset role");
  await db.query("insert into storage.objects(bucket_id,name) values('yavoi-marketing',$1)", [
    campaignImage,
  ]);
  await as(ids.admin, "aal2");
  const campaign = await rpc("upsert_campaign", {
    title: "Descuento en restaurante",
    advertiser_name: "Negocio de prueba",
    description: "Beneficio vigente para la comunidad Yavoi!.",
    discount_label: "10% de descuento",
    audience: "passenger",
    image_path: campaignImage,
    cta_label: "Ver promoción",
    cta_url: "https://example.test/promocion",
    starts_at: "2026-01-01T00:00:00Z",
    ends_at: "2099-12-31T23:59:59Z",
    active: true,
    priority: 10,
  });
  assert.equal(campaign.image_path, campaignImage);
  await rpc("set_reward_active", { reward_id: "passenger_snack", active: false });
  assert.equal(
    (await rpc("dashboard")).marketing.reward_catalog.find((reward) => reward.id === "passenger_snack")
      .active,
    false,
  );
  await rpc("authorize_profile_edit", {
    profile_id: ids.rider,
    allowed: true,
    note: "Identidad del pasajero verificada por Operaciones.",
  });
  await as(ids.rider);
  const riderMarketing = (await rpc("dashboard")).marketing;
  assert.ok(riderMarketing.campaigns.some((item) => item.id === campaign.id));
  assert.equal(riderMarketing.campaigns[0].image_path, campaignImage);
  await rpc("profile", { ...riderProfile, name: "Pasajero Actualizado" });
  assert.equal(
    (await db.query("select full_name from public.profiles where id=$1", [ids.rider])).rows[0].full_name,
    "Pasajero Actualizado",
  );
  await as(ids.admin, "aal2");
  await rpc("authorize_profile_edit", {
    profile_id: ids.rider,
    allowed: false,
    note: "Actualización concluida y revisada.",
  });
  await as(ids.rider);
  await expectError(() => rpc("profile", riderProfile), /protegido/);
  await as(ids.admin, "aal2");
  await expectError(
    () => rpc("review_driver", { driver_id: ids.driver, approved: true, note: "Expediente revisado" }),
    /expediente requiere/,
  );
  for (const [index, id] of [ids.driver, ids.driver2].entries()) {
    const avatarPath = `${id}/avatar.png`;
    const documents = {
      license_path: `${id}/license.pdf`,
      insurance_path: `${id}/insurance.pdf`,
      criminal_record_path: `${id}/criminal-record.pdf`,
      policy_commitment_path: `${id}/policy-commitment.pdf`,
      traffic_law_commitment_path: `${id}/traffic-law-commitment.pdf`,
    };
    await db.exec("reset role");
    await db.query("insert into storage.objects(bucket_id,name) values('yavoi-avatars',$1)", [avatarPath]);
    for (const path of Object.values(documents))
      await db.query("insert into storage.objects(bucket_id,name) values('yavoi-documents',$1)", [path]);
    await as(id);
    await rpc("profile", {
      name: `Conductor Prueba ${index + 1}`,
      phone: `639123456${index + 9}`,
      avatar_path: avatarPath,
    });
    const submitted = await rpc("driver_profile", {
      vehicle_make: "Nissan",
      vehicle_model: "Versa",
      vehicle_year: 2024,
      vehicle_color: "Gris",
      plate: `YAV${index + 1}01`,
      category: "basic",
      license_number: `LIC-${index + 1}`,
      license_expires: "2099-12-31",
      insurance_expires: "2099-12-31",
      ...documents,
    });
    assert.equal(submitted.complete, true);
    assert.ok(
      (await db.query("select profile_locked_at from public.profiles where id=$1", [id])).rows[0]
        .profile_locked_at,
    );
    await expectError(() => rpc("driver_profile", {}), /protegido/);
  }
  await as(ids.admin, "aal2");
  for (const id of [ids.driver, ids.driver2])
    await rpc("review_driver", {
      driver_id: id,
      approved: true,
      note: "Expediente completo y vigencias verificadas.",
    });
  await db.exec("reset role");
  await db.query("update public.drivers set online=true where id in ($1,$2)", [ids.driver, ids.driver2]);
  await as(ids.driver);
  await expectError(
    () => rpc("presence", { lat: 27.5, lng: -105.47, accuracy: 10 }),
    /fuera de cobertura/,
  );
  await rpc("presence", { lat: 28.191, lng: -105.471, accuracy: 10 });
  await as(ids.driver2);
  await rpc("presence", { lat: 28.198, lng: -105.478, accuracy: 12 });
  await as(ids.rider);
  await rpc("save_ride_draft", {
    origin: "Centro",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    destination: "Tecnológico",
    dest_lat: 28.18415,
    dest_lng: -105.4593,
    category: "basic",
    party_size: 4,
    service_notes: "Viaje para 4 personas",
  });
  assert.equal((await rpc("dashboard")).ride_draft.party_size, 4);
  await expectError(
    () =>
      rpc("quote", {
        origin: "Centro",
        destination: "Tecnológico",
        origin_lat: 28.19065,
        origin_lng: -105.47045,
        dest_lat: 28.18415,
        dest_lng: -105.4593,
        category: "basic",
        party_size: 5,
      }),
    /no tiene espacio/,
  );
  const q = await rpc("quote", {
    origin: "Centro",
    destination: "Tecnológico",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.18415,
    dest_lng: -105.4593,
    category: "basic",
    party_size: 4,
    service_notes: "Requiero espacio para dos maletas.",
    fare_cents: 1,
  });
  assert.ok(q.fare_cents > 3500);
  assert.ok(q.fare_cents !== 1);
  assert.equal(q.estimate_source, "nearby_online_unit");
  assert.equal(q.service_zone, "central");
  assert.ok(Number(q.distance_km) > Number(q.direct_distance_km));
  assert.ok(Number(q.pickup_distance_km) < 1);
  assert.ok(q.pickup_eta_minutes >= 3);
  assert.ok(q.trip_eta_minutes >= 5);
  assert.equal(q.booking_fee_cents, 0);
  assert.equal(q.pickup_surcharge_cents, 0);
  assert.equal(q.fare_cents, 4900);
  assert.equal(q.distance_charge_cents + q.time_charge_cents + q.minimum_adjustment_cents + 2300, q.fare_cents);
  const typical = await rpc("quote", {
    origin: "Centro",
    destination: "Zona urbana",
    origin_lat: 28.1902,
    origin_lng: -105.4701,
    dest_lat: 28.2212,
    dest_lng: -105.4701,
    category: "basic",
  });
  assert.ok(typical.fare_cents >= 6200 && typical.fare_cents <= 6800);
  assert.equal(typical.booking_fee_cents, 0);
  const units = await rpc("available_units", {
    lat: 28.19065,
    lng: -105.47045,
    category: "basic",
  });
  assert.equal(units.length, 2);
  assert.equal(units[0].unit_id, ids.driver);
  assert.ok(Number(units[0].pickup_km) < 1);
  await db.exec("reset role");
  await db.query("update public.driver_presence set heartbeat_at=now()-interval '2 minutes' where driver_id=$1", [ids.driver2]);
  await as(ids.rider);
  assert.equal((await rpc("available_units", {
    lat: 28.19065,
    lng: -105.47045,
    category: "basic",
  })).length, 1);
  await as(ids.driver2);
  await rpc("presence", { lat: 28.198, lng: -105.478, accuracy: 12, session_id: crypto.randomUUID() });
  await as(ids.rider);
  await expectError(
    () =>
      rpc("request_trip", {
        quote_id: q.id,
        request_key: crypto.randomUUID(),
        payment_method: "card",
      }),
    /tarjeta/i,
  );
  await expectError(
    () =>
      rpc("request_trip", {
        quote_id: q.id,
        request_key: crypto.randomUUID(),
        payment_method: "cash",
        cash_tender_cents: 1,
      }),
    /efectivo válido/,
  );
  const key = crypto.randomUUID();
  const t = await rpc("request_trip", {
    quote_id: q.id,
    request_key: key,
    payment_method: "cash",
    cash_tender_cents: 10000,
  });
  assert.equal(t.fare_cents, q.fare_cents);
  assert.equal(Number(t.distance_km), Number(q.distance_km));
  assert.equal(Number(t.pickup_distance_km), Number(q.pickup_distance_km));
  assert.equal(t.trip_eta_minutes, q.trip_eta_minutes);
  assert.equal(t.service_zone, q.service_zone);
  assert.equal(t.status, "requested");
  assert.equal(t.driver_id, null);
  assert.equal(t.party_size, 4);
  assert.equal(t.service_notes, "Requiero espacio para dos maletas.");
  assert.equal((await rpc("dashboard")).ride_draft, null);
  const duplicate = await rpc("request_trip", {
    quote_id: q.id,
    request_key: key,
    payment_method: "cash",
    cash_tender_cents: 10000,
  });
  assert.equal(duplicate.id, t.id);
  await as(ids.driver);
  const firstOffer = (await rpc("offers"))[0];
  assert.equal(firstOffer.id, t.id);
  assert.equal(firstOffer.party_size, 4);
  assert.equal(firstOffer.service_notes, "Requiero espacio para dos maletas.");
  assert.equal(firstOffer.passenger_name, "Pasajero Actualizado");
  assert.ok(firstOffer.offer_id);
  assert.equal(firstOffer.billing_mode, "weekly_fee");
  assert.equal(firstOffer.commission_bps, 0);
  assert.equal(firstOffer.commission_cents, 0);
  assert.equal(firstOffer.net_cents, firstOffer.fare_cents);
  const acceptedTrip = await rpc("accept", { offer_id: firstOffer.offer_id });
  assert.equal(acceptedTrip.status, "accepted");
  assert.equal(acceptedTrip.driver_id, ids.driver);
  assert.equal(acceptedTrip.billing_mode, "weekly_fee");
  assert.equal(acceptedTrip.commission_bps_applied, 0);
  await as(ids.rider);
  await rpc("message", { trip_id: t.id, body: "Estoy en la entrada principal." });
  await as(ids.driver);
  await rpc("message", { trip_id: t.id, body: "Voy en camino; llego en unos minutos." });
  await as(ids.rider);
  const detail = await rpc("trip", { trip_id: t.id });
  assert.match(detail.pin, /^\d{4}$/);
  assert.deepEqual(detail.messages.map((message) => message.body), [
    "Estoy en la entrada principal.",
    "Voy en camino; llego en unos minutos.",
  ]);
  const pin = detail.pin;
  await as(ids.other);
  assert.equal((await db.query("select * from public.trips")).rows.length, 0);
  await expectError(() => rpc("trip", { trip_id: t.id }), /acceso/);
  await expectError(() => db.query("select * from private.trip_secrets"), /permission denied/);
  await as(ids.driver);
  assert.equal((await rpc("offers")).length, 0);
  assert.equal((await rpc("trip", { trip_id: t.id })).pin, null);
  await as(ids.driver2);
  await expectError(() => rpc("accept", { trip_id: t.id }), /disponible/);
  await as(ids.rider);
  await expectError(
    () => rpc("transition", { trip_id: t.id, status: "arrived" }),
    /conductor asignado/,
  );
  await as(ids.driver);
  await expectError(
    () => rpc("transition", { trip_id: t.id, status: "completed", cash_received: true }),
    /estado/,
  );
  await rpc("transition", { trip_id: t.id, status: "arrived" });
  for (let i = 0; i < 5; i++)
    assert.ok(
      (await rpc("transition", { trip_id: t.id, status: "in_progress", pin: "0000" })).error,
    );
  assert.match(
    (await rpc("transition", { trip_id: t.id, status: "in_progress", pin })).error,
    /bloqueado/,
  );
  await as(ids.admin, "aal2");
  await rpc("reset_pin", { trip_id: t.id });
  await as(ids.rider);
  const newPin = (await rpc("trip", { trip_id: t.id })).pin;
  await as(ids.driver);
  await rpc("transition", { trip_id: t.id, status: "in_progress", pin: newPin });
  await rpc("location", { trip_id: t.id, lat: 28.19, lng: -105.47, accuracy: 10 });
  await as(ids.rider);
  assert.equal((await rpc("trip", { trip_id: t.id })).location.lat, 28.19);
  await rpc("message", { trip_id: t.id, body: "Hola conductor" });
  await as(ids.other);
  assert.equal((await db.query("select * from public.messages")).rows.length, 0);
  assert.equal((await db.query("select * from public.locations")).rows.length, 0);
  await as(ids.driver);
  await expectError(() => rpc("transition", { trip_id: t.id, status: "completed" }), /efectivo/);
  const done = await rpc("transition", { trip_id: t.id, status: "completed", cash_received: true });
  assert.equal(done.payment_status, "paid");
  await expectError(
    () => rpc("transition", { trip_id: t.id, status: "completed", cash_received: true }),
    /estado/,
  );
  await rpc("rating", { trip_id: t.id, stars: 5, comment: "Buen pasajero" });
  await rpc("tip", { trip_id: t.id, amount_cents: 2000 });
  await rpc("tip", { trip_id: t.id, amount_cents: 2000 });
  await as(ids.admin, "aal2");
  const cashOperations = await rpc("trip", { trip_id: t.id });
  assert.equal(cashOperations.operations.paid_cents, t.total_cents);
  assert.ok(cashOperations.operations.driver_net_cents > 0);
  await as(ids.driver);
  const driverData = await rpc("dashboard");
  assert.equal(driverData.ledger.filter((l) => l.kind === "cash_tip").length, 1);
  assert.equal(driverData.points, 14);
  assert.equal(driverData.reward_wallet.available_points, 14);
  assert.equal(driverData.reward_wallet.level, "Activo");
  assert.ok(driverData.reward_wallet.catalog.some((reward) => reward.id === "driver_wash_free"));
  await as(ids.rider);
  await expectError(() => rpc("rating", { trip_id: t.id, stars: 6 }), /check constraint/);
  const passengerRating = await rpc("rating_and_report", {
    trip_id: t.id,
    stars: 5,
    comfort: 4,
    safety: 5,
    comment: "Buen servicio",
    report_issue: true,
    report_subject: "Objeto olvidado",
    report_body: "Olvidé una mochila pequeña en el asiento trasero.",
  });
  assert.match(passengerRating.report.id, /^[0-9a-f-]{36}$/);
  await rpc("rating", { trip_id: t.id, stars: 1 });
  const ratedTrip = await rpc("trip", { trip_id: t.id });
  assert.equal(ratedTrip.my_rating.stars, 5);
  assert.equal(ratedTrip.ratings.length, 2);
  assert.ok(ratedTrip.ratings.some((rating) => rating.comment === "Buen pasajero"));
  assert.ok(ratedTrip.ratings.some((rating) => rating.comment === "Buen servicio"));
  assert.equal(ratedTrip.reports.length, 1);
  assert.equal(ratedTrip.reports[0].subject, "Objeto olvidado");
  await db.exec("reset role");
  await db.query("update public.reward_catalog set min_trips=1 where id='passenger_discount_20'");
  await db.query(
    "insert into public.reward_entries(user_id,points,entry_type,description,source_key) values($1,120,'adjustment','Bono controlado de prueba','test:rider:bonus')",
    [ids.rider],
  );
  await as(ids.rider);
  const rideReward = await rpc("redeem_reward", { reward_id: "passenger_discount_20" });
  assert.equal(rideReward.status, "available");
  assert.equal(rideReward.points_spent, 120);
  assert.match(rideReward.code, /^YV-[A-F0-9]{8}$/);
  assert.equal((await rpc("dashboard")).reward_wallet.available_points, 12);

  // Card payments stay blocked until credentials are enabled, then wait for a
  // verified provider event before dispatching a driver.
  await db.exec("reset role");
  await db.query(
    "update private.app_settings set mercado_pago_enabled=true,mercado_pago_public_key='TEST-public-key' where id",
  );
  await as(ids.rider);
  const cardQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Hospital Regional",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.18145,
    dest_lng: -105.475,
    category: "basic",
  });
  const cardTrip = await rpc("request_trip", {
    quote_id: cardQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "card",
    tip_cents: 1500,
    reward_code: rideReward.code,
  });
  assert.equal(cardTrip.status, "payment_pending");
  assert.equal(cardTrip.driver_id, null);
  assert.equal(cardTrip.reward_discount_cents, 2000);
  assert.equal(cardTrip.total_cents, cardQuote.fare_cents + 1500 - 2000);
  const checkout = await rpc("payment_checkout", { payment_id: cardTrip.payment_id });
  assert.equal(checkout.amount_cents, cardTrip.total_cents);
  assert.equal(checkout.payer_email, "rider@example.test");
  await as(ids.other);
  await expectError(
    () => rpc("payment_checkout", { payment_id: cardTrip.payment_id }),
    /Pago no disponible/,
  );
  await db.exec("reset role");
  const providerPayload = {
    external_reference: cardTrip.payment_id,
    provider_payment_id: "mp-test-1001",
    amount_cents: cardTrip.total_cents,
    status: "approved",
    status_detail: "accredited",
    payment_method_type: "credit_card",
    payment_method_id: "visa",
    installments: "1",
    live_mode: "false",
    event_key: "mp-test-1001:approved:1",
  };
  await db.query("select public.yavoi_payment_event($1::jsonb)", [JSON.stringify(providerPayload)]);
  await db.query("select public.yavoi_payment_event($1::jsonb)", [JSON.stringify(providerPayload)]);
  assert.equal(
    (await db.query("select count(*)::int as count from public.payment_events where payment_id=$1", [cardTrip.payment_id])).rows[0].count,
    1,
  );
  await as(ids.driver);
  const declinedOffer = (await rpc("offers"))[0];
  assert.equal(declinedOffer.id, cardTrip.id);
  await rpc("reject_offer", { offer_id: declinedOffer.offer_id, reason: "No tengo espacio suficiente" });
  await as(ids.driver2);
  const secondOffer = (await rpc("offers"))[0];
  assert.equal(secondOffer.id, cardTrip.id);
  assert.equal(secondOffer.billing_mode, "weekly_fee");
  assert.equal(secondOffer.commission_bps, 1000);
  assert.equal(secondOffer.commission_cents, Math.round(secondOffer.fare_cents * 0.1));
  const acceptedCardTrip = await rpc("accept", { offer_id: secondOffer.offer_id });
  assert.equal(acceptedCardTrip.billing_mode, "weekly_fee");
  assert.equal(acceptedCardTrip.commission_bps_applied, 1000);
  await as(ids.rider);
  const paidCardTrip = await rpc("trip", { trip_id: cardTrip.id });
  assert.equal(paidCardTrip.trip.status, "accepted");
  assert.equal(paidCardTrip.trip.payment_status, "paid");
  assert.equal(paidCardTrip.driver.vehicle, "Nissan Versa 2024");
  assert.equal(paidCardTrip.matching.attempts, 2);
  const cardPin = paidCardTrip.pin;
  await as(ids.driver2);
  await rpc("transition", { trip_id: cardTrip.id, status: "arrived" });
  await rpc("transition", { trip_id: cardTrip.id, status: "in_progress", pin: cardPin });
  await rpc("location", {
    trip_id: cardTrip.id,
    lat: 28.187,
    lng: -105.472,
    accuracy: 8,
    heading: 170,
    speed: 9,
  });
  await as(ids.admin, "aal2");
  const liveOperations = await rpc("dashboard");
  const liveUnit = liveOperations.operations_units.find((unit) => unit.driver_id === ids.driver2);
  assert.equal(liveUnit.trip_id, cardTrip.id);
  assert.equal(liveUnit.trip_status, "in_progress");
  assert.equal(liveUnit.route_history.length, 1);
  const operationsTrip = await rpc("trip", { trip_id: cardTrip.id });
  assert.equal(operationsTrip.operations.paid_cents, cardTrip.total_cents);
  assert.equal(operationsTrip.operations.passenger_phone, "6391234567");
  await as(ids.driver2);
  const cardDone = await rpc("transition", { trip_id: cardTrip.id, status: "completed" });
  assert.equal(cardDone.payment_status, "paid");
  const cardDriverData = await rpc("dashboard");
  assert.equal(cardDriverData.ledger.filter((l) => l.kind === "card_tip").length, 1);
  assert.ok(cardDriverData.reward_wallet.available_points >= 12);
  assert.equal((await rpc("trip", { trip_id: cardTrip.id })).route_history.length, 1);

  // Cancellation protection is calculated with server time, keeps both parties
  // informed and reconciles cash or card without trusting client totals.
  await as(ids.rider);
  const freeCancelQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Hotel Baeza",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.19656,
    dest_lng: -105.47062,
    category: "basic",
  });
  const freeCancelTrip = await rpc("request_trip", {
    quote_id: freeCancelQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "cash",
    cash_tender_cents: 10000,
  });
  const freeTerms = await rpc("cancellation_quote", { trip_id: freeCancelTrip.id });
  assert.equal(freeTerms.fee_cents, 0);
  const freeCancelled = await rpc("transition", {
    trip_id: freeCancelTrip.id,
    status: "cancelled",
    reason_code: "changed_plans",
    reason: "Ya no necesito realizar este traslado.",
  });
  assert.equal(freeCancelled.payment_status, "cancelled");
  assert.equal(freeCancelled.cancelled_by_role, "passenger");

  const cashCancelQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Hotel Casa Grande",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.19282,
    dest_lng: -105.46265,
    category: "basic",
    preferred_driver_id: ids.driver,
  });
  const cashCancelTrip = await rpc("request_trip", {
    quote_id: cashCancelQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "cash",
    cash_tender_cents: 10000,
    preferred_driver_id: ids.driver,
  });
  await as(ids.driver);
  const cashCancelOffer = (await rpc("offers")).find((offer) => offer.id === cashCancelTrip.id);
  await rpc("accept", { offer_id: cashCancelOffer.offer_id });
  await db.exec("reset role");
  await db.query(
    "update public.trip_events set created_at=now()-interval '3 minutes' where trip_id=$1 and event='accepted'",
    [cashCancelTrip.id],
  );
  await as(ids.rider);
  const cashTerms = await rpc("cancellation_quote", { trip_id: cashCancelTrip.id });
  assert.equal(cashTerms.fee_cents, 2500);
  assert.equal(cashTerms.refund_cents, 0);
  await rpc("transition", {
    trip_id: cashCancelTrip.id,
    status: "cancelled",
    reason_code: "wrong_location",
    reason: "La dirección de origen fue ingresada incorrectamente.",
  });
  await as(ids.driver);
  const cashCancelDetail = await rpc("trip", { trip_id: cashCancelTrip.id });
  assert.equal(cashCancelDetail.trip.cancellation_fee_cents, 2500);
  assert.equal(cashCancelDetail.trip.payment_status, "pending");
  assert.ok(cashCancelDetail.payments.some((payment) => payment.kind === "cancellation_fee" && payment.status === "pending"));
  await rpc("settle_cancellation_fee", {
    trip_id: cashCancelTrip.id,
    status: "paid",
    note: "Cuota recibida en efectivo y confirmada.",
  });
  assert.ok((await rpc("dashboard")).ledger.some((entry) => entry.trip_id === cashCancelTrip.id && entry.kind === "cancellation_fee" && entry.amount_cents === 2500));

  await as(ids.rider);
  const cardCancelQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Hotel Comfort Inn",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.19301,
    dest_lng: -105.45682,
    category: "basic",
    preferred_driver_id: ids.driver2,
  });
  const cardCancelTrip = await rpc("request_trip", {
    quote_id: cardCancelQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "card",
    preferred_driver_id: ids.driver2,
  });
  await db.exec("reset role");
  await db.query("select public.yavoi_payment_event($1::jsonb)", [JSON.stringify({
    external_reference: cardCancelTrip.payment_id,
    provider_payment_id: "mp-test-cancel-1002",
    amount_cents: cardCancelTrip.total_cents,
    status: "approved",
    status_detail: "accredited",
    payment_method_type: "credit_card",
    payment_method_id: "visa",
    installments: "1",
    live_mode: "false",
    event_key: "mp-test-cancel-1002:approved:1",
  })]);
  await as(ids.driver2);
  const cardCancelOffer = (await rpc("offers")).find((offer) => offer.id === cardCancelTrip.id);
  await rpc("accept", { offer_id: cardCancelOffer.offer_id });
  await db.exec("reset role");
  await db.query(
    "update public.trip_events set created_at=now()-interval '3 minutes' where trip_id=$1 and event='accepted'",
    [cardCancelTrip.id],
  );
  await as(ids.rider);
  const cardTerms = await rpc("cancellation_quote", { trip_id: cardCancelTrip.id });
  assert.equal(cardTerms.fee_cents, 2500);
  assert.equal(cardTerms.refund_cents, cardCancelTrip.total_cents - 2500);
  const cardCancelled = await rpc("transition", {
    trip_id: cardCancelTrip.id,
    status: "cancelled",
    reason_code: "changed_plans",
    reason: "Cambió mi itinerario después de la asignación.",
  });
  assert.equal(cardCancelled.payment_status, "refund_pending");
  const refundCheckout = await rpc("refund_checkout", { payment_id: cardCancelled.refund_payment_id });
  assert.equal(refundCheckout.amount_cents, cardCancelTrip.total_cents - 2500);
  assert.equal(refundCheckout.original_amount_cents, cardCancelTrip.total_cents);
  await db.exec("reset role");
  await db.query("select public.yavoi_payment_event($1::jsonb)", [JSON.stringify({
    external_reference: cardCancelTrip.payment_id,
    provider_payment_id: "mp-test-cancel-1002",
    amount_cents: cardCancelTrip.total_cents,
    status: "refunded",
    status_detail: "refunded",
    payment_method_type: "credit_card",
    payment_method_id: "visa",
    installments: "1",
    live_mode: "false",
    event_key: "mp-test-cancel-1002:refunded:2",
  })]);
  await as(ids.rider);
  const refundedTrip = await rpc("trip", { trip_id: cardCancelTrip.id });
  assert.equal(refundedTrip.trip.payment_status, "refunded");
  assert.equal(refundedTrip.trip.cancellation_refund_cents, cardCancelTrip.total_cents - 2500);
  assert.equal(refundedTrip.payments.find((payment) => payment.kind === "ride").retained_amount_cents, 2500);

  // A physical driver benefit requires Operations fulfillment and refunds its
  // points if Operations cancels it.
  await db.exec("reset role");
  await db.query(
    "update public.reward_catalog set min_trips=1,min_rating=null,min_income_cents=0 where id='driver_wash_discount'",
  );
  await db.query(
    "insert into public.reward_entries(user_id,points,entry_type,description,source_key) values($1,100,'adjustment','Bono controlado de prueba','test:driver:bonus')",
    [ids.driver2],
  );
  await as(ids.driver2);
  const driverReward = await rpc("redeem_reward", { reward_id: "driver_wash_discount" });
  assert.equal(driverReward.status, "requested");
  const pointsAfterRequest = (await rpc("dashboard")).reward_wallet.available_points;
  await as(ids.admin, "aal2");
  const rewardsOps = await rpc("dashboard");
  assert.ok(rewardsOps.reward_operations.pending.some((item) => item.id === driverReward.id));
  assert.ok(rewardsOps.reward_operations.drivers.some((item) => item.id === ids.driver2));
  await rpc("review_reward_redemption", {
    redemption_id: driverReward.id,
    status: "cancelled",
    note: "Proveedor no disponible en la prueba.",
  });
  await as(ids.driver2);
  assert.equal((await rpc("dashboard")).reward_wallet.available_points, pointsAfterRequest + 100);

  // Weekly application fee: private proof, Operations review and account switch.
  const weekly = cardDriverData.weekly_fees[0];
  assert.equal(weekly.amount_cents, 50000);
  const proofPath = ids.driver2 + "/weekly-proof.pdf";
  await db.query("insert into storage.objects(bucket_id,name) values('yavoi-payment-proofs',$1)", [proofPath]);
  await rpc("submit_weekly_fee", { fee_id: weekly.id, proof_path: proofPath });
  await as(ids.admin, "aal2");
  await rpc("review_weekly_fee", { fee_id: weekly.id, approved: true, note: "Pago comprobado." });
  await rpc("set_driver_access", { driver_id: ids.driver2, active: false, note: "Prueba de bloqueo" });
  await as(ids.driver2);
  await expectError(() => rpc("availability", { online: true }), /acceso semanal/);
  await as(ids.admin, "aal2");
  await rpc("set_driver_access", { driver_id: ids.driver2, active: true, note: "Prueba finalizada" });
  await rpc("set_driver_billing", {
    driver_id: ids.driver2,
    billing_mode: "commission",
    weekly_fee_cents: 50000,
    cash_commission_bps: 2000,
    card_commission_bps: 2000,
    note: "Cambio autorizado a comisión por viaje.",
  });
  const configuredDriver = (await db.query(
    "select billing_mode,weekly_fee_cents,cash_commission_bps,card_commission_bps from public.drivers where id=$1",
    [ids.driver2],
  )).rows[0];
  assert.deepEqual(configuredDriver, {
    billing_mode: "commission",
    weekly_fee_cents: 50000,
    cash_commission_bps: 2000,
    card_commission_bps: 2000,
  });
  assert.equal(
    (await db.query("select count(*)::int as count from public.weekly_fees where driver_id=$1 and status in ('pending','submitted','overdue')", [ids.driver2])).rows[0].count,
    0,
  );
  await as(ids.driver2);
  await rpc("availability", { online: true });
  await rpc("presence", { lat: 28.198, lng: -105.478, accuracy: 8, session_id: crypto.randomUUID() });
  await as(ids.rider);

  const commissionQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Colonia Linda Vista",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.205,
    dest_lng: -105.465,
    category: "basic",
    preferred_driver_id: ids.driver2,
  });
  const commissionTrip = await rpc("request_trip", {
    quote_id: commissionQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "cash",
    cash_tender_cents: 10000,
    preferred_driver_id: ids.driver2,
  });
  await as(ids.driver2);
  const commissionOffer = (await rpc("offers")).find((offer) => offer.id === commissionTrip.id);
  assert.equal(commissionOffer.billing_mode, "commission");
  assert.equal(commissionOffer.commission_bps, 2000);
  assert.equal(commissionOffer.commission_cents, Math.round(commissionOffer.fare_cents * 0.2));
  const acceptedCommissionTrip = await rpc("accept", { offer_id: commissionOffer.offer_id });
  assert.equal(acceptedCommissionTrip.billing_mode, "commission");
  assert.equal(acceptedCommissionTrip.commission_bps_applied, 2000);
  await as(ids.rider);
  const commissionPin = (await rpc("trip", { trip_id: commissionTrip.id })).pin;
  await as(ids.driver2);
  await rpc("transition", { trip_id: commissionTrip.id, status: "arrived" });
  await rpc("transition", { trip_id: commissionTrip.id, status: "in_progress", pin: commissionPin });
  await rpc("transition", { trip_id: commissionTrip.id, status: "completed", cash_received: true });
  const commissionDashboard = await rpc("dashboard");
  const settlement = commissionDashboard.commission_settlements[0];
  assert.equal(settlement.gross_cash_cents, commissionTrip.fare_cents);
  assert.equal(settlement.commission_due_cents, Math.round(commissionTrip.fare_cents * 0.2));
  assert.equal(settlement.status, "pending");
  const settlementProof = ids.driver2 + "/commission-proof.pdf";
  await db.query("insert into storage.objects(bucket_id,name) values('yavoi-payment-proofs',$1)", [settlementProof]);
  await rpc("submit_driver_settlement", { settlement_id: settlement.id, proof_path: settlementProof });
  await as(ids.admin, "aal2");
  await rpc("review_driver_settlement", {
    settlement_id: settlement.id,
    approved: true,
    note: "Transferencia semanal comprobada.",
  });
  const reconciled = (await rpc("dashboard")).commission_settlements.find((item) => item.id === settlement.id);
  assert.equal(reconciled.status, "paid");
  assert.ok((await rpc("dashboard")).audit.some((item) => item.action === "driver_billing_changed"));
  await rpc("set_marketing_settings", { rewards_enabled: false, advertising_enabled: false });
  await as(ids.rider);
  const pausedMarketing = (await rpc("dashboard")).marketing;
  assert.equal(pausedMarketing.rewards_enabled, false);
  assert.equal(pausedMarketing.advertising_enabled, false);
  assert.deepEqual(pausedMarketing.campaigns, []);
  await expectError(() => rpc("redeem_reward", { reward_id: "passenger_snack" }), /pausado/);
  await as(ids.admin, "aal2");
  await rpc("set_marketing_settings", { rewards_enabled: true, advertising_enabled: true });
  await rpc("set_campaign_active", { campaign_id: campaign.id, active: false });
  assert.equal(
    (await rpc("dashboard")).marketing.campaigns.find((item) => item.id === campaign.id).active,
    false,
  );
  await as(ids.rider);

  const regional = await rpc("quote", {
    origin: "Zona norte",
    destination: "Centro de Meoqui",
    origin_lat: 28.25,
    origin_lng: -105.475,
    dest_lat: 28.27215,
    dest_lng: -105.48075,
    category: "basic",
  });
  assert.equal(regional.service_zone, "regional");
  assert.equal(regional.zone_surcharge_cents, 1500);
  assert.ok(Number(regional.pickup_distance_km) > 3);
  assert.equal(regional.pickup_surcharge_cents, 0);
  assert.ok(regional.fare_cents > q.fare_cents);
  const selectedRegional = await rpc("quote", {
    origin: "Zona norte",
    destination: "Centro de Meoqui",
    origin_lat: 28.25,
    origin_lng: -105.475,
    dest_lat: 28.27215,
    dest_lng: -105.48075,
    category: "basic",
    preferred_driver_id: ids.driver,
  });
  assert.equal(selectedRegional.preferred_driver_id, ids.driver);
  assert.ok(Number(selectedRegional.pickup_distance_km) > 7);
  assert.ok(selectedRegional.pickup_surcharge_cents > 0);
  assert.equal(
    2300 + selectedRegional.distance_charge_cents + selectedRegional.time_charge_cents +
      selectedRegional.minimum_adjustment_cents + selectedRegional.pickup_surcharge_cents +
      selectedRegional.zone_surcharge_cents + selectedRegional.accessibility_surcharge_cents,
    selectedRegional.fare_cents,
  );
  await expectError(
    () =>
      rpc("category", {
        id: "basic",
        base_cents: 4000,
        km_cents: 1000,
        minute_cents: 100,
        minimum_cents: 5000,
        booking_fee_cents: 500,
        commission_bps: 2000,
        active: true,
      }),
    /Operaciones/,
  );
  const complaint = await rpc("complaint", {
    trip_id: t.id,
    subject: "Consulta",
    body: "Necesito revisar mi recibo.",
  });
  await as(ids.other);
  assert.equal((await db.query("select * from public.complaints")).rows.length, 0);
  await expectError(
    () =>
      rpc("resolve_complaint", {
        id: complaint.id,
        response: "Intento de otro usuario",
        status: "resolved",
      }),
    /Operaciones/,
  );
  await as(ids.admin, "aal2");
  await rpc("category", {
    id: "basic",
    base_cents: 2300,
    km_cents: 630,
    minute_cents: 75,
    minimum_cents: 4900,
    booking_fee_cents: 900,
    commission_bps: 2000,
    active: true,
  });
  assert.equal((await db.query("select booking_fee_cents from public.categories where id='basic'")).rows[0].booking_fee_cents, 0);
  await rpc("resolve_complaint", {
    id: complaint.id,
    response: "Consulta atendida.",
    status: "resolved",
  });
  const insurancePath = ids.admin + "/renewed-policy.pdf";
  await db.exec("reset role");
  await db.query("insert into storage.objects(bucket_id,name) values('yavoi-documents',$1)", [insurancePath]);
  await as(ids.admin, "aal2");
  await rpc("update_driver_insurance", {
    driver_id: ids.driver2,
    insurance_path: insurancePath,
    insurance_expires: "2026-10-01",
    note: "Póliza revisada por Operaciones.",
  });
  await rpc("log_report_export", { report: "overview", format: "pdf", period: "month" });
  const operationsReport = await rpc("operations_report", { report: "overview", period: "month" });
  assert.ok(operationsReport.summary.completed >= 2);
  assert.ok(operationsReport.summary.gross_cents > 0);
  assert.ok(operationsReport.periods.day.completed >= 2);
  assert.ok(operationsReport.drivers.some((driver) => driver.id === ids.driver2));
  assert.ok(operationsReport.audit.some((entry) => entry.actor_email === "admin.yavoi@gmail.com"));
  assert.ok(operationsReport.audit.some((entry) => entry.action === "operations_report_exported"));
  assert.equal(
    operationsReport.insurance.find((policy) => policy.id === ids.driver2).insurance_path,
    insurancePath,
  );
  await expectError(
    () => rpc("operations_report", { report: "overview", period: "custom", from: "2025-01-01", to: "2026-12-31" }),
    /366 días/,
  );
  assert.ok((await rpc("dashboard")).audit.length > 0);
  await as(ids.rider);
  await expectError(() => rpc("operations_report", { report: "overview", period: "month" }), /Operaciones/);
  await db.exec("reset role");
  await db.query("select set_config('request.jwt.claims','{}',false)");
  await db.exec("set role anon");
  await expectError(() => rpc("dashboard"), /permission denied/);
  await db.close();
});
