import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const vapidPublicKey = Deno.env.get("WEB_PUSH_VAPID_PUBLIC_KEY") || "";
const vapidPrivateKey = Deno.env.get("WEB_PUSH_VAPID_PRIVATE_KEY") || "";
const firebaseServiceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "";
const admin = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });
let cachedGoogleAccessToken = "";
let cachedGoogleAccessTokenExpiresAt = 0;

function base64Url(value: Uint8Array | string) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function firebaseAccessToken() {
  if (cachedGoogleAccessToken && cachedGoogleAccessTokenExpiresAt > Date.now() + 60_000) return cachedGoogleAccessToken;
  const account = JSON.parse(firebaseServiceAccountJson || "{}");
  const projectId = String(account.project_id || "");
  const clientEmail = String(account.client_email || "");
  const privateKey = String(account.private_key || "");
  if (!projectId || !clientEmail || !privateKey) throw new Error("Credencial FCM de servidor inválida");
  const now = Math.floor(Date.now() / 1000);
  const assertionBase = `${base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${base64Url(JSON.stringify({
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }))}`;
  const pemBytes = Uint8Array.from(atob(privateKey.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "")), (character) => character.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", pemBytes, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(assertionBase)));
  const assertion = `${assertionBase}.${base64Url(signature)}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || !result.access_token) throw new Error("No se pudo autenticar el envío FCM");
  cachedGoogleAccessToken = String(result.access_token);
  cachedGoogleAccessTokenExpiresAt = Date.now() + Number(result.expires_in || 3600) * 1000;
  return cachedGoogleAccessToken;
}

async function sendFirebaseMessage(projectId: string, accessToken: string, token: string, offerId: string, body: string, ttlSeconds: number) {
  return fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ message: {
      token,
      notification: { title: "Nueva solicitud de viaje", body },
      data: { offer_id: offerId, target: "home" },
      android: {
        priority: "HIGH",
        ttl: `${ttlSeconds}s`,
        notification: { channel_id: "yavoi_trips", tag: `yavoi-offer-${offerId}`, sound: "default", visibility: "PUBLIC" },
      },
    } }),
  });
}

function authorized(request: Request) {
  const values = Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"));
  const apiKey = request.headers.get("apikey") || request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  return Boolean(apiKey && values.includes(apiKey));
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ error: "Método no permitido" }, { status: 405 });
  if (!authorized(request)) return Response.json({ error: "No autorizado" }, { status: 401 });
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
  const [subscriptionResult, nativeTokenResult, financeResult] = await Promise.all([
    admin.from("driver_push_subscriptions").select("id,endpoint,p256dh,auth").eq("driver_id", job.driver_id),
    admin.from("native_push_tokens").select("id,token").eq("profile_id", job.driver_id),
    admin.rpc('yavoi_offer_finance', { offer_id: job.offer_id }),
  ]);
  const subscriptions = subscriptionResult.data || [];
  const nativeTokens = nativeTokenResult.data || [];
  const finance = financeResult.data;
  if (Date.parse(offer.expires_at) <= Date.now()) {
    await admin.from("driver_push_jobs").update({ failed_at: new Date().toISOString(), failure_reason: "Oferta vencida antes de entregar" }).eq("id", job.id);
    return Response.json({ ok: true, skipped: "expired" });
  }
  const netLabel = finance ? new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' }).format(Number(finance.net_cents) / 100) : '';
  const notificationBody = finance ? `Neto estimado ${netLabel}${finance.promotion_pending_cents ? ' · incluye promoción por conciliar' : ''}. Abre Yavoi! para ver comisión, impuestos y aceptar.` : "Tienes un viaje disponible. Abre Yavoi! y decide antes de que venza.";
  const ttlSeconds = Math.max(1, Math.min(8, Math.ceil((Date.parse(offer.expires_at) - Date.now()) / 1000)));
  const payload = JSON.stringify({
    title: "Nueva solicitud de viaje",
    body: notificationBody,
    tag: `yavoi-offer-${job.offer_id}`,
    target: "home",
    offer_id: job.offer_id,
    require_interaction: true,
    renotify: true,
    actions: [{ action: "open", title: "Ver solicitud" }],
  });
  const pendingWebDeliveries = subscriptions.length && vapidPublicKey && vapidPrivateKey ? (() => {
    webpush.setVapidDetails("mailto:soporte@yavoi.app", vapidPublicKey, vapidPrivateKey);
    return subscriptions.map((subscription) => webpush.sendNotification(
    { endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } },
    payload,
    { TTL: Math.max(1, Math.min(8, Math.ceil((Date.parse(offer.expires_at) - Date.now()) / 1000))), urgency: "high", topic: `yavoi-${job.offer_id.slice(0, 24)}` },
    ));
  })() : [];
  const firebaseAccount = JSON.parse(firebaseServiceAccountJson || "{}");
  let fcmError = "";
  let fcmDeliveries: PromiseSettledResult<Response>[] = [];
  if (nativeTokens.length && firebaseServiceAccountJson) {
    try {
      if (firebaseAccount.project_id !== "yavoi-4a7af") throw new Error("La credencial pertenece a otro proyecto de Firebase");
      const accessToken = await firebaseAccessToken();
      fcmDeliveries = await Promise.allSettled(nativeTokens.map((item) => sendFirebaseMessage(String(firebaseAccount.project_id), accessToken, item.token, job.offer_id, notificationBody, ttlSeconds)));
    } catch (error) {
      fcmError = error instanceof Error ? error.message : "No se pudo enviar por Firebase";
    }
  }
  const webDeliveries = await Promise.allSettled(pendingWebDeliveries);
  const invalidWeb = webDeliveries.flatMap((result, index) => result.status === "rejected" && [404, 410].includes(Number(result.reason?.statusCode)) ? [subscriptions[index].id] : []);
  const invalidNative = fcmDeliveries.flatMap((result, index) => result.status === "fulfilled" && !result.value.ok && [400, 404].includes(result.value.status) ? [nativeTokens[index].id] : []);
  if (invalidNative.length) await admin.from("native_push_tokens").delete().in("id", invalidNative);
  if (invalidWeb.length) await admin.from("driver_push_subscriptions").delete().in("id", invalidWeb);
  const allDeliveries = [...webDeliveries, ...fcmDeliveries];
  const successes = webDeliveries.filter((result) => result.status === "fulfilled").length + fcmDeliveries.filter((result) => result.status === "fulfilled" && result.value.ok).length;
  const unconfiguredDevices = (nativeTokens.length && !firebaseServiceAccountJson ? nativeTokens.length : 0) + (subscriptions.length && (!vapidPublicKey || !vapidPrivateKey) ? subscriptions.length : 0);
  const failures = allDeliveries.length - successes + unconfiguredDevices;
  await admin.from("driver_push_jobs").update(
    successes === 0
      ? { failed_at: new Date().toISOString(), failure_reason: fcmError || (nativeTokens.length && !firebaseServiceAccountJson ? "FIREBASE_SERVICE_ACCOUNT_JSON no configurado" : (subscriptions.length && (!vapidPublicKey || !vapidPrivateKey) ? "Credenciales VAPID no configuradas" : "No se pudo entregar a un dispositivo registrado")) }
      : { delivered_at: new Date().toISOString(), failed_at: null, failure_reason: failures ? "Uno o más dispositivos no recibieron la alerta" : null },
  ).eq("id", job.id);
  return Response.json({ ok: successes > 0, delivered: successes, failed: failures, native_devices: nativeTokens.length, web_devices: subscriptions.length, fcm_configured: Boolean(firebaseServiceAccountJson) });
});
