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
  if (command === "request_trip") payload = {
    confirm_transport_terms: true,
    regulatory_terms_version: "YV-TRANSPORTE-2026.09.15",
    ...payload,
  };
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
function currentShiftCode() {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chihuahua", hour: "2-digit", hourCycle: "h23" }).formatToParts(new Date());
  const hour = Number(parts.find((part) => part.type === "hour")?.value || 0);
  if (hour >= 5 && hour < 10) return "morning";
  if (hour >= 10 && hour < 13) return "midday";
  if (hour >= 17 && hour < 22) return "evening";
  return "night";
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
  assert.equal(
    (await db.query("select to_regclass('public.scheduled_trip_series') as relation")).rows[0].relation,
    "scheduled_trip_series",
  );
  assert.deepEqual(
    (await db.query("select column_name from information_schema.columns where table_schema='public' and table_name='trips' and column_name in ('planned_route','planned_route_distance_km','schedule_series_id') order by column_name")).rows.map((row) => row.column_name),
    ["planned_route", "planned_route_distance_km", "schedule_series_id"],
  );
  assert.ok(
    (await db.query("select 1 from pg_proc where proname in ('capture_trip_route_v1','assign_scheduled_trip_v1','release_scheduled_trips_v1')")).rows.length === 3,
  );
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
  const referralWallet = (await rpc("dashboard")).reward_wallet;
  assert.match(referralWallet.referral_code, /^YV[A-F0-9]{8}$/);
  assert.equal(referralWallet.referral_registered_count, 0);
  assert.ok(referralWallet.catalog.some((reward) => reward.program_type === "referral"));
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
  const savedHome = await rpc("save_saved_place", {
    slot: "home",
    address: "Calle 11 1/2 1108, Delicias",
    lat: 28.193,
    lng: -105.469,
  });
  assert.equal(savedHome.slot, "home");
  assert.equal((await rpc("dashboard")).saved_places[0].address, "Calle 11 1/2 1108, Delicias");
  await expectError(
    () => rpc("save_saved_place", { slot: "favorite", address: "Fuera", lat: 28.193, lng: -105.469 }),
    /Casa, Trabajo o Escuela/,
  );
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
    if (id === ids.driver) {
      await rpc("save_driver_profile_draft", { draft: { version: 1, values: { vehicle_make: "Nissan", seatbelts_all: true }, uploaded_paths: {}, saved_at: new Date().toISOString() } });
      assert.equal((await rpc("dashboard")).driver_profile_draft.draft.values.vehicle_make, "Nissan");
    }
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
  assert.deepEqual(adminDashboard.service_shifts.map((shift) => shift.code), ["morning", "midday", "evening", "night"]);
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
  const editableReward = await rpc("upsert_reward", {
    audience: "passenger",
    name: "Cupón digital de prueba",
    description: "Beneficio individual para validar el catálogo editable.",
    kind: "partner_coupon",
    delivery_mode: "digital_coupon",
    claim_method: "partner_counter",
    claim_instructions: "Presenta este ticket en la caja antes de pagar para validar el beneficio una sola vez.",
    claim_contact: "Negocio de prueba",
    claim_contact_url: "https://example.test/canje",
    claim_location: "Sucursal participante",
    claim_button_label: "Presentar en caja",
    icon: "ticket",
    points_cost: 0,
    min_trips: 0,
    min_income_cents: 0,
    partner_name: "Negocio de prueba",
    fulfillment_note: "Presenta el código antes de pagar.",
    terms: "Válido una vez y sujeto a disponibilidad.",
    image_path: campaignImage,
    expires_days: 30,
    sort_order: 1,
    automatic: false,
    active: true,
  });
  assert.match(editableReward.id, /^reward_[a-f0-9]{12}$/);
  assert.equal(editableReward.image_path, campaignImage);
  assert.equal(editableReward.claim_method, "partner_counter");
  assert.match(editableReward.claim_instructions, /una sola vez/);
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
  const digitalCoupon = await rpc("redeem_reward", { reward_id: editableReward.id });
  assert.equal(digitalCoupon.status, "available");
  assert.match(digitalCoupon.code, /^YV-[A-F0-9]{12}$/);
  const couponWallet = (await rpc("dashboard")).reward_wallet;
  assert.equal(couponWallet.redemptions.find((item) => item.id === digitalCoupon.id).image_path, campaignImage);
  assert.equal(couponWallet.redemptions.find((item) => item.id === digitalCoupon.id).terms, "Válido una vez y sujeto a disponibilidad.");
  assert.equal(couponWallet.redemptions.find((item) => item.id === digitalCoupon.id).claim_location, "Sucursal participante");
  await expectError(
    () => rpc("redeem_reward", { reward_id: editableReward.id }),
    /Ya tienes esta recompensa activa/,
  );
  await as(ids.admin, "aal2");
  const rewardQueue = (await rpc("dashboard")).reward_operations.redemptions;
  assert.ok(rewardQueue.some((item) => item.id === digitalCoupon.id && item.user_name === "Pasajero Prueba"));
  await rpc("review_reward_redemption", {
    redemption_id: digitalCoupon.id,
    status: "redeemed",
    reference: "CAJA-TEST-001",
    note: "Código validado por el negocio de prueba.",
  });
  await as(ids.rider);
  const redeemedCoupon = (await rpc("dashboard")).reward_wallet.redemptions.find((item) => item.id === digitalCoupon.id);
  assert.equal(redeemedCoupon.status, "redeemed");
  assert.equal(redeemedCoupon.redemption_reference, "CAJA-TEST-001");
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
    /Faltan requisitos/,
  );
  for (const [index, id] of [ids.driver, ids.driver2].entries()) {
    const avatarPath = `${id}/avatar.png`;
    const vehicleFrontPath = `${id}/vehicle-front.jpg`;
    const documents = {
      government_id_path: `${id}/government-id.pdf`,
      license_path: `${id}/license.pdf`,
      transport_card_path: `${id}/transport-card.pdf`,
      insurance_path: `${id}/insurance.pdf`,
      vehicle_registration_path: `${id}/registration.pdf`,
      vehicle_verification_path: `${id}/verification.pdf`,
      mechanical_inspection_path: `${id}/mechanical.pdf`,
      tax_compliance_path: `${id}/tax.pdf`,
      criminal_record_path: `${id}/criminal-record.pdf`,
      policy_commitment_path: `${id}/policy-commitment.pdf`,
      traffic_law_commitment_path: `${id}/traffic-law-commitment.pdf`,
    };
    await db.exec("reset role");
    await db.query("insert into storage.objects(bucket_id,name) values('yavoi-avatars',$1)", [avatarPath]);
    await db.query("insert into storage.objects(bucket_id,name) values('yavoi-vehicle-photos',$1)", [vehicleFrontPath]);
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
      birth_date: "1990-01-01",
      license_number: `LIC-${index + 1}`,
      license_expires: "2099-12-31",
      insurance_expires: "2099-12-31",
      transport_card_number: `TAR-${index + 1}`,
      transport_card_expires: "2099-12-31",
      vehicle_registration_expires: "2099-12-31",
      vin: `3N1CN7AP${String(index + 1).padStart(9, "0")}`,
      hologram_number: `HOL-${index + 1}`,
      hologram_expires: "2099-12-31",
      vehicle_verification_expires: "2099-12-31",
      mechanical_inspection_expires: "2099-12-31",
      tax_compliance_expires: "2099-12-31",
      seatbelts_all: true,
      front_airbags: true,
      abs_brakes: true,
      first_service_tools: true,
      extinguisher_abc: true,
      four_doors: true,
      tint_percent: 20,
      air_conditioning: true,
      reflective_markings: true,
      vehicle_front_path: vehicleFrontPath,
      ...documents,
    });
    assert.equal(submitted.complete, true);
    assert.equal(submitted.policy_version, "YV-POL-CON-2026.09.12");
    assert.equal(submitted.traffic_law_version, "YV-VIAL-POE-2026.08.08-63");
    assert.deepEqual(
      (
        await db.query(
          "select policy_version,traffic_law_version from public.drivers where id=$1",
          [id],
        )
      ).rows[0],
      {
        policy_version: "YV-POL-CON-2026.09.12",
        traffic_law_version: "YV-VIAL-POE-2026.08.08-63",
      },
    );
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
  await db.query("update public.service_shifts set start_time='00:00',end_time='23:59' where code=$1", [currentShiftCode()]);
  await as(ids.admin, "aal2");
  for (const id of [ids.driver, ids.driver2]) {
    const assigned = await rpc("set_driver_shift", { driver_id: id, shift_code: currentShiftCode(), note: "Compromiso de disponibilidad confirmado." });
    assert.equal(assigned.service_shift_code, currentShiftCode());
  }
  await expectError(() => as(ids.driver).then(() => rpc("set_driver_shift", { driver_id: ids.driver, shift_code: currentShiftCode(), note: "Intento no autorizado." })), /Operaciones/);
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
  const normalizedCapacityQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Tecnológico",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.18415,
    dest_lng: -105.4593,
    category: "basic",
    party_size: 5,
  });
  assert.equal(normalizedCapacityQuote.party_size, 4);
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
  assert.equal(units.length, 1);
  assert.equal(units[0].unit_id, ids.driver);
  assert.ok(Number(units[0].pickup_km) < 1);
  assert.equal(units[0].search_radius_km, 1);
  assert.deepEqual(Object.keys(units[0]).sort(), [
    "category", "fallback_all", "lat", "lng", "pickup_km", "pickup_minutes", "search_radius_km", "unit_id",
  ]);
  const allCategoryFallbackUnits = await rpc("available_units", {
    lat: 28.25,
    lng: -105.475,
    category: "plus",
  });
  assert.equal(allCategoryFallbackUnits.length, 2);
  assert.ok(allCategoryFallbackUnits.every((unit) => unit.fallback_all === true && unit.search_radius_km === null));
  await db.exec("reset role");
  await db.query("update public.driver_presence set heartbeat_at=now()-interval '2 minutes' where driver_id=$1", [ids.driver2]);
  await as(ids.rider);
  assert.equal((await rpc("available_units", {
    lat: 28.19065,
    lng: -105.47045,
    category: "basic",
  })).length, 1);
  await as(ids.driver2);
  await rpc("presence", { lat: 28.211, lng: -105.478, accuracy: 12, session_id: crypto.randomUUID() });
  await as(ids.rider);
  await db.exec("reset role");
  await db.query("update public.driver_presence set heartbeat_at=now()-interval '2 minutes' where driver_id=$1", [ids.driver]);
  await as(ids.rider);
  const expandedUnits = await rpc("available_units", {
    lat: 28.19065,
    lng: -105.47045,
    category: "basic",
  });
  assert.equal(expandedUnits.length, 1);
  assert.equal(expandedUnits[0].unit_id, ids.driver2);
  assert.equal(expandedUnits[0].search_radius_km, 2);
  await as(ids.driver);
  await rpc("presence", { lat: 28.191, lng: -105.471, accuracy: 10, session_id: crypto.randomUUID() });
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
  await expectError(
    () => db.query("select public.yavoi($1,$2::jsonb)", ["request_trip", JSON.stringify({ quote_id: q.id, request_key: crypto.randomUUID(), payment_method: "cash", cash_tender_cents: 10000 })]),
    /acepta la información legal/,
  );
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
  assert.equal(
    (await db.query("select regulatory_terms_version from public.trips where id=$1", [t.id])).rows[0].regulatory_terms_version,
    "YV-TRANSPORTE-2026.09.15",
  );
  assert.equal(
    (await rpc("trip", { trip_id: t.id })).regulatory_record.request_snapshot.regulatory_terms_version,
    "YV-TRANSPORTE-2026.09.15",
  );
  const persistedRoute = await rpc("capture_trip_route", {
    trip_id: t.id,
    planned_route: {
      coordinates: [[-105.47045, 28.19065], [-105.465, 28.188], [-105.4593, 28.18415]],
      distance_km: 1.8,
      duration_minutes: 5,
      instructions: [{ type: "depart", street: "Avenida principal", distance_m: 1800 }],
    },
  });
  assert.equal(persistedRoute.coordinates.length, 3);
  assert.equal((await rpc("trip", { trip_id: t.id })).route_plan.instructions[0].street, "Avenida principal");
  await as(ids.other);
  await expectError(
    () => rpc("capture_trip_route", { trip_id: t.id, planned_route: persistedRoute }),
    /No tienes acceso/,
  );
  await as(ids.rider);
  const unassignedDetail = await rpc("trip", { trip_id: t.id });
  assert.equal(unassignedDetail.driver, null);
  const riderDashboard = await rpc("dashboard");
  assert.equal(riderDashboard.ride_draft, null);
  assert.equal(riderDashboard.trips.find((trip) => trip.id === t.id).passenger_name, "Pasajero Actualizado");
  assert.equal(riderDashboard.trips.find((trip) => trip.id === t.id).driver_name, null);
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
  assert.equal((await rpc("dashboard")).trips.find((trip) => trip.id === t.id).passenger_name, "Pasajero Actualizado");
  await as(ids.rider);
  await rpc("message", { trip_id: t.id, body: "Estoy en la entrada principal." });
  await as(ids.driver);
  await rpc("message", { trip_id: t.id, body: "Voy en camino; llego en unos minutos." });
  await as(ids.rider);
  const detail = await rpc("trip", { trip_id: t.id });
  assert.equal(detail.driver.name, "Conductor Prueba 1");
  assert.equal(detail.driver.avatar_path, `${ids.driver}/avatar.png`);
  assert.equal(detail.driver.vehicle_model, "Versa");
  assert.equal(detail.driver.vehicle_color, "Gris");
  assert.equal(detail.driver.plate, "YAV101");
  assert.equal(detail.driver.vehicle_front_path, `${ids.driver}/vehicle-front.jpg`);
  assert.match(detail.regulatory_record.assignment_snapshot.driver.affiliation_number, /^YV-[A-F0-9]{12}$/);
  assert.equal(detail.regulatory_record.assignment_snapshot.driver.license_number, undefined);
  assert.equal(detail.regulatory_record.assignment_snapshot.vehicle.vin, undefined);
  await expectError(() => db.query("select * from public.trip_regulatory_records"), /permission denied/);
  assert.equal(detail.company_insurance.available, false);
  assert.match(detail.pin, /^\d{4}$/);
  assert.deepEqual(detail.messages.map((message) => message.body), [
    "Estoy en la entrada principal.",
    "Voy en camino; llego en unos minutos.",
  ]);
  const pin = detail.pin;
  await as(ids.other);
  assert.equal((await db.query("select * from public.trips")).rows.length, 0);
  await expectError(() => db.query("select * from public.trip_regulatory_records"), /permission denied/);
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
  await db.exec("reset role");
  await db.query(
    "insert into public.location_history(trip_id,driver_id,lat,lng,accuracy,captured_at) values($1,$2,28.18,-105.48,10,now()-interval '1 minute')",
    [t.id, ids.driver],
  );
  await as(ids.driver);
  await rpc("transition", { trip_id: t.id, status: "in_progress", pin: newPin });
  await rpc("location", { trip_id: t.id, lat: 28.19, lng: -105.47, accuracy: 10 });
  await as(ids.rider);
  const activeTrip = await rpc("trip", { trip_id: t.id });
  assert.equal(activeTrip.location.lat, 28.19);
  assert.equal(activeTrip.route_history.length, 1);
  assert.equal(activeTrip.route_history[0].lat, 28.19);
  await rpc("message", { trip_id: t.id, body: "Hola conductor" });
  await as(ids.other);
  assert.equal((await db.query("select * from public.messages")).rows.length, 0);
  assert.equal((await db.query("select * from public.locations")).rows.length, 0);
  await as(ids.driver);
  await expectError(() => rpc("transition", { trip_id: t.id, status: "completed" }), /efectivo/);
  const done = await rpc("transition", { trip_id: t.id, status: "completed", cash_received: true });
  assert.equal(done.payment_status, "paid");
  await db.exec("reset role");
  const regulatoryRecord = (await db.query("select * from public.trip_regulatory_records where trip_id=$1", [t.id])).rows[0];
  assert.equal(regulatoryRecord.receipt_status, "pending");
  assert.equal(regulatoryRecord.completion_snapshot.status, "completed");
  assert.ok(new Date(regulatoryRecord.retention_until) > new Date("2031-01-01"));
  await expectError(() => db.query("delete from public.trips where id=$1", [t.id]), /cinco años/);
  await as(ids.driver);
  await expectError(() => db.query("select * from private.trip_receipt_outbox"), /permission denied/);
  await expectError(
    () => rpc("transition", { trip_id: t.id, status: "completed", cash_received: true }),
    /estado/,
  );
  await as(ids.rider);
  const passengerPointsAfterTrip = await rpc("dashboard");
  assert.equal(passengerPointsAfterTrip.points, 10);
  assert.equal(passengerPointsAfterTrip.reward_wallet.available_points, 10);
  assert.equal(passengerPointsAfterTrip.reward_wallet.entries[0].entry_type, "trip_complete");
  await as(ids.driver);
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
    suspected_crime: true,
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
  assert.equal(
    (await db.query("select authority_report_status from public.complaints where id=$1", [passengerRating.report.id])).rows[0].authority_report_status,
    "pending",
  );
  await as(ids.admin, "aal2");
  const companyPolicyPath = `${ids.admin}/company-policy.pdf`;
  await db.exec("reset role");
  await db.query("insert into storage.objects(bucket_id,name) values('yavoi-documents',$1)", [companyPolicyPath]);
  await as(ids.admin, "aal2");
  await expectError(() => rpc("transport_compliance", { action: "save", enforcement_mode: "enforce" }), /Completa y verifica/);
  const compliance = await rpc("transport_compliance", {
    action: "save",
    legal_name: "Yavoi Movilidad de Chihuahua SA de CV",
    rfc: "YMC260915ABC",
    state_authorization_number: "AUT-CHIH-001",
    authorization_issued_at: "2026-09-15",
    authorization_expires: "2099-12-31",
    collaboration_agreement_at: "2026-09-15",
    company_policy_number: "POL-YAVOI-001",
    company_insurer: "Aseguradora de Prueba",
    company_policy_path: companyPolicyPath,
    company_policy_starts_at: "2026-09-15",
    company_policy_expires_at: "2099-12-31",
    company_policy_coverage_cents: 50000000,
    company_policy_coverage_uma: 32,
    mobility_fund_bps: 150,
    authority_reporting_channel: "Canal formal de prueba",
    receipt_email_enabled: true,
    enforcement_mode: "enforce",
  });
  assert.equal(compliance.company_ready, true);
  assert.equal(compliance.settings.enforcement_mode, "enforce");
  assert.equal(compliance.receipts[0].status, "pending");
  assert.equal(compliance.authority_incidents[0].authority_report_status, "pending");
  await db.exec("reset role");
  await db.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role: "service_role" })]);
  await db.exec("set role service_role");
  const receiptBatch = (await db.query("select public.yavoi_receipt_claim($1::jsonb) as result", [JSON.stringify({ trip_id: t.id, caller_id: ids.admin })])).rows[0].result;
  assert.equal(receiptBatch.length, 1);
  assert.equal(receiptBatch[0].trip.total_cents, done.total_cents);
  assert.equal(receiptBatch[0].trip.origin, done.origin);
  assert.equal(receiptBatch[0].trip.destination, done.destination);
  assert.equal(receiptBatch[0].driver.name, "Conductor Prueba 1");
  assert.equal(receiptBatch[0].driver.photo_path, `${ids.driver}/avatar.png`);
  await db.query("select public.yavoi_receipt_complete($1::jsonb)", [JSON.stringify({ trip_id: t.id, lease_token: receiptBatch[0].lease_token, success: true, provider_message_id: "gmail-test-001", caller_id: ids.admin })]);
  await as(ids.admin, "aal2");
  await rpc("transport_compliance", { action: "incident_reported", complaint_id: passengerRating.report.id, reference: "Fiscalía · folio TEST-002" });
  const complianceAfter = await rpc("transport_compliance", { action: "read" });
  assert.equal(complianceAfter.receipts[0].status, "sent");
  assert.equal(complianceAfter.authority_incidents[0].authority_report_status, "reported");
  const legalReport = await rpc("operations_report", { report: "overview", period: "year" });
  assert.equal(legalReport.regulatory.company_ready, true);
  assert.equal(legalReport.regulatory.settings.mobility_fund_bps, 150);
  assert.ok(Number(legalReport.regulatory.trips.mobility_fund_contribution_cents) >= 0);
  await as(ids.rider);
  await expectError(() => rpc("transport_compliance", { action: "read" }), /Operaciones/);
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
  assert.match(rideReward.code, /^YV-[A-F0-9]{12}$/);
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
  assert.equal(cardDriverData.driver_money.electronic_gross_cents, cardTrip.total_cents);
  assert.equal(cardDriverData.driver_money.electronic_net_cents, cardTrip.total_cents - cardDone.commission_cents);
  assert.equal(cardDriverData.driver_money.promotion_reimbursements_pending_cents, cardTrip.reward_discount_cents);
  assert.equal(cardDriverData.driver_money.electronic_balance_cents, cardTrip.fare_cents - cardDone.commission_cents + cardTrip.tip_cents);
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
  await db.exec("reset role");
  await db.query(
    `insert into public.weekly_fees(driver_id,week_start,due_at,amount_cents,status,note)
     values($1,current_date-7,now()-interval '1 day',50000,'overdue','Cuota vencida de prueba')`,
    [ids.driver2],
  );
  await as(ids.admin, "aal2");
  await rpc("set_driver_access", { driver_id: ids.driver2, active: false, note: "Prueba de bloqueo" });
  await as(ids.driver2);
  await expectError(() => rpc("availability", { online: true }), /acceso semanal/);
  await as(ids.admin, "aal2");
  const reactivation = await rpc("set_driver_access", { driver_id: ids.driver2, active: true, note: "Convenio de pago autorizado" });
  assert.equal(reactivation.active, true);
  assert.equal(reactivation.overdue_fees_preserved, 1);
  await rpc("dashboard");
  const reactivatedDriver = (await db.query(
    "select account_active,account_access_authorized_at,account_access_authorized_by from public.drivers where id=$1",
    [ids.driver2],
  )).rows[0];
  assert.equal(reactivatedDriver.account_active, true);
  assert.ok(reactivatedDriver.account_access_authorized_at);
  assert.equal(reactivatedDriver.account_access_authorized_by, ids.admin);
  assert.equal((await db.query(
    "select count(*)::integer as count from public.weekly_fees where driver_id=$1 and status='overdue'",
    [ids.driver2],
  )).rows[0].count, 1);
  await as(ids.driver2);
  await rpc("availability", { online: true, shift_code: currentShiftCode() });
  await rpc("availability", { online: false });
  await as(ids.admin, "aal2");
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
  await rpc("availability", { online: true, shift_code: currentShiftCode() });
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

  const scheduledAt = new Date(Date.now() + 2 * 86400000).toISOString();
  await rpc("save_ride_draft", {
    origin: "Mi ubicación actual",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    destination: "Hotel Baeza",
    dest_lat: 28.1965594,
    dest_lng: -105.4706209,
    category: "basic",
    party_size: 1,
    scheduled_at: scheduledAt,
    recurrence: "weekly",
    recurrence_count: 3,
  });
  let savedDraft = (await rpc("dashboard")).ride_draft;
  assert.equal(savedDraft.recurrence, "weekly");
  assert.equal(savedDraft.recurrence_count, 3);
  await rpc("save_ride_draft", { category: "basic", party_size: 1, recurrence: "weekly", recurrence_count: 9 });
  savedDraft = (await rpc("dashboard")).ride_draft;
  assert.equal(savedDraft.recurrence, "once");
  assert.equal(savedDraft.recurrence_count, 1);

  const scheduledQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Hotel Baeza",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.1965594,
    dest_lng: -105.4706209,
    category: "basic",
    scheduled_at: scheduledAt,
  });
  const singleScheduled = await rpc("request_trip", {
    quote_id: scheduledQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "cash",
    cash_tender_cents: scheduledQuote.fare_cents,
    recurrence: "once",
    recurrence_count: 7,
  });
  assert.equal(singleScheduled.scheduled_count, 1);
  assert.equal((await db.query("select schedule_series_id from public.trips where id=$1", [singleScheduled.id])).rows[0].schedule_series_id, null);

  const recurringQuote = await rpc("quote", {
    origin: "Centro",
    destination: "Hotel Casa Grande",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.192823,
    dest_lng: -105.462647,
    category: "basic",
    scheduled_at: scheduledAt,
  });
  const recurringTrip = await rpc("request_trip", {
    quote_id: recurringQuote.id,
    request_key: crypto.randomUUID(),
    payment_method: "cash",
    cash_tender_cents: recurringQuote.fare_cents,
    recurrence: "weekly",
    recurrence_count: 3,
  });
  assert.equal(recurringTrip.scheduled_count, 3);
  assert.equal((await db.query("select count(*)::integer as count from public.trips where schedule_series_id=$1", [recurringTrip.schedule_series_id])).rows[0].count, 3);
  const recurringAmounts = (await db.query(
    `select t.schedule_sequence,t.fare_cents,t.total_cents,q.fare_cents as quote_fare_cents,
      p.amount_cents as payment_cents
     from public.trips t
     join public.quotes q on q.id=t.quote_id
     join public.payments p on p.trip_id=t.id and p.kind='ride'
     where t.schedule_series_id=$1 order by t.schedule_sequence`,
    [recurringTrip.schedule_series_id],
  )).rows;
  assert.equal(new Set((await db.query("select quote_id from public.trips where schedule_series_id=$1", [recurringTrip.schedule_series_id])).rows.map((row) => row.quote_id)).size, 3);
  for (const amount of recurringAmounts) {
    assert.equal(amount.fare_cents, amount.quote_fare_cents);
    assert.equal(amount.total_cents, amount.quote_fare_cents);
    assert.equal(amount.payment_cents, amount.total_cents);
  }
  await db.exec("reset role");
  await db.query(
    "update public.drivers set category='large',online=false,account_active=false where id=$1",
    [ids.driver],
  );
  await as(ids.admin, "aal2");
  const offlineDriverCalendar = await rpc("scheduled_operations", { month: scheduledAt.slice(0, 7) });
  const offlineDriver = offlineDriverCalendar.drivers.find((driver) => driver.id === ids.driver);
  assert.equal(offlineDriver.category, "large");
  assert.equal(offlineDriver.connected, false);
  assert.equal(offlineDriver.account_active, false);
  const offlineAssignment = await rpc("assign_scheduled_trip", {
    trip_id: recurringTrip.id,
    driver_id: ids.driver,
  });
  assert.equal(offlineAssignment.driver_id, ids.driver);
  assert.equal(offlineAssignment.driver_online, false);
  await as(ids.driver);
  const driverScheduled = (await rpc("dashboard")).scheduling.upcoming;
  assert.ok(driverScheduled.some((trip) => trip.id === recurringTrip.id && trip.driver_id === ids.driver));
  await db.exec("reset role");
  await db.query(
    "update public.drivers set category='basic',online=true,account_active=true where id=$1",
    [ids.driver],
  );
  const activationTrip = (await db.query(
    "select id from public.trips where schedule_series_id=$1 and id<>$2 order by schedule_sequence limit 1",
    [recurringTrip.schedule_series_id, recurringTrip.id],
  )).rows[0];
  await as(ids.admin, "aal2");
  await rpc("assign_scheduled_trip", { trip_id: activationTrip.id, driver_id: ids.driver });
  await db.exec("reset role");
  await db.query("update public.trips set scheduled_at=now()+interval '10 minutes' where id=$1", [activationTrip.id]);
  await as(ids.admin, "aal2");
  await rpc("dashboard");
  const activatedScheduled = (await db.query(
    "select status,billing_mode,commission_bps_applied,commission_cents from public.trips where id=$1",
    [activationTrip.id],
  )).rows[0];
  assert.equal(activatedScheduled.status, "accepted");
  assert.equal(activatedScheduled.billing_mode, "weekly_fee");
  assert.equal(activatedScheduled.commission_bps_applied, 0);
  assert.equal(activatedScheduled.commission_cents, 0);
  await db.exec("reset role");
  await db.query("update public.trips set status='cancelled',cancel_reason='Fin de prueba',updated_at=now() where id=$1", [activationTrip.id]);
  await db.exec("reset role");
  await db.query(
    "update public.trips set driver_id=$2,scheduled_at=now()+interval '1 hour' where id=$1",
    [singleScheduled.id, ids.driver],
  );
  await as(ids.rider);
  const advanceScheduledCancellation = await rpc("cancellation_quote", { trip_id: singleScheduled.id });
  assert.equal(advanceScheduledCancellation.fee_cents, 0);
  assert.match(advanceScheduledCancellation.explanation, /periodo gratuito previo a la activación/);
  await db.exec("reset role");
  await db.query("update public.trips set scheduled_at=now()+interval '10 minutes' where id=$1", [singleScheduled.id]);
  await as(ids.rider);
  const activeScheduledCancellation = await rpc("cancellation_quote", { trip_id: singleScheduled.id });
  assert.equal(activeScheduledCancellation.fee_cents, 2500);
  assert.ok(activeScheduledCancellation.activation_at);
  await db.exec("reset role");
  await db.query("update public.trips set driver_id=null,scheduled_at=$2 where id=$1", [singleScheduled.id, scheduledAt]);
  await as(ids.admin, "aal2");
  const calendar = await rpc("scheduled_operations", { month: scheduledAt.slice(0, 7) });
  assert.ok(calendar.trips.some((item) => item.id === recurringTrip.id));
  const calendarTrip = calendar.trips.find((item) => item.id === recurringTrip.id);
  assert.equal(calendarTrip.passenger_name, "Pasajero Actualizado");
  assert.equal(calendarTrip.passenger_phone, "6391234567");
  await rpc("confirm_scheduled_trip", { trip_id: recurringTrip.id, note: "Confirmado por WhatsApp en prueba." });
  assert.ok((await db.query("select operations_confirmed_at from public.trips where id=$1", [recurringTrip.id])).rows[0].operations_confirmed_at);
  const reportWithMix = await rpc("operations_report", { report: "overview", period: "year" });
  assert.ok(reportWithMix.service_mix.some((item) => item.id === "basic"));
  await rpc("assign_scheduled_trip", { trip_id: recurringTrip.id, driver_id: null });
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
  assert.ok(operationsReport.commercial_summary.weekly_fees_collected_cents >= 50000);
  assert.ok(operationsReport.commercial_summary.cash_transfers_collected_cents > 0);
  assert.equal(
    operationsReport.commercial_summary.platform_revenue_collected_cents,
    operationsReport.commercial_summary.electronic_commission_retained_cents +
      operationsReport.commercial_summary.weekly_fees_collected_cents +
      operationsReport.commercial_summary.cash_transfers_collected_cents,
  );
  assert.ok(operationsReport.billing_drivers.some((driver) => driver.id === ids.driver2 && driver.billing_mode === "commission"));
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
