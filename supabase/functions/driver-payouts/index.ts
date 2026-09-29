import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.116.0';
import { payoutEvent, signPayout } from './provider.js';
const url = Deno.env.get('SUPABASE_URL') || '';
const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const admin = createClient(url, service, { auth: { persistSession: false } });
function authorized(request: Request) {
  const token = Deno.env.get('PAYOUT_WORKER_TOKEN') || '';
  const supplied = request.headers.get('x-yavoi-payout-token') || '';
  if (token && supplied.length === token.length && [...token].reduce((n, c, i) => n | (c.charCodeAt(0) ^ supplied.charCodeAt(i)), 0) === 0) return true;
  const apiKey = request.headers.get('apikey') || request.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  const secretKeys = Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}'));
  return Boolean(apiKey && (apiKey === service || secretKeys.includes(apiKey)));
}
Deno.serve(async request => {
  if (request.method !== 'POST' || !authorized(request)) return Response.json({ error: 'No autorizado' }, { status: 401 });
  const token = Deno.env.get('MP_ACCESS_TOKEN') || '';
  const pem = Deno.env.get('MP_PAYOUT_SIGNING_PRIVATE_KEY') || '';
  // This gate is explicit: an existing card-payment token does not prove that
  // Mercado Pago has authorized bank payouts or registered the signing key.
  if (Deno.env.get('MP_PAYOUTS_ENABLED') !== 'true' || !token || !pem) return Response.json({ error: 'Payouts requiere habilitación y firma de producción en Mercado Pago.' }, { status: 503 });
  const { data: jobs, error } = await admin.rpc('yavoi_payout_worker', { command: 'claim' });
  if (error) return Response.json({ error: 'No se pudo reservar la cola de retiros.' }, { status: 500 });
  let processed = 0;
  for (const job of jobs || []) {
    try {
      if (!job.provider_payout_id) {
        const body = JSON.stringify(job.provider_body);
        const signature = await signPayout(body, pem);
        const res = await fetch('https://api.mercadopago.com/v1/payouts', {
          method: 'POST', signal: AbortSignal.timeout(15000),
          headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', 'X-Idempotency-Key': job.id, 'X-enforce-signature': 'true', 'X-signature': signature, 'X-test-token': 'false' }, body,
        });
        if (!res.ok) throw Error(`Mercado Pago respondió ${res.status}. Requiere revisión; el saldo sigue reservado.`);
        const result = await res.json(); const transaction = result.transactions?.find((x: Record<string,unknown>) => String(x.external_reference) === String(job.provider_reference));
        if (!result.id || !transaction?.id) throw Error('El proveedor no confirmó identificadores; conserva la reserva.');
        const registered = await admin.rpc('yavoi_payout_worker', { command: 'registered', payload: { withdrawal_id: job.id, payout_id: String(result.id), transaction_id: String(transaction.id) } });
        if (registered.error) throw registered.error;
        job.provider_payout_id = String(result.id); job.provider_transaction_id = String(transaction.id);
      }
      const result = await fetch(`https://api.mercadopago.com/v1/payouts/${encodeURIComponent(job.provider_payout_id)}/transactions/${encodeURIComponent(job.provider_transaction_id)}`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10000) });
      if (!result.ok) throw Error('La transferencia sigue pendiente de verificación.');
      const transaction = await result.json();
      const saved = await admin.rpc('yavoi_payout_worker', { command: 'result', payload: payoutEvent(job, transaction) });
      if (saved.error) throw saved.error;
      processed++;
    } catch (err) {
      await admin.rpc('yavoi_payout_worker', { command: 'error', payload: { withdrawal_id: job.id, message: err instanceof Error ? err.message.slice(0,240) : 'Error de proveedor. Saldo reservado.' } });
    }
  }
  return Response.json({ processed, jobs: (jobs || []).length });
});
