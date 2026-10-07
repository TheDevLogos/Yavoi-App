import './finance.css';
import { rpc, money, escapeHtml as e } from './client.js';
import { barPercent, entryNames, splitIncludedVat, validClabe, withdrawalNames } from './finance-domain.js';
const $ = s => document.querySelector(s);
const date = value => new Date(value).toLocaleString('es-MX', { timeZone: 'America/Chihuahua', dateStyle: 'medium', timeStyle: 'short' });
const chartMoney = cents => new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN', notation: 'compact', maximumFractionDigits: 0 }).format(Number(cents || 0) / 100);
const row = (label, value) => `<div class="receipt-row"><span>${e(label)}</span><strong>${money(value)}</strong></div>`;
export function financeTripDetail(t, driver = false) {
  const f = t.financial_breakdown;
  const terms = t.financial_terms;
  if (!terms?.version) return `<p class="hint">Este viaje conserva las condiciones históricas. Su saldo se concilia por separado.</p>`;
  const fareRows = () => {
    const rows = [
      ['Inicio del servicio', terms.base_cents], ['Distancia estimada', terms.distance_cents],
      ['Tiempo estimado', terms.time_cents], ['Ajuste a tarifa mínima', terms.minimum_cents],
      ['Zona de servicio', terms.zone_cents], ['Accesibilidad', terms.accessibility_cents],
      ['Recogida lejana', terms.pickup_cents], ['Demanda aplicable', terms.dynamic_cents],
      ['Peajes', terms.tolls_cents], ['Tiempo de espera', terms.waiting_cents],
    ].filter(([, value]) => Number(value || 0) !== 0).map(([label, value]) => row(label, value));
    return rows.join('') || row('Tarifa confirmada', t.fare_cents);
  };
  const adjustments = Number(t.manual_adjustments_cents || f?.post_acceptance_adjustments_cents || 0);
  const waiting = Number(t.waiting_charge?.charged_cents || 0);
  const finalTotal = Number(t.final_total_cents ?? t.total_cents ?? t.fare_cents ?? 0);
  if (!driver) {
    const fixed = t.status === 'cancelled' ? t.cancellation_fee_cents : t.fare_cents;
    return `<details class="finance-detail"><summary>Ver desglose del precio</summary><h3>Precio aceptado</h3>${fareRows()}${row('Tarifa fija aceptada', fixed)}${t.reward_discount_cents ? row('Descuento aplicado', -t.reward_discount_cents) : ''}${waiting ? row('Espera después de 2 min de cortesía', waiting) : ''}${adjustments ? row('Otros ajustes aceptados durante el viaje', adjustments) : ''}${t.tip_cents ? row('Propina voluntaria', t.tip_cents) : ''}${row('Total final', finalTotal)}<p class="hint">El precio queda fijo al aceptar. Al llegar el conductor, los primeros 2 minutos de espera no tienen costo; después se calcula por segundo con la tarifa de espera de tu servicio. Desvíos, cambio de ruta y recolecciones adicionales requieren una propuesta aceptada por ambas partes.</p></details>`;
  }
  if (!f?.version) return '';
  return `<details class="finance-detail"><summary>Ver desglose comercial del viaje</summary><h3>Precio acordado con el pasajero</h3>${fareRows()}${row('Tarifa contractual', t.status === 'cancelled' ? t.cancellation_fee_cents : t.fare_cents)}${waiting ? row('Espera automática acumulada', waiting) : ''}${adjustments ? row('Otros ajustes aceptados', adjustments) : ''}${row('Total del viaje', f.passenger_total_cents ?? finalTotal)}${f.promotion_pending_cents ? row('Promoción financiada por Yavoi! · por conciliar', f.promotion_pending_cents) : ''}${row('Propina', f.tip_cents)}${row('Comisión comercial Yavoi! (IVA incluido)', -f.commission_cents)}<p class="hint">Este resumen muestra el precio y la comisión comercial. No determina impuestos, retenciones ni el importe final de la liquidación; Operaciones conciliará el pago semanal.</p></details>`;
}
export function offerFinanceDetail(f) {
  if (!f) return '';
  return `<details class="finance-detail offer-finance"><summary>Comisión comercial estimada</summary>${row('Comisión Yavoi! (IVA incluido)', -f.commission_cents)}${f.promotion_pending_cents ? row('Promoción Yavoi! · pendiente de conciliación', f.promotion_pending_cents) : ''}<p class="hint">El importe es un resumen comercial. Impuestos, retenciones y liquidación se revisan por Operaciones; este desglose no es una determinación fiscal.</p></details>`;
}
export function walletMarkup(w) {
  const profile = w.profile || {};
  const days = w.days || [];
  const weekEnd = new Date(`${w.week_start}T12:00:00`); weekEnd.setDate(weekEnd.getDate() + 6);
  return `<section class="finance-week panel"><div class="row between"><button class="finance-week-nav" data-wallet-week="-7" aria-label="Semana anterior">‹</button><div><span class="eyebrow">RESUMEN DE INGRESOS</span><h2>${money(w.week_net_cents)}</h2><p>Semana del ${e(w.week_start)} al ${weekEnd.toLocaleDateString('es-MX')}</p></div><button class="finance-week-nav" data-wallet-week="7" aria-label="Semana siguiente">›</button></div><div class="finance-chart" role="group" aria-label="Ingresos por día de la semana">${days.map(d => `<button type="button" class="finance-day" data-wallet-day="${e(d.day)}" aria-label="${e(d.day)} · ${money(d.net_cents)} · ${d.trips} viajes"><strong title="${money(d.net_cents)}">${chartMoney(d.net_cents)}</strong><div class="finance-bar-track"><span style="height:${barPercent(d.net_cents, days.map(x => x.net_cents))}%"></span></div><span>${new Date(`${d.day}T12:00:00`).toLocaleDateString('es-MX', { weekday: 'short' })}</span><small>${d.trips} viajes</small></button>`).join('')}</div><p class="hint">Resumen contable de los viajes completados; no representa dinero disponible en una billetera ni un retiro inmediato.</p></section><section class="finance-balance panel section-gap"><span class="eyebrow">LIQUIDACIÓN</span><h2>Conciliación semanal</h2><p>Operaciones revisa comisiones, aportaciones y saldos cada lunes. Si existe un saldo a favor validado, registra la transferencia manual; no hay retiros desde la app.</p><div class="finance-stats"><div><small>Efectivo recibido directamente</small><strong>${money(w.week_cash_cents)}</strong></div><div><small>Cuenta para liquidación</small><strong>${profile.payout_verified_at ? 'Verificada' : 'Pendiente de revisión'}</strong></div></div><p class="hint">El efectivo del viaje lo recibes directamente del pasajero. Las comisiones o aportaciones que correspondan se concilian por separado; el historial semanal muestra cualquier transferencia a tu favor.</p></section><details class="panel finance-account section-gap"><summary>Datos bancarios para liquidación manual</summary><form id="finance-account"><label>Tipo de cuenta<select name="payout_kind"><option value="bank" ${profile.payout_kind !== 'mercado_pago' ? 'selected' : ''}>Banco · CLABE</option><option value="mercado_pago" ${profile.payout_kind === 'mercado_pago' ? 'selected' : ''}>Mercado Pago · correo</option></select></label><label>Titular<input name="payout_holder" value="${e(profile.payout_holder)}" maxlength="160" required autocomplete="name"></label><label>CLABE de 18 dígitos o correo<input name="payout_destination" value="${e(profile.payout_destination)}" maxlength="160" required autocomplete="off"></label><button class="btn" type="submit">Guardar datos bancarios</button></form><p class="hint">${profile.payout_verified_at ? 'Operaciones verificó esta cuenta.' : 'Operaciones debe verificar que la cuenta pertenezca a su titular antes de liquidar.'} La app no guarda contraseñas ni datos de tarjeta.</p></details><details class="panel section-gap finance-detail"><summary>Cómo revisar tus ingresos</summary><p>La tarifa del viaje y la propina se muestran en el detalle de cada servicio. El efectivo se entrega directamente al conductor. Los importes pendientes de liquidación se concilian por Operaciones.</p><a class="btn secondary" href="#trips">Consultar mis viajes</a></details>`;
}
export function bindWallet(w, { redraw, openModal, notify, refresh }) {
  document.querySelectorAll('[data-wallet-day]').forEach(b => b.onclick = () => { const day = w.days.find(d => d.day === b.dataset.walletDay); openModal('Ingresos del día', row(day.day, day.net_cents) + `<p>${day.trips} viajes completados.</p>`); });
  document.querySelectorAll('[data-wallet-week]').forEach(b => b.onclick = async () => {
    b.disabled = true;
    try {
      const d = new Date(`${w.week_start}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + Number(b.dataset.walletWeek));
      redraw(await rpc('finance_wallet', { week_start: d.toISOString().slice(0, 10) }));
    } catch (err) { notify(err.message); b.disabled = false; }
  });
  $('#finance-account').onsubmit = async ev => {
    ev.preventDefault(); const form = ev.currentTarget; const button = form.querySelector('button');
    const values = Object.fromEntries(new FormData(form));
    if (values.payout_kind === 'bank' && !validClabe(values.payout_destination)) return notify('Revisa los 18 dígitos y el dígito verificador de tu CLABE.');
    button.disabled = true;
    try { await rpc('finance_profile', { ...values, weekly_auto: false }); await refresh(); notify('Datos guardados. Operaciones verificará la titularidad.'); }
    catch (err) { notify(err.message); button.disabled = false; }
  };
}
export async function mountFinanceOperations({ notify, openModal }) {
  const host = document.createElement('section'); host.className = 'panel section-gap finance-operations'; host.id = 'finance-operations';
  $('#page-content')?.append(host);
  let data, manualSettlements = [];
  async function render() {
    try { data = await rpc('finance_operations'); manualSettlements = await rpc('finance_manual_settlements'); }
    catch (err) { host.textContent = `No pudimos cargar la conciliación financiera: ${err.message}`; return; }
    const s = data.settings;
    host.innerHTML = `<span class="eyebrow">CONCILIACIÓN Y FISCALIDAD</span><h2>Conciliación semanal</h2><div class="finance-stats"><div><small>ISR registrado del mes</small><strong>${money(data.tax_summary.isr_cents)}</strong></div><div><small>IVA registrado del mes</small><strong>${money(data.tax_summary.vat_cents)}</strong></div><div><small>Aportación estatal registrada</small><strong>${money(data.state_summary)}</strong></div></div><p class="hint">La tarjeta y los retiros iniciados por conductores están desactivados. Operaciones revisa comisiones, aportaciones y saldos los lunes; sólo transfiere saldos a favor ya conciliados y registra aquí su referencia bancaria. Estos registros no sustituyen el entero de impuestos ni la emisión de CFDI; valida el tratamiento fiscal con Contabilidad.</p><details class="finance-detail"><summary>Reglas comerciales</summary><form id="finance-settings-form"><label class="check"><input name="dynamic_enabled" type="checkbox" ${s.dynamic_enabled ? 'checked' : ''}>Activar demanda dinámica visible en cotización</label><label>Máximo de demanda (multiplicador)<input name="dynamic_max" type="number" min="1" max="1.5" step="0.05" value="${s.dynamic_max_bps / 10000}" required></label><fieldset><legend>Reducción de comisión por nivel (puntos porcentuales)</legend>${['Activo','Destacado','Élite','Referente'].map(level => `<label>${level}<input data-finance-level="${level}" type="number" min="0" max="50" step="0.01" value="${Number(s.level_discounts[level] || 0) / 100}"></label>`).join('')}</fieldset><label>Motivo<textarea name="note" minlength="5" required></textarea></label><button class="btn" type="submit">Guardar reglas</button></form><p class="hint">El método de pago del piloto es efectivo. El cálculo fiscal sigue pendiente de validación y no debe tratarse como determinación fiscal.</p></details><section class="finance-detail"><h3>Conductores y conciliación de saldo</h3><div class="finance-driver-list">${data.drivers.map(d => `<article><strong>${e(d.name)}</strong><div class="finance-stats"><span>Importe contable por liquidar ${money(d.wallet.available_cents)}</span><span>Adeudo contable ${money(d.wallet.debt_cents)}</span></div><p class="hint">${d.fiscal.rfc_provided ? `RFC registrado ${e(d.fiscal.rfc)}` : 'RFC pendiente de validación'} · ${d.fiscal.payout_verified_at ? 'Cuenta verificada' : 'Cuenta pendiente de verificación'}</p>${d.fiscal.payout_destination ? `<small>${e(d.fiscal.payout_holder)} · ${e(d.fiscal.payout_destination)}</small>` : ''}<div class="row wrap"><button class="btn secondary" data-finance-driver="${d.id}">Validar fiscal y cuenta</button><button class="btn secondary" data-finance-funding="${d.id}">Registrar ajuste conciliado</button><button class="btn" data-finance-manual-settlement="${d.id}" ${d.fiscal.payout_verified_at && Number(d.wallet.available_cents) >= 100 ? '' : 'disabled'}>Registrar transferencia conciliada</button></div><button class="link" data-finance-export-driver="${d.id}">Descargar movimientos del mes</button></article>`).join('')}</div></section><details class="finance-detail"><summary>Historial de pagos manuales</summary><div class="finance-payout-list">${manualSettlements.map(x => `<article><strong>${e(x.driver_name)} · Semana ${e(x.week_start)}</strong>${row('Importe transferido', x.amount_cents)}<small>${date(x.settled_at)} · ${e(x.destination.holder || '')} · ${e(x.destination.destination || '')} · Ref. ${e(x.transfer_reference)}</small><small>${e(x.note)}</small></article>`).join('') || '<p>Aún no hay pagos semanales registrados.</p>'}</div></details><details class="finance-detail"><summary>Solicitudes antiguas pendientes</summary><div class="finance-payout-list">${data.withdrawals.filter(w => ['requested','processing'].includes(w.status)).map(w => `<article><strong>${e(w.driver_name)} · ${withdrawalNames[w.status]}</strong>${row('Importe reservado', w.net_cents)}<small>${e(w.destination.destination)} · ${e(w.destination.holder)}</small><button class="btn secondary" data-finance-review="${w.id}">Conciliar solicitud existente</button></article>`).join('') || '<p>No hay solicitudes antiguas pendientes.</p>'}</div></details>`;
    $('#finance-settings-form').onsubmit = ev => submit(ev, async form => {
      const levels = {}; form.querySelectorAll('[data-finance-level]').forEach(x => levels[x.dataset.financeLevel] = Math.round(Number(x.value) * 100));
      await rpc('finance_settings', { payouts_enabled: false, dynamic_enabled: form.elements.dynamic_enabled.checked, dynamic_max_bps: Math.round(Number(form.elements.dynamic_max.value) * 10000), level_discounts: levels, note: form.elements.note.value });
    });
    host.querySelectorAll('[data-finance-export-driver]').forEach(b => b.onclick = () => exportStatement({ driver_id: b.dataset.financeExportDriver, month: data.month }).catch(err => notify(err.message)));
    host.querySelectorAll('[data-finance-driver]').forEach(b => b.onclick = () => fiscalDialog(data.drivers.find(d => d.id === b.dataset.financeDriver)));
    host.querySelectorAll('[data-finance-funding]').forEach(b => b.onclick = () => fundingDialog(data.drivers.find(d => d.id === b.dataset.financeFunding)));
    host.querySelectorAll('[data-finance-review]').forEach(b => b.onclick = () => reviewDialog(data.withdrawals.find(w => w.id === b.dataset.financeReview)));
    host.querySelectorAll('[data-finance-manual-settlement]').forEach(b => b.onclick = () => manualSettlementDialog(data.drivers.find(d => d.id === b.dataset.financeManualSettlement)));
  }
  async function submit(ev, callback, close = false) {
    ev.preventDefault(); const form = ev.currentTarget; const b = form.querySelector('button[type=submit]'); b.disabled = true;
    try { await callback(form); if (close) $('#modal').close(); await render(); notify('Cambio conciliado y registrado en auditoría.'); }
    catch (err) { notify(err.message); b.disabled = false; }
  }
  function fiscalDialog(d) {
    const f = d.fiscal;
    openModal(`Datos fiscales · ${d.name}`, `<form id="finance-fiscal-form"><label>Tipo<select name="entity"><option value="individual" ${f.entity !== 'company' ? 'selected' : ''}>Persona física · transporte 2.1%</option><option value="company" ${f.entity === 'company' ? 'selected' : ''}>Persona moral · 2026 2.5%</option></select></label><label>RFC propio (vacío si no proporcionado)<input name="rfc" maxlength="13" value="${e(f.rfc)}"></label><p class="hint">Confirma los datos contra la información fiscal del titular. Un RFC genérico no acredita al conductor.</p>${f.payout_destination ? `<p>Cuenta: ${e(f.payout_destination)}<br>Titular: ${e(f.payout_holder)}</p><label class="check"><input name="verify_destination" type="checkbox">He verificado la titularidad de esta cuenta</label>` : '<p>El conductor aún no registró su cuenta.</p>'}<label>Nota de validación<textarea name="note" minlength="5" required></textarea></label><button class="btn" type="submit">Guardar validación</button></form>`);
    $('#finance-fiscal-form').onsubmit = ev => submit(ev, form => rpc('finance_verify_profile', { driver_id: d.id, entity: form.elements.entity.value, rfc: form.elements.rfc.value, verify_destination: Boolean(form.elements.verify_destination?.checked), note: form.elements.note.value }), true);
  }
  function fundingDialog(d) {
    const key = crypto.randomUUID();
    openModal(`Conciliar billetera · ${d.name}`, `<form id="finance-funding-form"><label>Concepto<select name="kind"><option value="commission_payment">Comisión pagada por conductor</option><option value="opening">Saldo previo confirmado pendiente de transferir</option><option value="promotion">Financiación de promoción por viaje</option><option value="incentive">Incentivo bruto de transporte (IVA incluido)</option><option value="adjustment">Ajuste a favor del conductor</option></select></label><label>Importe (MXN)<input name="amount" type="number" min="0.01" max="1000000" step="0.01" required></label><label>ID de viaje <span id="finance-trip-required">(obligatorio para promoción y ajuste)</span><input name="trip_id" placeholder="UUID del viaje"></label><label>Referencia bancaria / documento de conciliación<input name="reference" minlength="5" maxlength="160" required></label><label>Motivo y soporte documental<textarea name="note" minlength="5" required></textarea></label><p class="hint">Un ajuste no cambia el precio ni vuelve a cobrar al pasajero: acredita una corrección respaldada, ligada a un viaje finalizado y visible en la billetera. Una promoción abonada en billetera no puede transferirse otra vez desde el módulo anterior.</p><button class="btn" type="submit">Conciliar fondos</button></form>`);
    $('#finance-funding-form').onsubmit = ev => submit(ev, form => {
      const values = Object.fromEntries(new FormData(form));
      if (['promotion', 'adjustment'].includes(values.kind) && !values.trip_id?.trim()) throw new Error('Selecciona el viaje al que corresponde este movimiento.');
      return rpc('finance_funding', { driver_id: d.id, request_key: key, ...values, amount_cents: Math.round(Number(form.elements.amount.value) * 100) });
    }, true);
  }
  function manualSettlementDialog(d) {
    if (!d?.fiscal?.payout_verified_at || !d.fiscal.payout_destination) return notify('Verifica primero la cuenta bancaria del conductor.');
    const monday = new Date(); monday.setHours(12,0,0,0); monday.setDate(monday.getDate()-((monday.getDay()+6)%7));
    const weekStart = `${monday.getFullYear()}-${String(monday.getMonth()+1).padStart(2,'0')}-${String(monday.getDate()).padStart(2,'0')}`;
    openModal(`Registrar transferencia · ${d.name}`, `<form id="finance-manual-settlement-form"><p>Úsalo sólo si Operaciones ya transfirió al conductor un saldo a favor conciliado. El registro descontará el importe del saldo contable.</p><p><strong>${e(d.fiscal.payout_holder)}</strong><br>${e(d.fiscal.payout_destination)}</p><label>Semana de los ingresos<input name="week_start" type="date" value="${weekStart}" required></label><label>Importe transferido (MXN)<input name="amount" type="number" min="1" max="${Number(d.wallet.available_cents)/100}" step="0.01" value="${Number(d.wallet.available_cents)/100}" required inputmode="decimal"></label><label>Referencia bancaria<input name="transfer_reference" minlength="5" maxlength="160" required></label><label>Nota de conciliación<textarea name="note" minlength="5" maxlength="1000" required></textarea></label><button class="btn wide" type="submit">Registrar transferencia confirmada</button></form>`);
    $('#finance-manual-settlement-form').onsubmit = ev => submit(ev, form => rpc('finance_manual_settlement', { driver_id:d.id, week_start:form.elements.week_start.value, amount_cents:Math.round(Number(form.elements.amount.value)*100), transfer_reference:form.elements.transfer_reference.value, note:form.elements.note.value }), true);
  }
  function reviewDialog(w) {
    openModal(`Conciliar retiro · ${w.driver_name}`, `<form id="finance-review-form">${row('Transferir a la cuenta registrada', w.net_cents)}<p>${e(w.destination.destination)} · ${e(w.destination.holder)}</p><label>Estado<select name="status"><option value="processing">En proceso de transferencia</option><option value="paid">Transferencia confirmada</option><option value="rejected">Cancelar solicitud y liberar saldo</option></select></label><label>Referencia de la transferencia confirmada<input name="reference" maxlength="160"></label><label>Nota de conciliación<textarea name="note" minlength="5" required></textarea></label><p class="hint">Marca pagado únicamente al confirmar que los fondos salieron a la cuenta registrada.</p><button class="btn" type="submit">Guardar conciliación</button></form>`);
    $('#finance-review-form').onsubmit = ev => submit(ev, form => rpc('finance_review_withdrawal', { withdrawal_id: w.id, ...Object.fromEntries(new FormData(form)) }), true);
  }
  await render();
}

async function exportStatement(payload) {
  const data = await rpc('finance_statement', payload);
  const csvCell = value => { const raw = String(value ?? ''); const safe = /^[=+@-]/.test(raw) && !/^-?\d+(?:\.\d+)?$/.test(raw) ? "'" + raw : raw; return '"' + safe.replaceAll('"', '""') + '"'; };
  const rows = [['Fecha','Concepto','Importe MXN','Viaje','Referencia','Motivo'], ...data.entries.map(x => [date(x.date),entryNames[x.kind] || x.kind,(Number(x.amount_cents) / 100).toFixed(2),x.trip_id,x.reference,x.note])];
  const blob = new Blob(['\uFEFF' + rows.map(r => r.map(csvCell).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob); const a = document.createElement('a'); a.href = url; a.download = `yavoi-movimientos-${data.month}.csv`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
