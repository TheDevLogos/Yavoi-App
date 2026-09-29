import { escapeHtml as e, money } from './domain.js';

export const taxNames = { isr_withheld: 'ISR retenido a conductores', vat_withheld: 'IVA retenido a conductores', state_contribution: 'Aportación estatal 1.5%', company_vat: 'IVA propio de Yavoi!', company_isr: 'ISR propio de Yavoi!' };
export const fiscalNames = {income_extra:'Ingresos complementarios sin IVA',cash_commission_offset:'Comisiones de efectivo compensadas en billetera (IVA incluido)',other_deductions:'Deducciones adicionales pagadas y validadas',ptu:'PTU efectivamente pagada',losses:'Pérdidas fiscales aplicables del ejercicio',isr_credit:'ISR acreditable propio',vat_credit:'Saldo de IVA acreditable adicional'};
export const costNames = { operations: 'Operación', marketing: 'Publicidad', processing_fee: 'Procesamiento de pagos', insurance: 'Seguros', technology: 'Tecnología', other: 'Otros gastos' };
export function localToday() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chihuahua', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()); }
export function movePeriod(anchor, period, direction) {
  const d = new Date(`${anchor}T12:00:00Z`);
  if (period === 'month') { d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() + direction); }
  else d.setUTCDate(d.getUTCDate() + direction * 7);
  return d.toISOString().slice(0, 10);
}
export function periodLabel(meta = {}) {
  const last = new Date(`${meta.ends_on}T12:00:00Z`); last.setUTCDate(last.getUTCDate() - 1);
  const date = value => new Date(`${value}T12:00:00Z`).toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
  return `${date(meta.starts_on)} — ${date(last.toISOString().slice(0,10))}`;
}
export function taxRows(report) {
  const s = report.summary;
  const assessed = Object.fromEntries(report.tax_assessments.map(x => [x.category, Number(x.amount_cents)]));
  const paid = Object.fromEntries(report.tax_payments.map(x => [x.category, Number(x.amount_cents)]));
  const calculated = { isr_withheld: s.isr_withheld_cents, vat_withheld: s.vat_withheld_cents, state_contribution: s.state_contribution_cents, company_vat: s.company_vat_estimate_cents, company_isr: report.meta.period==='month' ? (report.corporate?.isr_due_cents ?? null) : null };
  return Object.entries(taxNames).map(([kind,label]) => {
    const validated = Object.hasOwn(assessed, kind);
    const due = validated ? assessed[kind] : calculated[kind];
    const settled = paid[kind] || 0;
    return {kind,label,due,paid:settled,balance:due === null ? null : Number(due)-settled,validated,
      basis: validated ? 'Determinación validada del mes' : kind==='company_isr' ? (due===null?'Determinación pendiente':'RESICO PM 30% acumulado, estimado') : kind==='company_vat' ? 'Reserva estimada; validar cobros y acreditamiento' : report.meta.period==='week' ? 'Acumulado semanal' : 'Acumulado calculado del mes'};
  });
}
export function financialWarnings(report) {
  const s = report.summary; const notices=[];
  if (s.pending_trips) notices.push(`${s.pending_trips} viajes con cobro pendiente, diferencia o reembolso en proceso.`);
  if (s.historical_trips) notices.push(`${s.historical_trips} viajes anteriores al nuevo registro fiscal: requieren conciliación; sus retenciones no se reconstruyen automáticamente.`);
  if (s.refunds_pending) notices.push(`${s.refunds_pending} reembolsos aún pendientes de confirmación.`);
  if (s.promotion_pending_cents) notices.push(`Promociones por abonar a conductores: ${money(s.promotion_pending_cents)}. Un abono en billetera aún no equivale a una transferencia bancaria.`);
  if (s.opening_adjustments_cents || s.adjustments_cents) notices.push('Hay saldos de apertura o ajustes manuales: revisa sus comprobantes. No se cuentan como ingresos comerciales.');
  if (!report.saved_closure && report.closure_history.length) notices.push('Existe un cierre guardado. El avance actual puede contener movimientos posteriores; consulta la versión guardada o genera una nueva revisión.');
  return notices;
}
export function reconciliationRows(r) {
  const s=r.summary;
  return [
    ['Cobro esperado de viajes del periodo',s.expected_cents],['Cobro confirmado de esos viajes',s.collected_cents],['Diferencia por conciliar',s.difference_cents],
    ['Comisiones generadas (IVA incluido)',s.commission_cents],['Comisiones sin IVA',s.commission_base_cents],['Ajuste de comisiones por reembolsos de viajes anteriores',s.commission_refund_adjustment_cents||0],['IVA de comisiones',s.commission_vat_cents],
    ['Propinas confirmadas de estos viajes',s.tip_cents],['Cargo por distancia',s.distance_fare_cents||0],['Cargo por tiempo',s.time_fare_cents||0],['Demanda dinámica',s.dynamic_fare_cents||0],['Base y otros componentes de tarifa',s.base_other_fare_cents||0],['Descuentos financiados por Yavoi!',s.discount_cents],['Promociones abonadas en el periodo',s.promotions_credited_cents],['Promociones históricas transferidas',s.legacy_promotion_transfers_cents||0],['Promociones de estos viajes pendientes',s.promotion_pending_cents],
    ['Incentivos abonados',s.incentives_cents],['Neto registrado de los conductores',s.driver_net_cents],['Retiros bancarios netos',s.withdrawals_cents],
    ['Cuotas semanales conciliadas',s.weekly_fees_cents],['Cargos de retiro (IVA incluido)',s.withdrawal_fees_cents],['Gastos netos registrados',s.expenses_cents],['Comisiones del proveedor',s.processor_fees_cents],
    ['Resultado operativo antes de ISR propio',s.operating_result_cents],['Cobros confirmados en el periodo (incluye viajes de otras fechas)',s.flow_gross_cents],['Reembolsos confirmados en el periodo',s.flow_refunds_cents],
    ['Flujo identificado de Yavoi!',s.platform_cash_flow_cents],['Saldo inicial de billeteras',s.journal_opening_cents],['Movimiento de billeteras',s.journal_movement_cents],['Saldo final de billeteras',s.journal_closing_cents],
    ['Saldo a favor de conductores',s.wallet_payable_cents],['Adeudos de conductores',s.wallet_receivable_cents],
    ['Comisiones en efectivo liquidadas directamente',s.cash_commission_payments_cents],['Saldos de apertura conciliados',s.opening_adjustments_cents],['Ajustes conciliados',s.adjustments_cents]
  ];
}
export function corporateRows(c) { return [['Ingresos propios cobrados acumulados sin IVA',c.income_ytd_cents],['Deducciones pagadas validadas acumuladas',c.deductions_ytd_cents],['PTU pagada',c.ptu_cents],['Pérdidas fiscales aplicables',c.losses_cents],['Base fiscal acumulada',c.taxable_base_ytd_cents],['ISR causado acumulado al 30%',c.isr_accrued_cents],['Pagos provisionales de meses anteriores',c.previous_payments_cents],['ISR acreditable propio',c.credits_cents],['Pago provisional estimado del mes',c.isr_due_cents]]; }
export function reportPrintBody(r) {
  const s=r.summary; const warnings=financialWarnings(r);
  const table=(head,rows)=>`<table><thead><tr>${head.map(x=>`<th>${e(x)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${row.map(x=>`<td>${e(x)}</td>`).join('')}</tr>`).join('') || '<tr><td>Sin registros</td></tr>'}</tbody></table>`;
  return `<article class="finance-paper"><header><strong>Yavoi! · Finanzas</strong><h1>${r.meta.period==='week'?'Cierre semanal':'Cierre mensual'}</h1><p>${e(periodLabel(r.meta))} · ${r.saved_closure ? `Versión ${r.saved_closure.revision} · folio ${e(r.saved_closure.id)}` : 'Avance sin cierre guardado'}<br>Generado ${e(new Date(r.meta.generated_at).toLocaleString('es-MX',{timeZone:'America/Chihuahua'}))} · MXN · Hora de Chihuahua</p></header>
  <h2>Resumen financiero</h2>${table(['Concepto','Importe'],reconciliationRows(r).map(([label,n])=>[label,money(n)]))}
  <h2>Impuestos y aportación estatal</h2>${table(['Concepto','Calculado / validado','Pagado','Pendiente / saldo a favor','Base'],taxRows(r).map(x=>[x.label,x.due===null?'Pendiente':money(x.due),money(x.paid),x.balance===null?'Pendiente':money(x.balance),x.basis]))}
  <p>El IVA propio calculado es una reserva de gestión. El ISR propio RESICO usa ingresos cobrados y deducciones validadas acumulados, con tasa de 30%, menos pagos previos y créditos. Requiere validar los saldos del ejercicio. Registrar un cierre no declara ni paga impuestos. La aportación estatal debe conciliarse con el convenio aplicable.</p>
  ${r.corporate?.regime?`<h2>ISR propio RESICO persona moral</h2>${table(['Concepto','Importe'],corporateRows(r.corporate).map(([label,n])=>[label,money(n)]))}<p>${e(r.corporate.basis)}</p>`:''}<h2>Actividad diaria</h2>${table(['Fecha','Viajes','Cobro confirmado','Comisión sin IVA','Neto conductor'],r.daily.map(d=>[d.day,d.trips,money(d.collected_cents),money(d.commission_cents),money(d.driver_net_cents)]))}
  <h2>Por conductor</h2>${table(['Conductor','Viajes','Cobrado','Comisión con IVA','Neto registrado','ISR','IVA retenido','Promoción pendiente'],r.drivers.map(d=>[d.driver_name,d.trips,money(d.collected_cents),money(d.commission_cents),money(d.driver_net_cents),money(d.isr_cents),money(d.vat_cents),money(d.promotion_pending_cents)]))}
  <h2>Detalle por viaje</h2>${table(['Folio','Fecha','Estado','Conductor','Método','Esperado','Confirmado','Comisión','Neto','ISR','IVA','Descuento'],r.trips.map(t=>[t.id,t.day,t.status==='completed'?'Completado':'Cancelado',t.driver_name,t.payment_method==='cash'?'Efectivo':'Electrónico',money(t.expected_cents),money(t.collected_cents),money(t.commission_cents),money(t.driver_net_cents),money(t.isr_cents),money(t.vat_cents),money(t.discount_cents)]))}
  <h2>Comprobantes y pagos registrados</h2>${table(['Fecha','Tipo','Concepto','Importe','IVA acreditable','Deducción ISR','Referencia','Nota'],r.documents.map(d=>[d.occurred_on,d.kind==='expense'?'Gasto':d.kind==='tax_payment'?'Pago fiscal':d.kind==='fiscal_adjustment'?'Ajuste fiscal':'Determinación fiscal',costNames[d.category]||taxNames[d.category]||fiscalNames[d.category]||d.category,money(d.gross_cents*(d.reverses_id?-1:1)),money(d.creditable_vat_cents*(d.reverses_id?-1:1)),money((d.deductible_cents||0)*(d.reverses_id?-1:1)),d.reference,d.note]))}
  ${warnings.length?`<h2>Observaciones</h2><ul>${warnings.map(w=>`<li>${e(w)}</li>`).join('')}</ul>`:''}<p>Resultado operativo: comisiones sin IVA + cuotas sin IVA + cargos de retiro sin IVA − descuentos − incentivos − procesamiento − gastos netos − aportación estatal. No representa el saldo de una cuenta bancaria.</p>
  ${r.saved_closure?`<footer>Nota: ${e(r.saved_closure.note)}<br>Huella del reporte: ${e(r.saved_closure.checksum)}</footer>`:''}</article>`;
}
const csvCell = value => {
  const text=String(value??''); return `"${(/^[\s]*[=+@-]/.test(text) && typeof value !== 'number' ? "'"+text : text).replace(/"/g,'""')}"`;
};
export function financialCsv(r) {
  const rows=[['Yavoi! Finanzas',periodLabel(r.meta),'MXN'],['Estado',r.saved_closure?`Cierre versión ${r.saved_closure.revision}`:'Avance'],['Concepto','Centavos MXN'],...reconciliationRows(r),[],
    ['Impuesto','Calculado / validado centavos','Pagado centavos','Saldo centavos','Base'],...taxRows(r).map(x=>[x.label,x.due??'',x.paid,x.balance??'',x.basis]),[],...(r.corporate?.regime ? [['ISR propio RESICO PM','Centavos MXN'],...corporateRows(r.corporate),[]] : []),
    ['Folio','Fecha','Estado','Conductor','Método','Esperado centavos','Confirmado centavos','Comisión centavos','Neto centavos','ISR centavos','IVA retenido centavos','Descuento centavos','Promoción pendiente centavos'],
    ...r.trips.map(t=>[t.id,t.day,t.status,t.driver_name,t.payment_method,t.expected_cents,t.collected_cents,t.commission_cents,t.driver_net_cents,t.isr_cents,t.vat_cents,t.discount_cents,t.promotion_pending_cents]),[],
    ['Fecha','Tipo','Concepto','Importe centavos','IVA acreditable centavos','Deducción ISR centavos','Referencia','Nota'],...r.documents.map(d=>[d.occurred_on,d.kind,d.category,d.gross_cents*(d.reverses_id?-1:1),d.creditable_vat_cents*(d.reverses_id?-1:1),(d.deductible_cents||0)*(d.reverses_id?-1:1),d.reference,d.note])];
  return '\uFEFF'+rows.map(row=>row.map(csvCell).join(',')).join('\r\n');
}
export async function financePdf(r) {
  const [{jsPDF},{default:autoTable}]=await Promise.all([import('jspdf'),import('jspdf-autotable')]);
  const doc=new jsPDF({unit:'mm',format:'a4',orientation:'landscape'}); const width=doc.internal.pageSize.getWidth();
  doc.setFillColor(8,35,56);doc.rect(0,0,width,32,'F');doc.setTextColor(255);doc.setFontSize(19);doc.text('Yavoi! · Finanzas',14,13);doc.setFontSize(10);doc.text(`${r.meta.period==='week'?'Semanal':'Mensual'} · ${periodLabel(r.meta)} · MXN`,14,22);
  doc.setTextColor(20);doc.setFontSize(10);doc.text(r.saved_closure?`Cierre ${r.saved_closure.id} · versión ${r.saved_closure.revision}`:'Avance: periodo sin cierre guardado',14,39);
  let y=45;
  const section=(title,head,body)=>{
    if(y>175){doc.addPage();y=16;}
    doc.setFontSize(12);doc.setTextColor(8,35,56);doc.text(title,14,y);
    autoTable(doc,{startY:y+4,head:[head],body:body.length?body:[['Sin registros']],margin:{left:14,right:14,bottom:16},styles:{fontSize:8,cellPadding:2,overflow:'linebreak'},headStyles:{fillColor:[8,35,56]},alternateRowStyles:{fillColor:[246,248,251]}});
    y=doc.lastAutoTable.finalY+12;
  };
  // Native vector bars stay crisp on paper and in exported PDFs.
  doc.setFontSize(9);doc.text('Cobros de viajes por día',14,y);y+=5;
  const max=Math.max(1,...r.daily.map(x=>Number(x.collected_cents)));const step=(width-28)/r.daily.length;
  r.daily.forEach((d,i)=>{const h=Number(d.collected_cents)/max*23;doc.setFillColor(255,107,0);doc.rect(14+i*step,y+25-h,Math.max(1,step-2),h,'F');doc.setTextColor(75);doc.setFontSize(6);doc.text(d.day.slice(-2),14+i*step,y+29);});y+=39;
  section('Resumen financiero',['Concepto','Importe'],reconciliationRows(r).map(([label,n])=>[label,money(n)]));
  section('Impuestos y aportación',['Concepto','Calculado / validado','Pagado','Saldo','Base'],taxRows(r).map(x=>[x.label,x.due===null?'Pendiente':money(x.due),money(x.paid),x.balance===null?'Pendiente':money(x.balance),x.basis]));
  if(r.corporate?.regime)section('ISR propio RESICO persona moral',['Concepto','Importe'],corporateRows(r.corporate).map(([label,n])=>[label,money(n)]));
  section('Conductores',['Nombre','Viajes','Cobrado','Comisión con IVA','Neto registrado','ISR','IVA','Promoción pendiente'],r.drivers.map(d=>[d.driver_name,d.trips,money(d.collected_cents),money(d.commission_cents),money(d.driver_net_cents),money(d.isr_cents),money(d.vat_cents),money(d.promotion_pending_cents)]));
  section('Detalle por viaje',['Folio','Fecha','Estado','Conductor','Método','Esperado','Confirmado','Comisión','Neto','ISR','IVA'],r.trips.map(t=>[t.id,t.day,t.status==='completed'?'Completado':'Cancelado',t.driver_name,t.payment_method==='cash'?'Efectivo':'Electrónico',money(t.expected_cents),money(t.collected_cents),money(t.commission_cents),money(t.driver_net_cents),money(t.isr_cents),money(t.vat_cents)]));
  section('Documentos registrados',['Fecha','Concepto','Importe','IVA acreditable','Deducción ISR','Referencia','Nota'],r.documents.map(d=>[d.occurred_on,costNames[d.category]||taxNames[d.category]||fiscalNames[d.category],money(d.gross_cents*(d.reverses_id?-1:1)),money(d.creditable_vat_cents*(d.reverses_id?-1:1)),money((d.deductible_cents||0)*(d.reverses_id?-1:1)),d.reference,d.note]));
  section('Observaciones',['Revisión'],[...financialWarnings(r),'IVA propio: reserva estimada. ISR propio RESICO PM: 30% acumulado sobre base fiscal de caja registrada. Un cierre no declara ni paga impuestos.','La gráfica y los viajes usan fecha de finalización; el flujo de cobros y reembolsos usa fecha de confirmación. El saldo de billeteras es contable.'].map(x=>[x]));
  for(let p=1;p<=doc.getNumberOfPages();p++){doc.setPage(p);doc.setFontSize(8);doc.setTextColor(100);doc.text(`Generado ${r.meta.generated_at} · Página ${p} / ${doc.getNumberOfPages()}`,14,doc.internal.pageSize.getHeight()-7);}
  return doc;
}
