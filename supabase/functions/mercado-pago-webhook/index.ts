import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});

async function signatureIsValid(signature: string, requestId: string, dataId: string, secret: string) {
  const parts = Object.fromEntries(signature.split(",").map((part) => part.trim().split("=", 2)));
  if (!parts.ts || !parts.v1 || !/^\d+$/.test(parts.ts)) return false;
  const age = Math.abs(Date.now() - Number(parts.ts) * 1000);
  if (!Number.isFinite(age) || age > 5 * 60 * 1000) return false;
  const manifest = `id:${dataId.toLowerCase()};request-id:${requestId};ts:${parts.ts};`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifest));
  const expected = [...new Uint8Array(signed)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  if (expected.length !== parts.v1.length) return false;
  let different = 0;
  for (let index = 0; index < expected.length; index++) different |= expected.charCodeAt(index) ^ parts.v1.charCodeAt(index);
  return different === 0;
}

function eventFrom(payment: Record<string, unknown>, eventKey: string) {
  const feeDetails = Array.isArray(payment.fee_details) ? payment.fee_details as Array<Record<string, unknown>> : [];
  const transaction = (payment.transaction_details || {}) as Record<string, unknown>;
  return {
    external_reference: String(payment.external_reference || ""),
    provider_payment_id: String(payment.id || ""),
    amount_cents: Math.round(Number(payment.transaction_amount || 0) * 100),
    status: String(payment.status || "pending"),
    status_detail: String(payment.status_detail || ""),
    payment_method_type: String(payment.payment_type_id || ""),
    payment_method_id: String(payment.payment_method_id || ""),
    installments: String(payment.installments || ""),
    processing_fee_cents: Math.round(feeDetails.reduce((sum, item) => sum + Number(item.amount || 0), 0) * 100),
    net_received_cents: Math.round(Number(transaction.net_received_amount || 0) * 100),
    live_mode: String(Boolean(payment.live_mode)),
    provider_created_at: String(payment.date_created || ""),
    provider_approved_at: String(payment.date_approved || ""),
    event_key: eventKey,
    event_type: "webhook",
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return response({ error: "Método no permitido." }, 405);
  const secret = Deno.env.get("MP_WEBHOOK_SECRET") || "";
  const accessToken = Deno.env.get("MP_ACCESS_TOKEN") || "";
  if (!secret || !accessToken) return response({ error: "Webhook pendiente de configuración." }, 503);
  const url = new URL(req.url);
  const dataId = url.searchParams.get("data.id") || url.searchParams.get("id") || "";
  const signature = req.headers.get("x-signature") || "";
  const requestId = req.headers.get("x-request-id") || "";
  if (!dataId || !requestId || !(await signatureIsValid(signature, requestId, dataId, secret)))
    return response({ error: "Firma inválida." }, 401);
  try {
    const providerResponse = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(dataId)}`, {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    if (!providerResponse.ok) return response({ error: "No se pudo verificar el pago." }, 502);
    const payment = await providerResponse.json();
    if (String(payment.id) !== dataId || !payment.external_reference) return response({ error: "Pago no reconocido." }, 400);
    const supabase = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "", { auth: { persistSession: false } });
    const event = eventFrom(payment, `webhook:${requestId}:${payment.status}:${payment.date_last_updated || "update"}`);
    const { error } = await supabase.rpc("yavoi_payment_event", { payload: event });
    if (error) throw error;
    return response({ received: true }, 200);
  } catch {
    return response({ error: "No se pudo registrar la notificación." }, 500);
  }
});
