import './finance.css';
import { rpc, money, escapeHtml as e } from './client.js';
import { barPercent } from './finance-domain.js';
import { taxRows } from './finance-report.js';

const $ = selector => document.querySelector(selector);
const chartMoney = cents => new Intl.NumberFormat('es-MX', {
  style: 'currency', currency: 'MXN', notation: 'compact', maximumFractionDigits: 0,
}).format(Number(cents || 0) / 100);
const row = (label, value) => `<div class="receipt-row"><span>${e(label)}</span><strong>${money(value)}</strong></div>`;
const localToday = () => new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Chihuahua', year: 'numeric', month: '2-digit', day: '2-digit',
}).format(new Date());
const periodLabel = report => report?.meta?.starts_on && report?.meta?.ends_on
  ? `${report.meta.starts_on} a ${report.meta.ends_on}` : 'Periodo no determinado';
const dateLabel = value => value ? new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T12:00:00` : value).toLocaleDateString('es-MX', { timeZone: 'America/Chihuahua' }) : 'Sin fecha límite registrada';

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
  document.querySelector('#page-content')?.append(host);
  let data = {};
  let liquidations = {};
  let destination = {};
  let compliance = {};
  let fiscalReport = {};

  async function render() {
    host.innerHTML = '<p role="status">Revisando pendientes de Operaciones…</p>';
    try {
      [data, liquidations, destination, compliance, fiscalReport] = await Promise.all([
        rpc('finance_operations'),
        rpc('weekly_commission_dashboard', { period: 'month', anchor: localToday() }),
        rpc('weekly_transfer_destination'),
        rpc('transport_compliance', { action: 'read' }).catch(() => ({})),
        rpc('finance_report', { period: 'month', anchor: localToday() }).catch(() => ({})),
      ]);
    } catch (error) {
      host.innerHTML = `<p>No pudimos cargar los pendientes financieros: ${e(error.message)}</p><a class="btn secondary" href="#payments">Abrir Pagos y cuotas</a>`;
      return;
    }
    const drivers = data.drivers || [];
    const cuts = liquidations.open_settlements || (liquidations.settlements || []).filter(cut => ['pending', 'submitted', 'overdue'].includes(cut.status));
    const fiscalPending = drivers.filter(driver => !driver.fiscal?.verified_at);
    const receiptPending = cuts.filter(cut => cut.status === 'submitted');
    const overdue = cuts.filter(cut => cut.status === 'overdue');
    const actionable = [];
    const statePolicy = data.state_contribution_policy || {};
    if (compliance.company_ready === false) actionable.push({
      title: 'Expediente regulatorio de Yavoi! incompleto',
      detail: 'Revisa autorización, convenio y póliza empresarial en Cumplimiento antes de activar controles obligatorios.',
      period: 'Vigencia regulatoria', deadline: 'Antes de habilitar el modo obligatorio.', href: '#audit', action: 'Revisar cumplimiento', tone: 'pending',
    });
    const warnings = [];
    if (!destination.configured) warnings.push('Falta registrar el banco y la CLABE de Yavoi!. No se generan vencimientos ni suspensiones por cortes nuevos.');
    if (fiscalPending.length) warnings.push(`${fiscalPending.length} conductor(es) necesitan validación de tipo fiscal y RFC antes de aceptar la liquidación vigente.`);
    if (receiptPending.length) warnings.push(`${receiptPending.length} comprobante(s) semanal(es) esperan conciliación de Operaciones.`);
    if (overdue.length) warnings.push(`${overdue.length} liquidación(es) vencidas requieren revisión y aviso en Bandeja de Entrada.`);
    if (!statePolicy.enabled) {
      warnings.push('La referencia estatal de 1.5% sigue desactivada hasta registrar y validar autorización y convenio.');
      actionable.push({ title: 'Aportación estatal pendiente de autorización', detail: 'No se suma a los cortes mientras falten autorización y convenio vigentes.', period: 'Vigencia estatal', deadline: 'Antes de activar el concepto.', href: '#payments', action: 'Revisar política estatal', tone: 'pending' });
    }
    for (const driver of fiscalPending) actionable.push({ title: `Perfil fiscal pendiente · ${driver.name || 'Conductor'}`, detail: 'Validar tipo fiscal y RFC antes de aplicar el desglose semanal.', period: 'Próximo corte elegible', deadline: 'Antes de emitir el primer corte.', href: '#finance', action: 'Validar perfil', tone: 'pending' });
    const monthPeriod = periodLabel(fiscalReport);
    const summary = fiscalReport.summary || {};
    const difference = Number(summary.difference_cents || 0);
    if (Number(summary.pending_trips || 0) > 0 || difference !== 0) {
      actionable.push({
        title: 'Diferencias de cobro por conciliar',
        detail: `${Number(summary.pending_trips || 0)} viaje(s) en revisión · diferencia neta ${money(difference)}.`,
        period: monthPeriod, deadline: 'Atención operativa; sin vencimiento automático.', href: '#finance', action: 'Abrir conciliación', tone: 'pending',
      });
    }
    for (const cut of overdue) actionable.push({
      title: `Liquidación vencida · ${cut.driver_name || 'Conductor'}`,
      detail: `${money(cut.settlement_due_cents ?? cut.commission_due_cents)} pendiente · semana ${cut.week_start}.`,
      period: cut.week_start, deadline: dateLabel(cut.due_at), href: '#payments', action: 'Revisar corte', tone: 'overdue',
    });
    for (const cut of receiptPending) actionable.push({
      title: `Comprobante por conciliar · ${cut.driver_name || 'Conductor'}`,
      detail: `${money(cut.settlement_due_cents ?? cut.commission_due_cents)} recibido por confirmar · semana ${cut.week_start}.`,
      period: cut.week_start, deadline: dateLabel(cut.due_at), href: '#payments', action: 'Conciliar comprobante', tone: 'pending',
    });
    for (const driver of compliance.drivers || []) {
      const missing = Array.isArray(driver.missing) ? driver.missing : [];
      if (missing.length) actionable.push({
        title: `Expediente incompleto · ${driver.full_name || 'Conductor'}`,
        detail: `Falta revisar: ${missing.join(', ')}.`, period: 'Sin periodo fiscal',
        deadline: 'Antes de autorizar o renovar el permiso.', href: '#fleet', action: 'Revisar expediente', tone: 'pending',
      });
    }
    const fiscalRows = fiscalReport.summary ? taxRows(fiscalReport) : [];
    const historicalDriverTaxRows = fiscalRows.filter(tax => ['isr_withheld', 'vat_withheld'].includes(tax.kind) && Number(tax.due || 0) > 0);
    if (historicalDriverTaxRows.length) actionable.push({
      title: 'Conciliar registros fiscales históricos de conductores',
      detail: `${historicalDriverTaxRows.map(tax => tax.label).join(' e ')} requieren comprobación; no se tratan como retención vigente ni pago pendiente al SAT.`,
      period: monthPeriod, deadline: 'Sin fecha límite registrada; confirmar con asesor fiscal.', href: '#finance', action: 'Revisar registros históricos', tone: 'pending',
    });
    for (const tax of fiscalRows) {
      const isHistoricalDriverReference = ['isr_withheld', 'vat_withheld'].includes(tax.kind);
      const isCompanyEstimate = ['company_vat', 'company_isr'].includes(tax.kind) && !tax.validated;
      if (isHistoricalDriverReference || (!tax.validated && !isCompanyEstimate)) continue;
      const amount = Number(tax.balance ?? tax.due ?? 0);
      if (amount <= 0) continue;
      const validated = Boolean(tax.validated);
      actionable.push({
        title: `${validated ? 'Pago fiscal por registrar' : 'Determinación fiscal pendiente'} · ${tax.label}`,
        detail: validated ? `Saldo por pagar ${money(amount)}.` : `Importe calculado de referencia ${money(amount)}; requiere determinación validada.`,
        period: monthPeriod, deadline: 'Verificar y registrar la fecha del calendario fiscal.', href: '#finance',
        action: validated ? 'Registrar pago' : 'Registrar determinación', tone: validated ? 'overdue' : 'pending',
      });
    }
    host.innerHTML = `<div class="row between wrap"><div><span class="eyebrow">CONTROL DE PENDIENTES</span><h2>Conciliación y preparación fiscal</h2><p>Alertas operativas que requieren una acción o confirmación.</p></div><button class="btn secondary" data-finance-refresh>Actualizar</button></div>
      <div class="finance-stats"><div><small>DESTINO SEMANAL</small><strong>${destination.configured ? 'Configurado' : 'Pendiente'}</strong><span>${destination.configured ? 'Los cortes nuevos podrán emitirse' : 'Cortes nuevos pausados'}</span></div><div><small>PERFILES FISCALES PENDIENTES</small><strong>${fiscalPending.length}</strong><span>Validar tipo fiscal y RFC</span></div><div><small>COMPROBANTES EN REVISIÓN</small><strong>${receiptPending.length}</strong><span>Requieren conciliación</span></div><div><small>LIQUIDACIONES VENCIDAS</small><strong>${overdue.length}</strong><span>Revisar saldo y permiso</span></div></div>
      <section class="finance-detail"><h3>Bandeja de pendientes accionables</h3><p class="hint">Cada aviso indica el periodo y la fecha límite conocida. Cuando el calendario fiscal o el destino de pago no está configurado, se señala como pendiente de captura; el sistema no inventa vencimientos.</p>${!destination.configured ? `<article class="finance-action-item blocked"><div><strong>Destino bancario pendiente · emisión de cortes bloqueada</strong><p>Registra y valida la cuenta receptora para poder crear avisos con fecha de vencimiento.</p><small>Periodo: próxima liquidación · Fecha límite: no aplica mientras siga bloqueada.</small></div><a class="btn secondary" href="#payments">Configurar destino</a></article>` : ''}${actionable.length ? `<div class="finance-action-list">${actionable.map(item => `<article class="finance-action-item ${e(item.tone)}"><div><strong>${e(item.title)}</strong><p>${e(item.detail)}</p><small>Periodo: ${e(item.period)} · Fecha límite: ${e(item.deadline)}</small></div><a class="btn secondary" href="${e(item.href)}">${e(item.action)}</a></article>`).join('')}</div>` : '<p class="hint">No hay diferencias, cortes vencidos, documentos faltantes ni importes fiscales pendientes en el periodo consultado.</p>'}<div class="row wrap"><a class="btn secondary" href="#payments">Abrir Pagos y cuotas</a><a class="btn secondary" href="#fleet">Revisar expedientes</a></div>${warnings.length ? `<details class="finance-warning-context"><summary>Contexto de configuración</summary><ul class="finance-warning-list">${warnings.map(warning => `<li>${e(warning)}</li>`).join('')}</ul></details>` : ''}</section>
      <section class="finance-detail section-gap"><div class="row between wrap"><div><h3>Validación fiscal de conductores</h3><p>Operaciones registra el tipo fiscal y RFC para que el conductor vea y acepte su desglose semanal. La validación no registra ni entera impuestos.</p></div><span class="badge ${fiscalPending.length ? 'pending' : ''}">${fiscalPending.length ? `${fiscalPending.length} por validar` : 'Al día'}</span></div><div class="finance-driver-list">${drivers.map(driver => { const fiscal = driver.fiscal || {}; const verified = Boolean(fiscal.verified_at); return `<article><div class="row between wrap"><strong>${e(driver.name || 'Conductor')}</strong><span class="badge ${verified ? '' : 'pending'}">${verified ? `Validado · ${e(fiscal.entity === 'company' ? 'persona moral' : 'persona física')}` : 'Validación pendiente'}</span></div><p class="hint">${verified ? `${fiscal.rfc_provided ? `RFC ${e(fiscal.rfc || '')}` : 'Sin RFC reportado'} · validado ${new Date(fiscal.verified_at).toLocaleDateString('es-MX')}` : 'Validar contra la documentación fiscal y registrar una nota de revisión.'}</p><button class="btn secondary" data-finance-driver="${e(driver.id)}">${verified ? 'Actualizar validación' : 'Validar tipo fiscal y RFC'}</button></article>`; }).join('') || '<p>No hay conductores registrados.</p>'}</div></section>
      <p class="hint">Las tasas en los cortes son referencias contractuales. Las obligaciones fiscales de Yavoi! y los pagos oficiales se concilian por separado en Finanzas. Un cierre no sustituye una declaración ni el criterio del asesor fiscal.</p>`;
    host.querySelector('[data-finance-refresh]').onclick = render;
    host.querySelectorAll('[data-finance-driver]').forEach(button => {
      button.onclick = () => {
        const driver = drivers.find(item => item.id === button.dataset.financeDriver);
        fiscalDialog(driver);
      };
    });
  }

  async function submit(event, callback) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      await callback(form);
      document.querySelector('#modal')?.close();
      await render();
      notify('Validación fiscal guardada en la auditoría.');
    } catch (error) {
      notify(error.message);
      button.disabled = false;
    }
  }

  function fiscalDialog(driver) {
    const fiscal = driver?.fiscal || {};
    openModal(`Datos fiscales · ${driver.name}`, `<form id="finance-fiscal-form"><label>Tipo<select name="entity"><option value="individual" ${fiscal.entity !== 'company' ? 'selected' : ''}>Persona física</option><option value="company" ${fiscal.entity === 'company' ? 'selected' : ''}>Persona moral</option></select></label><label>RFC (vacío si no proporcionado)<input name="rfc" maxlength="13" value="${e(fiscal.rfc)}"></label><p class="hint">Verifica contra documentación fiscal. La tasa que se muestre al conductor es una referencia contractual; no significa que Yavoi! retuvo o enteró ese impuesto.</p><label>Nota de validación<textarea name="note" minlength="5" required></textarea></label><button class="btn" type="submit">Guardar validación</button></form>`);
    document.querySelector('#finance-fiscal-form').onsubmit = event => submit(event, form => rpc('finance_verify_profile', {
      driver_id: driver.id,
      entity: form.elements.entity.value,
      rfc: form.elements.rfc.value,
      verify_destination: false,
      note: form.elements.note.value,
    }));
  }

  await render();
}
