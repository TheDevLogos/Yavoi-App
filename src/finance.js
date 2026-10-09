import './finance.css';
import { rpc, money, escapeHtml as e } from './client.js';
import { barPercent } from './finance-domain.js';

const $ = selector => document.querySelector(selector);
const chartMoney = cents => new Intl.NumberFormat('es-MX', {
  style: 'currency', currency: 'MXN', notation: 'compact', maximumFractionDigits: 0,
}).format(Number(cents || 0) / 100);
const row = (label, value) => `<div class="receipt-row"><span>${e(label)}</span><strong>${money(value)}</strong></div>`;

export function financeTripDetail(trip, driver = false) {
  const breakdown = trip.financial_breakdown || {};
  const terms = trip.financial_terms || {};
  if (!terms.version) return '<p class="hint">Este viaje conserva su desglose histórico.</p>';
  const fareRows = [
    ['Inicio del servicio', terms.base_cents], ['Distancia estimada', terms.distance_cents],
    ['Tiempo estimado', terms.time_cents], ['Ajuste a tarifa mínima', terms.minimum_cents],
    ['Zona de servicio', terms.zone_cents], ['Accesibilidad', terms.accessibility_cents],
    ['Recogida lejana', terms.pickup_cents], ['Demanda aplicable', terms.dynamic_cents],
    ['Peajes', terms.tolls_cents], ['Tiempo de espera', terms.waiting_cents],
  ].filter(([, value]) => Number(value || 0) !== 0).map(([label, value]) => row(label, value)).join('') || row('Tarifa confirmada', trip.fare_cents);
  const adjustments = Number(trip.manual_adjustments_cents || breakdown.post_acceptance_adjustments_cents || 0);
  const waiting = Number(trip.waiting_charge?.charged_cents || 0);
  const total = Number(trip.final_total_cents ?? trip.total_cents ?? trip.fare_cents ?? 0);

  if (!driver) {
    const fixed = trip.status === 'cancelled' ? trip.cancellation_fee_cents : trip.fare_cents;
    return `<details class="finance-detail"><summary>Ver desglose del precio</summary><h3>Precio aceptado</h3>${fareRows}${row('Tarifa fija aceptada', fixed)}${trip.reward_discount_cents ? row('Descuento aplicado', -trip.reward_discount_cents) : ''}${waiting ? row('Espera después de 2 min de cortesía', waiting) : ''}${adjustments ? row('Otros ajustes aceptados durante el viaje', adjustments) : ''}${trip.tip_cents ? row('Propina voluntaria', trip.tip_cents) : ''}${row('Total final', total)}<p class="hint">El importe queda fijo al aceptar. Los ajustes por espera, desvío, cambio de ruta o recolección adicional requieren aviso y aceptación durante el viaje.</p></details>`;
  }

  return `<details class="finance-detail"><summary>Ver desglose comercial del viaje</summary><h3>Servicio realizado</h3>${fareRows}${row('Tarifa contractual', trip.status === 'cancelled' ? trip.cancellation_fee_cents : trip.fare_cents)}${waiting ? row('Espera automática acumulada', waiting) : ''}${adjustments ? row('Otros ajustes aceptados', adjustments) : ''}${row('Total cobrado al pasajero', breakdown.passenger_total_cents ?? total)}${trip.tip_cents ? row('Propina en efectivo', trip.tip_cents) : ''}${row('Comisión Yavoi! aplicable', breakdown.commission_cents || trip.commission_cents)}<p class="hint">Es un desglose comercial del servicio. Operaciones consolida las comisiones, impuestos y la cuota semanal; Yavoi! Drive no administra saldos, cuentas ni transferencias.</p></details>`;
}

export function offerFinanceDetail(finance) {
  if (!finance) return '';
  return `<details class="finance-detail offer-finance"><summary>Detalle comercial estimado</summary>${row('Comisión Yavoi! aplicable', finance.commission_cents)}${finance.promotion_pending_cents ? row('Descuento financiado por Yavoi!', finance.promotion_pending_cents) : ''}<p class="hint">El corte semanal de Operaciones confirmará la comisión y las deducciones que correspondan.</p></details>`;
}

export function walletMarkup(summary) {
  const days = summary.days || [];
  const weekEnd = new Date(`${summary.week_start}T12:00:00`);
  weekEnd.setDate(weekEnd.getDate() + 6);
  return `<section class="finance-week panel"><div class="row between"><button class="finance-week-nav" data-week-offset="-7" aria-label="Semana anterior">‹</button><div><span class="eyebrow">CORTE SEMANAL</span><h2>${money(summary.week_net_cents)}</h2><p>Servicios registrados del ${e(summary.week_start)} al ${weekEnd.toLocaleDateString('es-MX')}</p></div><button class="finance-week-nav" data-week-offset="7" aria-label="Semana siguiente">›</button></div><div class="finance-chart" role="group" aria-label="Servicios registrados por día">${days.map(day => `<button type="button" class="finance-day" data-week-day="${e(day.day)}" aria-label="${e(day.day)} · ${money(day.net_cents)} · ${day.trips} viajes"><strong>${chartMoney(day.net_cents)}</strong><div class="finance-bar-track"><span style="height:${barPercent(day.net_cents, days.map(item => item.net_cents))}%"></span></div><span>${new Date(`${day.day}T12:00:00`).toLocaleDateString('es-MX', { weekday: 'short' })}</span><small>${day.trips} viajes</small></button>`).join('')}</div><p class="hint">Resumen de operación. No representa saldo disponible, billetera, retiro ni transferencia.</p></section><section class="finance-balance panel section-gap"><span class="eyebrow">CUOTA Y COMISIONES</span><h2>Revisión con Operaciones</h2><p>Al cierre semanal, Operaciones te compartirá la comisión y cuota aplicable por tus servicios. La cobertura de la cuota es requisito para mantener activo el permiso de conducir.</p><div class="finance-stats"><div><small>Importe de servicios de la semana</small><strong>${money(summary.week_cash_cents)}</strong></div><div><small>Pago al pasajero</small><strong>Efectivo directo</strong></div></div><p class="hint">Yavoi! Drive no conserva cuentas bancarias, CLABE, saldo disponible ni herramientas para pagos o retiros.</p></section><details class="panel section-gap finance-detail"><summary>Cómo se forma el corte</summary><p>Consulta la tarifa, los ajustes aceptados, descuentos y comisión de cada viaje desde Mis viajes. Operaciones consolida estos datos y conserva la conciliación administrativa.</p><a class="btn secondary" href="#trips">Consultar mis viajes</a></details>`;
}

export function bindWallet(summary, { redraw, openModal, notify }) {
  document.querySelectorAll('[data-week-day]').forEach(button => {
    button.onclick = () => {
      const day = (summary.days || []).find(item => item.day === button.dataset.weekDay);
      if (day) openModal('Servicios del día', `${row(day.day, day.net_cents)}<p>${day.trips} viajes completados.</p>`);
    };
  });
  document.querySelectorAll('[data-week-offset]').forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        const date = new Date(`${summary.week_start}T12:00:00Z`);
        date.setUTCDate(date.getUTCDate() + Number(button.dataset.weekOffset));
        redraw(await rpc('finance_wallet', { week_start: date.toISOString().slice(0, 10) }));
      } catch (error) {
        notify(error.message);
        button.disabled = false;
      }
    };
  });
}

export async function mountFinanceOperations({ notify, openModal }) {
  const host = document.createElement('section');
  host.className = 'panel section-gap finance-operations';
  host.id = 'finance-operations';
  $('#page-content')?.append(host);
  let data;

  async function render() {
    try { data = await rpc('finance_operations'); }
    catch (error) { host.textContent = `No pudimos cargar la conciliación: ${error.message}`; return; }
    const settings = data.settings || {};
    host.innerHTML = `<span class="eyebrow">CONCILIACIÓN Y FISCALIDAD</span><h2>Corte semanal interno</h2><div class="finance-stats"><div><small>ISR registrado del mes</small><strong>${money(data.tax_summary?.isr_cents)}</strong></div><div><small>IVA registrado del mes</small><strong>${money(data.tax_summary?.vat_cents)}</strong></div><div><small>Aportación estatal registrada</small><strong>${money(data.state_summary)}</strong></div></div><p class="hint">Este módulo calcula y conserva la conciliación administrativa. No procesa pagos desde la aplicación.</p><details class="finance-detail"><summary>Reglas comerciales</summary><form id="finance-settings-form"><label class="check"><input name="dynamic_enabled" type="checkbox" ${settings.dynamic_enabled ? 'checked' : ''}>Activar demanda dinámica visible en cotización</label><label>Máximo de demanda (multiplicador)<input name="dynamic_max" type="number" min="1" max="1.5" step="0.05" value="${settings.dynamic_max_bps / 10000}" required></label><fieldset><legend>Reducción de comisión por nivel (puntos porcentuales)</legend>${['Activo', 'Destacado', 'Élite', 'Referente'].map(level => `<label>${level}<input data-finance-level="${level}" type="number" min="0" max="50" step="0.01" value="${Number(settings.level_discounts?.[level] || 0) / 100}"></label>`).join('')}</fieldset><label>Motivo<textarea name="note" minlength="5" required></textarea></label><button class="btn" type="submit">Guardar reglas</button></form></details><section class="finance-detail"><h3>Conductores y cuota semanal</h3><div class="finance-driver-list">${(data.drivers || []).map(driver => `<article><strong>${e(driver.name)}</strong><div class="finance-stats"><span>Servicios de la semana ${money(driver.wallet?.week_cash_cents)}</span><span>Comisión o cuota pendiente ${money(driver.wallet?.debt_cents)}</span></div><p class="hint">${driver.fiscal?.rfc_provided ? `RFC registrado ${e(driver.fiscal.rfc)}` : 'RFC pendiente de validación'} · El detalle queda en la conciliación interna de Operaciones.</p><div class="row wrap"><button class="btn secondary" data-finance-driver="${driver.id}">Validar datos fiscales</button><button class="btn secondary" data-finance-adjustment="${driver.id}">Registrar ajuste administrativo</button></div><button class="link" data-finance-export-driver="${driver.id}">Descargar corte del mes</button></article>`).join('') || '<p>No hay conductores para conciliar.</p>'}</div></section>`;
    $('#finance-settings-form').onsubmit = event => submit(event, async form => {
      const levels = {};
      form.querySelectorAll('[data-finance-level]').forEach(input => { levels[input.dataset.financeLevel] = Math.round(Number(input.value) * 100); });
      await rpc('finance_settings', { payouts_enabled: false, dynamic_enabled: form.elements.dynamic_enabled.checked, dynamic_max_bps: Math.round(Number(form.elements.dynamic_max.value) * 10000), level_discounts: levels, note: form.elements.note.value });
    });
    host.querySelectorAll('[data-finance-export-driver]').forEach(button => button.onclick = () => exportStatement({ driver_id: button.dataset.financeExportDriver, month: data.month }).catch(error => notify(error.message)));
    host.querySelectorAll('[data-finance-driver]').forEach(button => button.onclick = () => fiscalDialog((data.drivers || []).find(driver => driver.id === button.dataset.financeDriver)));
    host.querySelectorAll('[data-finance-adjustment]').forEach(button => button.onclick = () => adjustmentDialog((data.drivers || []).find(driver => driver.id === button.dataset.financeAdjustment)));
  }
  async function submit(event, callback, close = false) {
    event.preventDefault();
    const form = event.currentTarget; const button = form.querySelector('button[type=submit]'); button.disabled = true;
    try { await callback(form); if (close) $('#modal').close(); await render(); notify('Cambio administrativo registrado en auditoría.'); }
    catch (error) { notify(error.message); button.disabled = false; }
  }
  function fiscalDialog(driver) {
    const fiscal = driver?.fiscal || {};
    openModal(`Datos fiscales · ${driver.name}`, `<form id="finance-fiscal-form"><label>Tipo<select name="entity"><option value="individual" ${fiscal.entity !== 'company' ? 'selected' : ''}>Persona física · transporte 2.1%</option><option value="company" ${fiscal.entity === 'company' ? 'selected' : ''}>Persona moral · 2026 2.5%</option></select></label><label>RFC propio (vacío si no proporcionado)<input name="rfc" maxlength="13" value="${e(fiscal.rfc)}"></label><p class="hint">Valida los datos contra la documentación fiscal del conductor. No se solicitan ni almacenan datos bancarios.</p><label>Nota de validación<textarea name="note" minlength="5" required></textarea></label><button class="btn" type="submit">Guardar validación</button></form>`);
    $('#finance-fiscal-form').onsubmit = event => submit(event, form => rpc('finance_verify_profile', { driver_id: driver.id, entity: form.elements.entity.value, rfc: form.elements.rfc.value, verify_destination: false, note: form.elements.note.value }), true);
  }
  function adjustmentDialog(driver) {
    const requestKey = crypto.randomUUID();
    openModal(`Ajuste administrativo · ${driver.name}`, `<form id="finance-adjustment-form"><label>Concepto<select name="kind"><option value="commission_payment">Cuota o comisión confirmada</option><option value="promotion">Promoción aplicada al viaje</option><option value="incentive">Incentivo registrado</option><option value="adjustment">Corrección administrativa</option></select></label><label>Importe (MXN)<input name="amount" type="number" min="0.01" max="1000000" step="0.01" required></label><label>ID de viaje (si aplica)<input name="trip_id" placeholder="UUID del viaje"></label><label>Referencia interna o documento<input name="reference" minlength="5" maxlength="160" required></label><label>Motivo y soporte<textarea name="note" minlength="5" required></textarea></label><p class="hint">Este registro sólo actualiza la conciliación interna. No inicia ni registra pagos, transferencias o retiros.</p><button class="btn" type="submit">Registrar ajuste</button></form>`);
    $('#finance-adjustment-form').onsubmit = event => submit(event, form => {
      const values = Object.fromEntries(new FormData(form));
      return rpc('finance_funding', { driver_id: driver.id, request_key: requestKey, ...values, amount_cents: Math.round(Number(form.elements.amount.value) * 100) });
    }, true);
  }
  async function exportStatement(payload) {
    const report = await rpc('finance_driver_statement', payload);
    const rows = ['Fecha,Concepto,Importe,Viaje,Referencia', ...(report.entries || []).map(entry => [new Date(entry.date).toLocaleString('es-MX'), entry.kind, Number(entry.amount_cents || 0) / 100, entry.trip_id || '', entry.reference || ''].map(value => `"${String(value).replaceAll('"', '""')}"`).join(','))];
    const url = URL.createObjectURL(new Blob([rows.join('\n')], { type: 'text/csv;charset=utf-8' }));
    const link = document.createElement('a'); link.href = url; link.download = `corte-yavoi-${report.month}.csv`; link.click(); URL.revokeObjectURL(url);
  }
  await render();
}
