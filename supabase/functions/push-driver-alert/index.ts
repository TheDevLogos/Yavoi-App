import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const vapidPublicKey = Deno.env.get("WEB_PUSH_VAPID_PUBLIC_KEY") || "";
const vapidPrivateKey = Deno.env.get("WEB_PUSH_VAPID_PRIVATE_KEY") || "";
const admin = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

function authorized(request: Request) {
  const values = Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"));
  const apiKey = request.headers.get("apikey") || request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  return Boolean(apiKey && values.includes(apiKey));
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ error: "Método no permitido" }, { status: 405 });
  if (!authorized(request)) return Response.json({ error: "No autorizado" }, { status: 401 });
  if (!vapidPublicKey || !vapidPrivateKey) return Response.json({ error: "VAPID no configurado" }, { status: 503 });

  const webhook = await request.json().catch(() => ({}));
  const jobId = String(webhook?.record?.id || webhook?.id || "");
  if (!/^[0-9a-f-]{36}$/i.test(jobId)) return Response.json({ error: "Trabajo inválido" }, { status: 400 });
  const { data: job, error: jobError } = await admin
    .from("driver_push_jobs")
    .select("id,offer_id,driver_id,trip_id")
    .eq("id", jobId)
    .maybeSingle();
  if (jobError || !job) return Response.json({ ok: true, skipped: "missing" });
  const { data: offer } = await admin
    .from("trip_offers")
    .select("id,status,expires_at")
    .eq("id", job.offer_id)
    .maybeSingle();
  if (!offer || offer.status !== "offered" || Date.parse(offer.expires_at) <= Date.now()) {
    await admin.from("driver_push_jobs").update({ failed_at: new Date().toISOString(), failure_reason: "Oferta vencida antes de entregar" }).eq("id", job.id);
    return Response.json({ ok: true, skipped: "expired" });
  }
  const { data: subscriptions = [] } = await admin
    .from("driver_push_subscriptions")
    .select("id,endpoint,p256dh,auth")
    .eq("driver_id", job.driver_id);
  webpush.setVapidDetails("mailto:soporte@yavoi.app", vapidPublicKey, vapidPrivateKey);
  const { data: finance } = await admin.rpc('yavoi_offer_finance', { offer_id: job.offer_id });
  const netLabel = finance ? new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' }).format(Number(finance.net_cents) / 100) : '';
  const payload = JSON.stringify({
    title: "Nueva solicitud de viaje",
    body: finance ? `Neto estimado ${netLabel}${finance.promotion_pending_cents ? ' · incluye promoción por conciliar' : ''}. Abre Yavoi! para ver comisión, impuestos y aceptar.` : "Tienes un viaje disponible. Abre Yavoi! y decide antes de que venza.",
    tag: `yavoi-offer-${job.offer_id}`,
    target: "home",
    offer_id: job.offer_id,
    require_interaction: true,
    renotify: true,
    actions: [{ action: "open", title: "Ver solicitud" }],
  });
  const deliveries = await Promise.allSettled(subscriptions.map((subscription) => webpush.sendNotification(
    { endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } },
    payload,
    { TTL: 60, urgency: "high", topic: `yavoi-${job.offer_id.slice(0, 24)}` },
  )));
  const invalid = deliveries.flatMap((result, index) => result.status === "rejected" && [404, 410].includes(Number(result.reason?.statusCode)) ? [subscriptions[index].id] : []);
  if (invalid.length) await admin.from("driver_push_subscriptions").delete().in("id", invalid);
  const failures = deliveries.filter((result) => result.status === "rejected");
  await admin.from("driver_push_jobs").update(
    failures.length === deliveries.length
      ? { failed_at: new Date().toISOString(), failure_reason: "No se pudo entregar a un dispositivo registrado" }
      : { delivered_at: new Date().toISOString() },
  ).eq("id", job.id);
  return Response.json({ ok: true, delivered: deliveries.length - failures.length, failed: failures.length });
});
