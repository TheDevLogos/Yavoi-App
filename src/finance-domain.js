// Presentation math only. Postgres is the authority for amounts and reservations.
export function splitIncludedVat(gross) {
  const base = Math.round(Number(gross || 0) / 1.16);
  return { base, vat: Number(gross || 0) - base };
}
export function withdrawalPreview(gross, mode) {
  const fee = mode === 'daily' ? Math.round(Number(gross) * 0.03) : 0;
  return { gross: Number(gross), fee, feeVat: splitIncludedVat(fee).vat, net: Number(gross) - fee };
}
export function validClabe(value) {
  if (!/^\d{18}$/.test(value)) return false;
  const sum = [...value.slice(0, 17)].reduce((n, d, i) => n + Number(d) * [3, 7, 1][i % 3], 0);
  return (10 - sum % 10) % 10 === Number(value[17]);
}
export function barPercent(value, values) {
  return Math.max(0, Math.min(100, Number(value || 0) / Math.max(1, ...values.map(Number)) * 100));
}
export const entryNames = {
  card_credit: 'Pago electrónico del viaje', withdrawal_return: 'Retiro devuelto por banco', withdrawal_fee_return: 'Cargo de retiro devuelto', cash_commission: 'Comisión de viaje en efectivo',
  commission: 'Comisión Yavoi! (IVA incluido)', isr: 'ISR retenido', vat: 'IVA retenido',
  card_tip: 'Propina electrónica', refund: 'Ajuste por reembolso', promotion_credit: 'Promoción financiada',
  opening: 'Saldo inicial conciliado', incentive: 'Incentivo', commission_payment: 'Comisión pagada',
  adjustment: 'Ajuste conciliado', withdrawal: 'Transferencia a tu cuenta', withdrawal_fee: 'Cargo por retiro diario',
};
export const withdrawalNames = { requested: 'Solicitado', processing: 'En transferencia', paid: 'Pagado', rejected: 'Cancelado' };
