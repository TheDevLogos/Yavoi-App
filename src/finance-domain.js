// Presentation math only. Postgres is the authority for amounts and reservations.
export function splitIncludedVat(gross) {
  const base = Math.round(Number(gross || 0) / 1.16);
  return { base, vat: Number(gross || 0) - base };
}
export function barPercent(value, values) {
  return Math.max(0, Math.min(100, Number(value || 0) / Math.max(1, ...values.map(Number)) * 100));
}
export const entryNames = {
  cash_commission: 'Comisión de viaje en efectivo',
  commission: 'Comisión Yavoi! (IVA incluido)', isr: 'ISR retenido', vat: 'IVA retenido',
  refund: 'Ajuste comercial', promotion_credit: 'Promoción financiada',
  opening: 'Saldo inicial conciliado', incentive: 'Incentivo', commission_payment: 'Comisión conciliada',
  adjustment: 'Ajuste conciliado del viaje',
};
