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
    `create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;create function auth.uid() returns uuid language sql stable as $$select nullif(auth.jwt()->>'sub','')::uuid$$;grant usage on schema auth to authenticated,anon;grant execute on function auth.uid(),auth.jwt() to authenticated,anon;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text);alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert on storage.objects to authenticated;create function storage.foldername(text) returns text[] language sql immutable as $$select (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1]$$;`,
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
      name + "@example.test",
    ]);
  await as(ids.rider);
  await rpc("onboard", { role: "passenger", name: "Pasajero Prueba", phone: "6391234567" });
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
  await rpc("dashboard");
  await db.exec("reset role");
  for (const id of [ids.driver, ids.driver2])
    await db.query(
      "update public.drivers set approved=true,online=true,vehicle='Versa 2024',plate=$2,license_expires=current_date+365,insurance_expires=current_date+365 where id=$1",
      [id, id.slice(-5)],
    );
  await as(ids.driver);
  await expectError(
    () => rpc("presence", { lat: 27.5, lng: -105.47, accuracy: 10 }),
    /fuera de cobertura/,
  );
  await rpc("presence", { lat: 28.191, lng: -105.471, accuracy: 10 });
  await as(ids.rider);
  const q = await rpc("quote", {
    origin: "Centro",
    destination: "Tecnológico",
    origin_lat: 28.19065,
    origin_lng: -105.47045,
    dest_lat: 28.18415,
    dest_lng: -105.4593,
    category: "basic",
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
  assert.equal(q.booking_fee_cents, 900);
  assert.equal(q.pickup_surcharge_cents, 0);
  await expectError(
    () =>
      rpc("request_trip", {
        quote_id: q.id,
        request_key: crypto.randomUUID(),
        payment_method: "card",
      }),
    /Tarjeta/,
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
  const duplicate = await rpc("request_trip", {
    quote_id: q.id,
    request_key: key,
    payment_method: "cash",
    cash_tender_cents: 10000,
  });
  assert.equal(duplicate.id, t.id);
  const detail = await rpc("trip", { trip_id: t.id });
  assert.match(detail.pin, /^\d{4}$/);
  const pin = detail.pin;
  await as(ids.other);
  assert.equal((await db.query("select * from public.trips")).rows.length, 0);
  await expectError(() => rpc("trip", { trip_id: t.id }), /acceso/);
  await expectError(() => db.query("select * from private.trip_secrets"), /permission denied/);
  await as(ids.driver);
  const offers = await rpc("offers");
  const offer = offers.find((o) => o.id === t.id);
  assert.ok(offer);
  assert.ok(Number(offer.pickup_from_driver_km) < 1);
  assert.equal(Number(offer.distance_km), Number(q.distance_km));
  assert.equal(offer.trip_eta_minutes, q.trip_eta_minutes);
  await rpc("accept", { trip_id: t.id });
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
  const driverData = await rpc("dashboard");
  assert.equal(driverData.ledger.filter((l) => l.kind === "cash_tip").length, 1);
  assert.equal(driverData.points, 10);
  await as(ids.rider);
  await expectError(() => rpc("rating", { trip_id: t.id, stars: 6 }), /check constraint/);
  await rpc("rating", { trip_id: t.id, stars: 5, comfort: 4, safety: 5, comment: "Buen servicio" });
  await rpc("rating", { trip_id: t.id, stars: 1 });
  assert.equal((await rpc("trip", { trip_id: t.id })).my_rating.stars, 5);
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
  assert.equal(regional.zone_surcharge_cents, 2500);
  assert.ok(Number(regional.pickup_distance_km) > 3);
  assert.ok(regional.pickup_surcharge_cents > 0);
  assert.ok(regional.fare_cents > q.fare_cents);
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
    base_cents: 3900,
    km_cents: 1150,
    minute_cents: 160,
    minimum_cents: 5900,
    booking_fee_cents: 900,
    commission_bps: 2000,
    active: true,
  });
  await rpc("resolve_complaint", {
    id: complaint.id,
    response: "Consulta atendida.",
    status: "resolved",
  });
  assert.ok((await rpc("dashboard")).audit.length > 0);
  await db.exec("reset role");
  await db.query("select set_config('request.jwt.claims','{}',false)");
  await db.exec("set role anon");
  await expectError(() => rpc("dashboard"), /permission denied/);
  await db.close();
});
