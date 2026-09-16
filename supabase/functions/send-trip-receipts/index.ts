import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { buildReceiptContent } from "./template.js";

const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});

const bytesToBase64 = (bytes: Uint8Array) => {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return btoa(binary);
};
const mimeBase64 = (bytes: Uint8Array) => bytesToBase64(bytes).replace(/.{1,76}/g, "$&\r\n").trim();
const base64Url = (bytes: Uint8Array) => bytesToBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
const encodedHeader = (value: string) => `=?UTF-8?B?${bytesToBase64(new TextEncoder().encode(value))}?=`;

function constantTimeEqual(left: string, right: string) {
  if (!left || left.length !== right.length) return false;
  let different = 0;
  for (let index = 0; index < left.length; index++) different |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return different === 0;
}

async function gmailAccessToken() {
  const clientId = Deno.env.get("GMAIL_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("GMAIL_CLIENT_SECRET") || "";
  const refreshToken = Deno.env.get("GMAIL_REFRESH_TOKEN") || "";
  if (!clientId || !clientSecret || !refreshToken) throw new Error("Gmail todavía no está configurado en los secretos de Supabase.");
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken, grant_type: "refresh_token" }),
  });
  const token = await tokenResponse.json();
  if (!tokenResponse.ok || !token.access_token) throw new Error("Google rechazó la autorización para enviar correos.");
  return String(token.access_token);
}

async function receiptMime(item: Record<string, unknown>, supabase: ReturnType<typeof createClient>) {
  const content = buildReceiptContent(item);
  const { data: photo, error } = await supabase.storage.from("yavoi-avatars").download(content.driverPhotoPath);
  if (error || !photo || !photo.type.startsWith("image/")) throw new Error("No fue posible incorporar la fotografía protegida del conductor.");
  const boundary = `yavoi-related-${crypto.randomUUID()}`;
  const alternative = `yavoi-alternative-${crypto.randomUUID()}`;
  const sender = Deno.env.get("GMAIL_SENDER_EMAIL") || "admin.yavoi@gmail.com";
  if (/[\r\n]/.test(sender)) throw new Error("Remitente inválido.");
  const photoBytes = new Uint8Array(await photo.arrayBuffer());
  const lines = [
    `From: Yavoi! <${sender}>`, `To: ${content.email}`, `Subject: ${encodedHeader(content.subject)}`,
    "MIME-Version: 1.0", `Content-Type: multipart/related; boundary="${boundary}"`, "",
    `--${boundary}`, `Content-Type: multipart/alternative; boundary="${alternative}"`, "",
    `--${alternative}`, "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
    mimeBase64(new TextEncoder().encode(content.text)), "",
    `--${alternative}`, "Content-Type: text/html; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
    mimeBase64(new TextEncoder().encode(content.html)), "", `--${alternative}--`, "",
    `--${boundary}`, `Content-Type: ${photo.type}`, "Content-Transfer-Encoding: base64",
    "Content-ID: <driver-photo>", `Content-Disposition: inline; filename="conductor-${content.folio}.jpg"`, "",
    mimeBase64(photoBytes), "", `--${boundary}--`, "",
  ];
  return { raw: base64Url(new TextEncoder().encode(lines.join("\r\n"))), content };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return response({ error: "Método no permitido." }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const service = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { return response({ error: "Solicitud inválida." }, 400); }
  let callerId: string | null = null;
  const cronToken = Deno.env.get("RECEIPT_CRON_TOKEN") || "";
  const suppliedCronToken = req.headers.get("x-yavoi-receipt-token") || "";
  if (!constantTimeEqual(cronToken, suppliedCronToken)) {
    const authorization = req.headers.get("authorization") || "";
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } });
    const { data, error } = await userClient.auth.getUser();
    if (error || !data.user) return response({ error: "Sesión no válida." }, 401);
    callerId = data.user.id;
    if (!body.trip_id) return response({ error: "El viaje es obligatorio para un envío manual." }, 400);
  }
  try {
    const accessToken = await gmailAccessToken();
    const { data: claimed, error: claimError } = await service.rpc("yavoi_receipt_claim", {
      payload: { trip_id: body.trip_id || null, caller_id: callerId, batch_size: callerId ? 1 : 5 },
    });
    if (claimError) throw claimError;
    const results = [];
    for (const item of claimed || []) {
      try {
        const { raw, content } = await receiptMime(item, service);
        const sentResponse = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
          method: "POST",
          headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
          body: JSON.stringify({ raw }),
        });
        const sent = await sentResponse.json();
        if (!sentResponse.ok || !sent.id) throw new Error("Gmail no confirmó el envío del recibo.");
        const { error: completeError } = await service.rpc("yavoi_receipt_complete", { payload: { trip_id: item.trip_id, lease_token: item.lease_token, success: true, provider_message_id: sent.id, caller_id: callerId } });
        if (completeError) {
          results.push({ trip_id: item.trip_id, status: "sent_unconfirmed", receipt_number: content.folio });
          continue;
        }
        results.push({ trip_id: item.trip_id, status: "sent", receipt_number: content.folio });
      } catch (error) {
        const { error: completeError } = await service.rpc("yavoi_receipt_complete", { payload: { trip_id: item.trip_id, lease_token: item.lease_token, success: false, error: error instanceof Error ? error.message : "Fallo temporal", caller_id: callerId } });
        if (completeError) return response({ error: "No se pudo conservar el resultado del envío.", processed: results.length }, 503);
        results.push({ trip_id: item.trip_id, status: "failed" });
      }
    }
    return response({ ok: results.every((item) => item.status === "sent"), processed: results.length, results });
  } catch (error) {
    return response({ error: error instanceof Error ? error.message : "No se pudo procesar la entrega." }, 503);
  }
});
