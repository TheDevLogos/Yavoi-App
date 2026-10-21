import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const url = Deno.env.get("SUPABASE_URL") || "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const vapidPublic = Deno.env.get("WEB_PUSH_VAPID_PUBLIC_KEY") || "";
const vapidPrivate = Deno.env.get("WEB_PUSH_VAPID_PRIVATE_KEY") || "";
const firebaseServiceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "";
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

function b64url(value: Uint8Array | string) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function firebaseAccessToken() {
  const account = JSON.parse(firebaseServiceAccountJson || "{}");
  if (!account.project_id || !account.client_email || !account.private_key) throw Error("Firebase no está configurado.");
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({ iss: account.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }));
  const unsigned = `${head}.${claims}`;
  const pem = String(account.private_key).replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const bytes = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", bytes, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = b64url(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned))));
  const response = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${signature}` }) });
  const result = await response.json();
  if (!response.ok || !result.access_token) throw Error("Firebase rechazó la credencial.");
  return { projectId: String(account.project_id), token: String(result.access_token) };
}

function imageUrl(path: string | null) {
  if (!path) return undefined;
  return `${url}/storage/v1/object/public/yavoi-marketing/${path.split("/").map(encodeURIComponent).join("/")}`;
}

async function mapInBatches<T, R>(items: T[], batchSize: number, send: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = [];
  for (let offset = 0; offset < items.length; offset += batchSize) {
    results.push(...await Promise.all(items.slice(offset, offset + batchSize).map(send)));
  }
  return results;
}

async function sendNative(token: string, credentials: { projectId: string; token: string }, message: Record<string, unknown>, app: string) {
  const image = imageUrl(message.image_path as string | null);
  const ttlSeconds = Math.max(1, Math.min(86400, Math.floor((Date.parse(String(message.ends_at)) - Date.now()) / 1000)));
  const notification = { title: message.title, body: message.body, ...(image ? { image } : {}) };
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(credentials.projectId)}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${credentials.token}`, "content-type": "application/json" },
    body: JSON.stringify({ message: {
      token, notification,
      data: { target: "inbox", message_id: String(message.id), app },
      android: { priority: "NORMAL", ttl: `${ttlSeconds}s`, notification: { channel_id: "yavoi_updates", tag: `yavoi-communication-${message.id}`, ...(image ? { image } : {}) } },
      apns: { headers: { "apns-expiration": String(Math.floor(Date.now() / 1000) + ttlSeconds) }, payload: { aps: { "mutable-content": 1, sound: "default" } }, ...(image ? { fcm_options: { image } } : {}) },
    } }),
  });
  return response.ok;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ error: "Método no permitido" }, { status: 405 });
  const workerToken = request.headers.get("x-yavoi-communications-worker") || "";
  if (workerToken) {
    const { data: verified, error } = await admin.rpc("verify_yavoi_communications_worker_token", { supplied_token: workerToken });
    if (error || verified !== true) return Response.json({ error: "Trabajador no autorizado" }, { status: 401 });
  } else {
    const jwt = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") || "";
    const { data: authResult, error: authError } = await admin.auth.getUser(jwt);
    if (authError || !authResult.user) return Response.json({ error: "Sesión inválida" }, { status: 401 });
    let claims: Record<string, unknown> = {};
    try { claims = JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); } catch { /* rejected below */ }
    const { data: operator } = await admin.from("profiles").select("role,suspended").eq("id", authResult.user.id).maybeSingle();
    if (claims.aal !== "aal2" || operator?.role !== "admin" || operator.suspended) return Response.json({ error: "Operaciones requiere verificación en dos pasos" }, { status: 403 });
  }
  const body = await request.json().catch(() => ({}));
  const messageId = String(body.message_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(messageId)) return Response.json({ error: "Mensaje inválido" }, { status: 400 });
  const { data: message, error: messageError } = await admin.from("communication_messages").select("id,audience,recipient_id,category,title,body,image_path,send_push,ends_at").eq("id", messageId).maybeSingle();
  if (messageError) return Response.json({ error: "No se pudo consultar el aviso" }, { status: 500 });
  if (!message || !message.send_push) return Response.json({ error: "Trabajo no encontrado" }, { status: 404 });
  if (Date.parse(message.ends_at) <= Date.now()) return Response.json({ error: "El mensaje ya no está vigente" }, { status: 409 });
  const { data: claim, error: claimError } = await admin.rpc("claim_yavoi_communications_push_job", { target_message_id: messageId });
  if (claimError) return Response.json({ error: "No se pudo reservar el envío push" }, { status: 500 });
  if (!claim?.claimed) {
    if (claim?.not_found) return Response.json({ error: "Trabajo no encontrado" }, { status: 404 });
    return Response.json({ ok: true, more: false, processing: Boolean(claim?.processing), delivered: Number(claim?.delivered_count || 0), failed: Number(claim?.failed_count || 0) }, { status: claim?.complete ? 200 : 202 });
  }
  const job = {
    id: String(claim.job_id),
    claim_token: String(claim.claim_token),
    last_profile_id: claim.last_profile_id ? String(claim.last_profile_id) : null,
    delivered_count: Number(claim.delivered_count || 0),
    failed_count: Number(claim.failed_count || 0),
  };
  let query = admin.from("profiles").select("id,role").eq("suspended", false).in("role", ["passenger", "driver"]).order("id", { ascending: true }).limit(50);
  if (message.recipient_id) query = query.eq("id", message.recipient_id);
  else if (message.audience !== "all") query = query.eq("role", message.audience);
  if (job.last_profile_id) query = query.gt("id", job.last_profile_id);
  const { data: recipients, error: recipientsError } = await query;
  if (recipientsError) return Response.json({ error: recipientsError.message }, { status: 500 });
  if (!recipients?.length) {
    const { data: completed, error: completeError } = await admin.from("communication_push_jobs")
      .update({ state: "complete", last_error: null, claim_token: null, claim_expires_at: null, updated_at: new Date().toISOString() })
      .eq("id", job.id).eq("claim_token", job.claim_token).select("id");
    if (completeError || !completed?.length) return Response.json({ error: "El turno de envío venció; la cola lo reintentará." }, { status: 409 });
    return Response.json({ ok: true, more: false, delivered: job.delivered_count, failed: job.failed_count });
  }
  const ids = recipients.map((item) => item.id);
  const [prefsResult, webResult, nativeResult] = await Promise.all([
    admin.from("communication_push_preferences").select("profile_id,marketing_enabled").in("profile_id", ids),
    admin.from("device_push_subscriptions").select("id,profile_id,endpoint,p256dh,auth").in("profile_id", ids),
    admin.from("native_push_tokens").select("id,profile_id,token,app_id").in("profile_id", ids),
  ]);
  if (prefsResult.error || webResult.error || nativeResult.error) return Response.json({ error: "No se pudieron consultar los dispositivos" }, { status: 500 });
  const optedIn = new Set((prefsResult.data || []).filter((row) => row.marketing_enabled).map((row) => row.profile_id));
  // Manual campaigns require explicit consent regardless of their label.
  // Transactional trip and safety pushes use their existing dedicated flow.
  const allowed = new Set(ids.filter((id) => optedIn.has(id)));
  const web = (webResult.data || []).filter((row) => allowed.has(row.profile_id));
  const native = (nativeResult.data || []).filter((row) => allowed.has(row.profile_id) && (row.app_id === "universal" || row.app_id === (recipients.find((person) => person.id === row.profile_id)?.role === "driver" ? "mx.yavoi.conductor" : "mx.yavoi.pasajero")));
  let delivered = 0;
  let failed = 0;
  if (web.length && vapidPublic && vapidPrivate) {
    webpush.setVapidDetails("mailto:soporte@yavoi.app", vapidPublic, vapidPrivate);
    const payload = JSON.stringify({ title: message.title, body: message.body, image: imageUrl(message.image_path), target: "inbox", tag: `yavoi-communication-${message.id}`, actions: [{ action: "open", title: "Ver mensaje" }] });
    const results = await mapInBatches(web, 20, async (subscription) => {
      try {
        await webpush.sendNotification({ endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } }, payload, { TTL: 86400 });
        return true;
      } catch (error) {
        if ([404, 410].includes(Number((error as { statusCode?: number }).statusCode))) await admin.from("device_push_subscriptions").delete().eq("id", subscription.id);
        return false;
      }
    });
    delivered += results.filter(Boolean).length;
    failed += results.filter((ok) => !ok).length;
  } else failed += web.length;
  if (native.length && firebaseServiceAccountJson) {
    try {
      const credentials = await firebaseAccessToken();
      const results = await mapInBatches(native, 20, (device) => sendNative(device.token, credentials, message, device.app_id));
      delivered += results.filter(Boolean).length;
      failed += results.filter((ok) => !ok).length;
    } catch { failed += native.length; }
  } else failed += native.length;
  const lastId = recipients.at(-1)?.id || job.last_profile_id;
  const more = recipients.length === 50 && !message.recipient_id;
  const { data: updated, error: updateError } = await admin.from("communication_push_jobs").update({
    last_profile_id: lastId,
    state: more ? "sending" : "complete",
    delivered_count: job.delivered_count + delivered,
    failed_count: job.failed_count + failed,
    last_error: failed ? `${failed} dispositivos sin entrega en este lote` : null,
    claim_token: null,
    claim_expires_at: null,
    updated_at: new Date().toISOString(),
  }).eq("id", job.id).eq("claim_token", job.claim_token).select("id");
  if (updateError || !updated?.length) return Response.json({ error: "El turno de envío venció; la cola lo reintentará." }, { status: 409 });
  return Response.json({ ok: true, more, delivered: job.delivered_count + delivered, failed: job.failed_count + failed });
});
