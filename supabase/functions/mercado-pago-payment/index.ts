import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const json = (body: unknown, status = 200, origin = "") =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "access-control-allow-origin": origin,
      "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
      "access-control-allow-methods": "POST, OPTIONS",
      vary: "Origin",
    },
  });

function allowedOrigin(req: Request) {
  const origin = req.headers.get("origin") || "";
  const configured = (Deno.env.get("APP_ORIGINS") || "https://yavoi-delicias.alonsovl-logos88.chatgpt.site")
    .split(",")
    .map((value) => value.trim());
  if (configured.includes(origin) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) return origin;
  return "";
}

function safePaymentEvent(payment: Record<string, unknown>, externalReference: string, eventKey: string) {
  const feeDetails = Array.isArray(payment.fee_details) ? payment.fee_details as Array<Record<string, unknown>> : [];
  const transaction = (payment.transaction_details || {}) as Record<string, unknown>;
  return {
    external_reference: externalReference,
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
    event_type: "payment_api",
  };
}

Deno.serve(async (req: Request) => {
  const origin = allowedOrigin(req);
  if (!origin) return json({ error: "Origen no permitido." }, 403, "null");
  if (req.method === "OPTIONS") return json({ ok: true }, 200, origin);
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405, origin);
  const authorization = req.headers.get("authorization") || "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const accessToken = Deno.env.get("MP_ACCESS_TOKEN") || "";
  if (!accessToken) return json({ error: "Mercado Pago está listo, pero Operaciones aún no cargó las credenciales." }, 503, origin);

  try {
    const body = await req.json();
    if (!body || typeof body !== "object") throw new Error("Solicitud inválida.");
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } });
    const serviceClient = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) return json({ error: "Sesión no válida." }, 401, origin);

    if (body.action === "refund") {
      const { data: refundData, error: refundError } = await userClient.rpc("yavoi", {
        command: "refund_checkout",
        payload: { payment_id: body.payment_id },
      });
      if (refundError) throw refundError;
      const response = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(refundData.provider_payment_id)}/refunds`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
          "x-idempotency-key": refundData.refund_idempotency_key,
        },
        body: "{}",
      });
      const result = await response.json();
      if (!response.ok) return json({ error: "Mercado Pago no pudo completar el reembolso.", status: result.status || "error" }, response.status, origin);
      const { error: eventError } = await serviceClient.rpc("yavoi_payment_event", {
        payload: {
          external_reference: refundData.payment_id,
          provider_payment_id: refundData.provider_payment_id,
          amount_cents: refundData.amount_cents,
          status: "refunded",
          status_detail: String(result.status || "approved"),
          event_key: `refund:${result.id || refundData.refund_idempotency_key}`,
          event_type: "refund_api",
        },
      });
      if (eventError) throw eventError;
      return json({ ok: true, status: "refunded" }, 200, origin);
    }

    const form = body.form_data || {};
    if (typeof form.token !== "string" || form.token.length < 10 || typeof form.payment_method_id !== "string")
      return json({ error: "Los datos seguros de la tarjeta están incompletos." }, 400, origin);
    const { data: checkout, error: checkoutError } = await userClient.rpc("yavoi", {
      command: "payment_checkout",
      payload: { payment_id: body.payment_id },
    });
    if (checkoutError) throw checkoutError;
    const paymentBody = {
      token: form.token,
      transaction_amount: checkout.amount_cents / 100,
      installments: Math.max(1, Math.min(48, Number(form.installments || 1))),
      payment_method_id: String(form.payment_method_id).slice(0, 50),
      issuer_id: form.issuer_id ? String(form.issuer_id).slice(0, 50) : undefined,
      payer: {
        email: checkout.payer_email,
        identification: form.payer?.identification?.type && form.payer?.identification?.number
          ? {
              type: String(form.payer.identification.type).slice(0, 20),
              number: String(form.payer.identification.number).slice(0, 40),
            }
          : undefined,
      },
      description: checkout.description,
      external_reference: checkout.payment_id,
      notification_url: `${supabaseUrl}/functions/v1/mercado-pago-webhook`,
      statement_descriptor: "YAVOI",
      three_d_secure_mode: "optional",
      metadata: { trip_id: checkout.trip_id || null, payment_kind: checkout.kind },
    };
    const response = await fetch("https://api.mercadopago.com/v1/payments", {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-idempotency-key": checkout.idempotency_key,
      },
      body: JSON.stringify(paymentBody),
    });
    const result = await response.json();
    if (result.id && result.status) {
      const event = safePaymentEvent(result, checkout.payment_id, `api:${result.id}:${result.status}:${result.date_last_updated || "initial"}`);
      const { error: eventError } = await serviceClient.rpc("yavoi_payment_event", { payload: event });
      if (eventError) throw eventError;
    }
    if (!response.ok) return json({ error: "Mercado Pago no aprobó la solicitud.", status: result.status || "rejected", detail: result.status_detail || "" }, response.status, origin);
    return json({ ok: true, payment_id: checkout.payment_id, provider_payment_id: String(result.id), status: result.status, status_detail: result.status_detail }, 200, origin);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "No se pudo procesar el pago." }, 400, origin);
  }
});
