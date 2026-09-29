export function settledPayout(transaction) {
  return (transaction.status === 'processed' && transaction.status_detail === 'approved') ||
    (transaction.status === 'success' && transaction.status_detail === 'accredited');
}
export function payoutEvent(w, transaction) {
  if (String(transaction.id) !== w.provider_transaction_id || String(transaction.external_reference) !== String(w.provider_reference) || transaction.amount?.currency !== 'MXN' || Math.round(Number(transaction.amount?.value) * 100) !== Number(w.net_cents)) throw Error('La respuesta del proveedor no coincide con el retiro.');
  return { withdrawal_id: w.id, transaction_id: String(transaction.id), external_reference: String(transaction.external_reference), amount_cents: Number(w.net_cents), currency: 'MXN', status: String(transaction.status), status_detail: String(transaction.status_detail || '') };
}
export async function signPayout(body, pem) {
  const raw = pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
  const bytes = Uint8Array.from(atob(raw), x => x.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', bytes, { name: 'Ed25519' }, false, ['sign']);
  const signature = new Uint8Array(await crypto.subtle.sign('Ed25519', key, new TextEncoder().encode(body)));
  return btoa(String.fromCharCode(...signature));
}
