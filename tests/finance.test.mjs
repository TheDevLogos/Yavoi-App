import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { payoutEvent, settledPayout, signPayout } from '../supabase/functions/driver-payouts/provider.js';
import { generateKeyPairSync, verify } from 'node:crypto';
import { barPercent, splitIncludedVat, validClabe, withdrawalPreview } from '../src/finance-domain.js';
test('IVA incluido, retiro del 3% y CLABE', () => {
  assert.deepEqual(splitIncludedVat(11600), { base: 10000, vat: 1600 });
  assert.deepEqual(withdrawalPreview(10000, 'daily'), { gross: 10000, fee: 300, feeVat: 41, net: 9700 });
  assert.deepEqual(withdrawalPreview(10000, 'weekly'), { gross: 10000, fee: 0, feeVat: 0, net: 10000 });
  assert.ok(validClabe('032180000118359719'));
  assert.ok(!validClabe('032180000118359710'));
  assert.equal(barPercent(50, [0, 50, 100]), 50);
  assert.equal(barPercent(0, [0, 0]), 0);
});
test('Financial wallet: taxes, cash carry, funding, refunds and withdrawal authorization', async () => {
  const db = new PGlite();
  const d = '20000000-0000-4000-8000-000000000003';
  const rider = '20000000-0000-4000-8000-000000000001';
  const admin = '20000000-0000-4000-8000-000000000005';
  const outsider = '20000000-0000-4000-8000-000000000006';
  await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;create function auth.uid() returns uuid language sql stable as $$select nullif(auth.jwt()->>'sub','')::uuid$$;grant usage on schema auth to authenticated,anon;grant execute on function auth.uid(),auth.jwt() to authenticated,anon;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text);alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert on storage.objects to authenticated;create function storage.foldername(text) returns text[] language sql immutable as $$select (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1]$$;`);
  for (const file of (await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(x=>x.endsWith('.sql')).sort()) {
    await db.exec((await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8')).replace(/alter publication supabase_realtime add table[^;]+;/g,''));
  }
  for (const [id, role] of [[d,'driver'],[rider,'passenger'],[admin,'admin'],[outsider,'passenger']]) {
    await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[id,`${role}${id.slice(-1)}@example.com`]);
    await db.query("update public.profiles set role=$2,full_name=$2 where id=$1",[id,role]);
  }
  await db.query("insert into public.drivers(id,category,billing_mode,cash_commission_bps,card_commission_bps) values($1,'basic','commission',2000,2000)",[d]);
  async function as(id, aal='aal1') { await db.exec('reset role'); await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:id,role:'authenticated',aal})]); await db.exec('set role authenticated'); }
  async function rpc(command,payload={}) { return (await db.query('select public.yavoi($1,$2::jsonb) result',[command,JSON.stringify(payload)])).rows[0].result; }
  await as(admin);
  await assert.rejects(()=>rpc('finance_settings',{note:'Sin MFA'}),/dos pasos/);
  await as(d);
  await assert.rejects(()=>rpc('finance_operations'),/Operaciones/);
  await assert.rejects(()=>db.query('select * from public.driver_wallet_entries'),/permission denied/);
  await assert.rejects(()=>rpc('finance_verify_profile',{driver_id:d}),/dos pasos/);
  await rpc('finance_profile',{payout_kind:'bank',payout_destination:'032180000118359719',payout_holder:'Conductor de prueba',weekly_auto:true});
  await assert.rejects(()=>rpc('finance_profile',{payout_kind:'bank',payout_destination:'032180000118359710',payout_holder:'Conductor de prueba'}),/CLABE/);
  await as(admin,'aal2');
  await rpc('finance_verify_profile',{driver_id:d,entity:'individual',rfc:'VILA880101AB1',verify_destination:true,note:'RFC y cuenta comprobados'});
  await rpc('finance_settings',{note:'Prueba habilitada',payouts_enabled:true,level_discounts:{Activo:0},dynamic_max_bps:15000});
  await db.exec('reset role');
  for (const [provided,entity,isr,iva] of [[true,'individual',210,800],[true,'company',250,800],[false,'individual',2000,1600]]) {
    const split=(await db.query('select private.finance_split(11600,1000,2320,true,$1::jsonb) f',[JSON.stringify({rfc_provided:provided,entity})])).rows[0].f;
    assert.equal(split.isr_withheld_cents,Math.round(11000*isr/10000));
    assert.equal(split.vat_withheld_cents,iva);
    assert.equal(split.commission_base_cents,2000);
    assert.equal(split.commission_vat_cents,320);
  }
  const cashSplit=(await db.query("select private.finance_split(11600,1000,2320,false,'{}') f")).rows[0].f;
  assert.equal(cashSplit.isr_withheld_cents,0);assert.equal(cashSplit.vat_withheld_cents,0);
  assert.equal((await db.query("select private.finance_weekly_due('2026-09-28T12:30:00Z')='2026-09-28T13:00:00Z'::timestamptz due")).rows[0].due, true);
  assert.equal((await db.query("select private.finance_weekly_due('2026-09-29T12:30:00Z')='2026-10-05T13:00:00Z'::timestamptz due")).rows[0].due, true);
  const terms={version:'test',vat_included:true,level_discounts:{Activo:0}};
  async function trip(method,discount=0) {
    const q=(await db.query(`insert into public.quotes(passenger_id,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,distance_km,fare_cents,commission_cents,financial_terms) values($1,'Origen','Destino',28.19,-105.47,28.2,-105.46,'basic',5,11600,2320,$2) returning id`,[rider,JSON.stringify(terms)])).rows[0];
    return (await db.query(`insert into public.trips(passenger_id,driver_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,fare_cents,commission_cents,commission_bps_applied,billing_mode,payment_method,payment_status,tip_cents,reward_discount_cents,total_cents,completed_at) values($1,$2,$3,gen_random_uuid(),'completed','Origen','Destino',28.19,-105.47,28.2,-105.46,'basic',11600,2320,2000,'commission',$4,'paid',1000,$5,12600-$5,now()) returning *`,[rider,d,q.id,method,discount])).rows[0];
  }
  const cash=await trip('cash');
  // A completed cash trip keeps the passenger amount and the contractual
  // driver amount tied to the same fare snapshot. Taxes are not withheld
  // from cash because it is collected directly by the driver.
  assert.equal(cash.financial_breakdown.fare_cents,cash.fare_cents);
  assert.equal(cash.financial_breakdown.passenger_total_cents,cash.fare_cents+cash.tip_cents);
  assert.equal(cash.financial_breakdown.commission_cents,cash.commission_cents);
  assert.equal(cash.financial_breakdown.cash_commission_due_cents,cash.commission_cents);
  assert.equal(cash.financial_breakdown.isr_withheld_cents,0);
  assert.equal(cash.financial_breakdown.vat_withheld_cents,0);
  assert.equal(cash.financial_breakdown.contractual_net_cents,cash.fare_cents+cash.tip_cents-cash.commission_cents);
  let balance=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w;
  assert.equal(balance.debt_cents,2320);
  assert.equal((await db.query('select count(*)::int n from public.driver_commission_settlements where driver_id=$1',[d])).rows[0].n,0);
  const card=await trip('card',1160);
  // Card settlement, discount reimbursement and driver detail must reconcile
  // exactly in integer cents against the amount actually charged.
  const cardBreakdown=card.financial_breakdown;
  assert.equal(cardBreakdown.fare_cents,card.fare_cents);
  assert.equal(cardBreakdown.passenger_total_cents,card.fare_cents-card.reward_discount_cents+card.tip_cents);
  assert.equal(cardBreakdown.promotion_pending_cents,card.reward_discount_cents);
  assert.equal(cardBreakdown.commission_cents,card.commission_cents);
  assert.equal(cardBreakdown.taxable_base_cents+cardBreakdown.fare_vat_cents,card.fare_cents-card.reward_discount_cents);
  assert.equal(cardBreakdown.commission_base_cents+cardBreakdown.commission_vat_cents,card.commission_cents);
  assert.equal(cardBreakdown.net_cents,cardBreakdown.passenger_total_cents-card.commission_cents-cardBreakdown.isr_withheld_cents-cardBreakdown.vat_withheld_cents);
  assert.equal(cardBreakdown.contractual_net_cents,cardBreakdown.net_cents+(await db.query('select (private.finance_split($1,0,0,true,$2::jsonb)->>\'net_cents\')::bigint amount',[card.reward_discount_cents,JSON.stringify({rfc_provided:true,entity:'individual'})])).rows[0].amount);
  let pay=(await db.query(`insert into public.payments(payer_id,driver_id,trip_id,kind,provider,amount_cents,status,provider_approved_at,funds_available_at) values($1,$2,$3,'ride','mercado_pago',11440,'approved',now(),now()) returning *`,[rider,d,card.id])).rows[0];
  assert.equal(pay.amount_cents,cardBreakdown.passenger_total_cents);
  const split=(await db.query('select private.finance_split(10440,1000,2320,true,$1::jsonb) f',[JSON.stringify({rfc_provided:true,entity:'individual'})])).rows[0].f;
  balance=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w;
  assert.equal(balance.balance_cents,split.net_cents-2320);
  const before=balance.balance_cents;
  await db.query("update public.payments set funds_available_at=now()+interval '1 day' where id=$1",[pay.id]);
  const held=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w;
  assert.equal(held.held_cents,split.net_cents);
  assert.equal(held.available_cents,0);
  await db.query('update public.payments set funds_available_at=now() where id=$1',[pay.id]);
  await db.query("update public.payments set status='approved' where id=$1",[pay.id]);
  await db.query("update public.trips set status='completed' where id=$1",[card.id]);
  assert.equal((await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents,before);
  await as(outsider);await assert.rejects(()=>rpc('finance_wallet'),/conductor/);
  await as(d);
  assert.equal((await rpc('finance_wallet')).days.length,7);
  const withdrawalKey=crypto.randomUUID();
  const withdrawal=await rpc('finance_withdraw',{mode:'daily',amount_cents:1000,request_key:withdrawalKey});
  assert.equal(withdrawal.fee_cents,30);assert.equal(withdrawal.net_cents,970);
  assert.equal((await rpc('finance_withdraw',{mode:'daily',amount_cents:1000,request_key:withdrawalKey})).id,withdrawal.id);
  await assert.rejects(()=>rpc('finance_withdraw',{mode:'daily',amount_cents:1000,request_key:crypto.randomUUID()}),/diario/);
  await as(admin,'aal2');
  await rpc('finance_review_withdrawal',{withdrawal_id:withdrawal.id,status:'paid',reference:'SPEI-FINANCE-TEST',note:'Transferencia confirmada en prueba'});
  await assert.rejects(()=>rpc('finance_review_withdrawal',{withdrawal_id:withdrawal.id,status:'paid',reference:'SPEI-FINANCE-TEST',note:'Repetido'}),/cerrado/);
  const fundingKey=crypto.randomUUID();
  const funding={driver_id:d,kind:'commission_payment',amount_cents:2320,request_key:fundingKey,reference:'SPEI-FUNDING-TEST',note:'Comisión en efectivo pagada'};
  await rpc('finance_funding',funding); await rpc('finance_funding',funding);
  await assert.rejects(()=>rpc('finance_funding',{...funding,request_key:crypto.randomUUID()}),/duplicate/);
  await db.exec('reset role');
  const refundBefore=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents;
  await db.query("update public.payments set status='refunded' where id=$1",[pay.id]);
  const afterRefund=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents;
  assert.equal(afterRefund,refundBefore-split.net_cents);
  await db.query("update public.payments set status='refunded' where id=$1",[pay.id]);
  assert.equal((await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents,afterRefund);
  const tipPay=(await db.query(`insert into public.payments(payer_id,driver_id,trip_id,kind,provider,amount_cents,status,provider_approved_at,funds_available_at) values($1,$2,$3,'tip','mercado_pago',500,'approved',now(),now()) returning id`,[rider,d,card.id])).rows[0];
  const withTip=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents;
  assert.equal(withTip,afterRefund+489);
  await db.query("update public.payments set status='refunded' where id=$1",[tipPay.id]);
  await db.query("update public.payments set status='refunded' where id=$1",[tipPay.id]);
  assert.equal((await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents,afterRefund);
  await as(admin,'aal2');
  assert.equal((await rpc('finance_operations')).tax_summary.isr_cents,0);
  await rpc('finance_funding',{driver_id:d,kind:'incentive',amount_cents:11600,request_key:crypto.randomUUID(),reference:'INCENTIVE-TEST',note:'Incentivo bruto conciliado'});
  await rpc('finance_provider',{provider:'mercado_pago',note:'Proveedor de prueba controlada'});
  await as(d);
  const weekly=await rpc('finance_withdraw',{mode:'weekly',amount_cents:1000,request_key:crypto.randomUUID()});
  let weeklyData=await rpc('finance_wallet');
  assert.equal(weeklyData.week_net_cents,weeklyData.days.reduce((n,x)=>n+Number(x.net_cents),0));
  assert.ok((await rpc('finance_statement')).entries.length>0);
  await as(outsider); await assert.rejects(()=>rpc('finance_statement',{driver_id:d}),/titular/);
  await db.exec('reset role');
  await db.query('update public.driver_withdrawals set scheduled_for=now() where id=$1',[weekly.id]);
  await db.exec('set role service_role');
  const jobs=(await db.query("select public.yavoi_payout_worker('claim') jobs")).rows[0].jobs;
  const job=jobs.find(x=>x.id===weekly.id); assert.ok(job); assert.equal(job.provider_body.transactions[0].account.number,'032180000118359719');
  const event={withdrawal_id:weekly.id,transaction_id:'txn-test',external_reference:String(job.provider_reference),amount_cents:1000,currency:'MXN',status:'approved',status_detail:''};
  await db.query("select public.yavoi_payout_worker('registered',$1)",[JSON.stringify({...event,payout_id:'payout-test'})]);
  await assert.rejects(()=>db.query("select public.yavoi_payout_worker('result',$1)",[JSON.stringify({...event,amount_cents:null})]),/no coincide/);
  await db.query("select public.yavoi_payout_worker('result',$1)",[JSON.stringify(event)]);
  await db.exec('reset role');
  assert.equal((await db.query('select status from public.driver_withdrawals where id=$1',[weekly.id])).rows[0].status,'processing');
  const prePayout=(await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents;
  await db.exec('set role service_role');
  await db.query("select public.yavoi_payout_worker('result',$1)",[JSON.stringify({...event,status:'processed',status_detail:'approved'})]);
  await db.query("select public.yavoi_payout_worker('result',$1)",[JSON.stringify({...event,status:'processed',status_detail:'approved'})]);
  await db.exec('reset role');
  assert.equal((await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents,prePayout-1000);
  await db.exec('set role service_role');
  await db.query("select public.yavoi_payout_worker('result',$1)",[JSON.stringify({...event,status:'refunded',status_detail:'refunded'})]);
  await db.query("select public.yavoi_payout_worker('result',$1)",[JSON.stringify({...event,status:'refunded',status_detail:'refunded'})]);
  await db.exec('reset role');
  assert.equal((await db.query('select private.finance_wallet_data($1) w',[d])).rows[0].w.balance_cents,prePayout);
  assert.equal((await db.query('select status from public.driver_withdrawals where id=$1',[weekly.id])).rows[0].status,'rejected');

  // Operations reporting: complete aggregates, fiscal dates, documents, security
  // and immutable revisions. No closure mutates a trip or a wallet.
  await as(d);
  await assert.rejects(()=>rpc('finance_report'),/dos pasos/);
  await as(admin);
  await assert.rejects(()=>rpc('finance_report'),/dos pasos/);
  await as(admin,'aal2');
  await assert.rejects(()=>db.query('select * from public.finance_closures'),/permission denied/);
  await db.exec('reset role');
  await db.query(`insert into public.payments(payer_id,driver_id,trip_id,kind,provider,amount_cents,status,provider_approved_at) values($1,$2,$3,'ride','cash',12600,'approved',now())`,[rider,d,cash.id]);
  await as(admin,'aal2');
  let report=await rpc('finance_report');
  assert.equal(report.daily.length,7);
  assert.equal(report.summary.expected_cents,12600);
  assert.equal(report.summary.collected_cents,12600);
  assert.equal(report.summary.commission_cents,2320);
  assert.equal(report.summary.state_contribution_cents,174);
  assert.equal(report.summary.promotion_pending_cents,0);
  assert.equal(report.summary.collected_cents,report.daily.reduce((n,x)=>n+x.collected_cents,0));
  assert.equal(report.summary.journal_opening_cents+report.summary.journal_movement_cents,report.summary.journal_closing_cents);
  if(process.env.FINANCE_PREVIEW_OUTPUT){const {writeFile}=await import('node:fs/promises');await writeFile(process.env.FINANCE_PREVIEW_OUTPUT,JSON.stringify(report));}
  const today=report.meta.generated_at.slice(0,10);
  const expenseKey=crypto.randomUUID();
  const expense={kind:'expense',category:'operations',gross_cents:11600,creditable_vat_cents:1600,occurred_on:today,reference:'CFDI-FINANCE-TEST',note:'Comprobante validado de operación',request_key:expenseKey,fiscal_validated:true};
  await assert.rejects(()=>rpc('finance_document',{...expense,creditable_vat_cents:1700}),/IVA/);
  await assert.rejects(()=>rpc('finance_document',{...expense,fiscal_validated:false}),/comprobante/);
  const doc=await rpc('finance_document',expense);
  assert.equal((await rpc('finance_document',expense)).id,doc.id);
  await assert.rejects(()=>rpc('finance_document',{...expense,request_key:crypto.randomUUID()}),/duplicate/);
  report=await rpc('finance_report');
  assert.equal(report.summary.expenses_cents,10000);
  assert.equal(report.summary.expense_vat_credit_cents,1600);
  const filtered=await rpc('finance_report',{driver_id:d});assert.equal(filtered.summary.expenses_cents,0);
  assert.equal(filtered.summary.collected_cents,12600);
  const month=today.slice(0,7)+'-01';
  const assessment={kind:'tax_assessment',category:'company_isr',gross_cents:3000,occurred_on:today,period_start:month,reference:'ISR-ASSESSMENT-TEST',note:'Determinación fiscal validada',fiscal_validated:true,request_key:crypto.randomUUID()};
  const assessmentDoc=await rpc('finance_document',assessment);
  await assert.rejects(()=>rpc('finance_document',{...assessment,request_key:crypto.randomUUID(),reference:'ISR-ASSESSMENT-OTHER'}),/determinación vigente/);
  await rpc('finance_document',{kind:'tax_payment',category:'company_isr',gross_cents:1000,occurred_on:today,period_start:month,reference:'SAT-PAYMENT-TEST',note:'Pago confirmado del impuesto',request_key:crypto.randomUUID()});
  const monthly=await rpc('finance_report',{period:'month'});
  assert.equal(monthly.tax_assessments.find(x=>x.category==='company_isr').amount_cents,3000);
  assert.equal(monthly.tax_payments.find(x=>x.category==='company_isr').amount_cents,1000);
  assert.equal((await rpc('finance_report')).tax_assessments.length,0);
  await rpc('finance_document',{reverses_id:assessmentDoc.id,occurred_on:today,reference:'ASSESSMENT-REVERSED',note:'Revertir determinación para verificar estimación',fiscal_validated:true,request_key:crypto.randomUUID()});
  assert.equal((await rpc('finance_report',{period:'month'})).tax_assessments.length,0);
  const baseline=(await rpc('finance_report',{period:'month'})).corporate;
  const fiscal={kind:'fiscal_adjustment',category:'cash_commission_offset',gross_cents:11600,occurred_on:today,period_start:month,reference:'CASH-COMMISSION-OFFSET',note:'Comisiones efectivamente compensadas validadas',fiscal_validated:true,request_key:crypto.randomUUID()};
  await assert.rejects(()=>rpc('finance_document',{...fiscal,fiscal_validated:false}),/comprobante/);
  await rpc('finance_document',fiscal);
  let projection=(await rpc('finance_report',{period:'month'})).corporate;
  assert.equal(projection.income_ytd_cents,baseline.income_ytd_cents+10000);
  assert.equal(projection.output_vat_period_cents,baseline.output_vat_period_cents+1600);
  const ded=await rpc('finance_document',{...expense,reference:'DEDUCTION-ISR-TEST',request_key:crypto.randomUUID(),gross_cents:5800,creditable_vat_cents:800,deductible_cents:5000});
  projection=(await rpc('finance_report',{period:'month'})).corporate;
  assert.equal(projection.deductions_ytd_cents,baseline.deductions_ytd_cents+5000);
  assert.equal(projection.isr_accrued_cents,Math.round(Math.max(0,baseline.income_ytd_cents+10000-baseline.deductions_ytd_cents-5000)*.30));
  assert.equal(projection.isr_due_cents,Math.max(0,projection.isr_accrued_cents-projection.previous_payments_cents-projection.credits_cents));
  await rpc('finance_document',{reverses_id:ded.id,occurred_on:today,reference:'DEDUCTION-REVERSED',note:'Corrección de deducción validada',fiscal_validated:true,request_key:crypto.randomUUID()});
  assert.equal((await rpc('finance_report',{period:'month'})).corporate.deductions_ytd_cents,baseline.deductions_ytd_cents);
  assert.equal((await rpc('finance_report',{period:'month'})).corporate.opening_reconciled,true);
  await assert.rejects(()=>rpc('finance_document',{...fiscal,category:'opening_certified',gross_cents:0,period_start:today.slice(0,4)+'-01-01',reference:'YEAR-OPENING-TEST',request_key:crypto.randomUUID()}),/saldos históricos de prueba/);

  await rpc('finance_document',{kind:'expense',reverses_id:doc.id,gross_cents:doc.gross_cents,occurred_on:today,reference:'CFDI-CORRECTION-TEST',note:'Comprobante corregido con contrapartida',request_key:crypto.randomUUID(),fiscal_validated:true});
  assert.equal((await rpc('finance_report')).summary.expenses_cents,0);
  await assert.rejects(()=>rpc('finance_document',{reverses_id:doc.id,occurred_on:today,reference:'CFDI-REPEAT-CORRECTION',note:'Corrección repetida',request_key:crypto.randomUUID()}),/corregido/);
  await assert.rejects(()=>rpc('finance_close',{request_key:crypto.randomUUID(),note:'Periodo sigue abierto'}),/sigue abierto/);
  await db.exec('reset role');
  const past=(await db.query(`select (date_trunc('week',timezone('America/Chihuahua',now()))-interval '7 days')::date::text as day`)).rows[0].day;
  const oldCash=await trip('cash');
  await db.query(`update public.trips set completed_at=$2::date::timestamp at time zone 'America/Chihuahua' where id=$1`,[oldCash.id,past]);
  await as(admin,'aal2');
  const closing={period:'week',anchor:past,request_key:crypto.randomUUID(),note:'Cierre anterior con pendientes revisados',accept_exceptions:true};
  await assert.rejects(()=>rpc('finance_close',{...closing,accept_exceptions:false}),/observaciones/);
  const close=await rpc('finance_close',closing);
  assert.equal(close.revision,1);assert.equal(close.status,'closed_with_exceptions');
  assert.equal((await rpc('finance_close',closing)).id,close.id);
  const saved=await rpc('finance_closed_report',{closure_id:close.id});
  await rpc('finance_document',{kind:'expense',category:'operations',gross_cents:5000,occurred_on:past,reference:'LATE-EXPENSE-TEST',note:'Gasto anterior conciliado tarde',request_key:crypto.randomUUID()});
  const currentPast=await rpc('finance_report',{period:'week',anchor:past});
  assert.equal(currentPast.summary.operating_result_cents,saved.summary.operating_result_cents-5000);
  assert.equal((await rpc('finance_closed_report',{closure_id:close.id})).summary.operating_result_cents,saved.summary.operating_result_cents);
  assert.equal((await rpc('finance_close',{...closing,request_key:crypto.randomUUID()})).revision,2);
  const emptyPast=(await db.query(`select (date_trunc('week',timezone('America/Chihuahua',now()))-interval '21 days')::date::text as day`)).rows[0].day;
  const noOpeningProof=await rpc('finance_close',{period:'week',anchor:emptyPast,request_key:crypto.randomUUID(),note:'Cierre sin saldos históricos de prueba'});
  assert.equal(noOpeningProof.status,'closed');
  await as(outsider);await assert.rejects(()=>rpc('finance_closed_report',{closure_id:close.id}),/dos pasos/);

  // A card cancellation keeps only the retained cancellation fee. The original
  // fare is never credited to the driver after the passenger refund completes.
  await db.exec('reset role');
  const cancellationTerms={version:'test-cancellation',vat_included:true,level_discounts:{Activo:0}};
  const cancellationQuote=(await db.query(`insert into public.quotes(passenger_id,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,distance_km,fare_cents,commission_cents,financial_terms) values($1,'Origen','Destino',28.19,-105.47,28.2,-105.46,'basic',5,11600,2320,$2) returning id`,[rider,JSON.stringify(cancellationTerms)])).rows[0];
  const cancellationTrip=(await db.query(`insert into public.trips(passenger_id,driver_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,fare_cents,commission_cents,commission_bps_applied,billing_mode,payment_method,payment_status,total_cents,cancellation_fee_cents,cancellation_commission_cents,cancelled_at) values($1,$2,$3,gen_random_uuid(),'cancelled','Origen','Destino',28.19,-105.47,28.2,-105.46,'basic',11600,2320,2000,'commission','card','paid',11600,1160,232,now()) returning *`,[rider,d,cancellationQuote.id])).rows[0];
  assert.equal(cancellationTrip.financial_breakdown.passenger_total_cents,1160);
  assert.equal(cancellationTrip.financial_breakdown.commission_cents,232);
  assert.equal(cancellationTrip.financial_breakdown.state_contribution_cents,17);
  const cancellationPayment=(await db.query(`insert into public.payments(payer_id,driver_id,trip_id,kind,provider,amount_cents,retained_amount_cents,status,provider_approved_at) values($1,$2,$3,'ride','mercado_pago',11600,1160,'refunded',now()) returning id`,[rider,d,cancellationTrip.id])).rows[0];
  const cancellationEntries=(await db.query(`select kind,amount_cents from public.driver_wallet_entries where trip_id=$1 order by created_at,kind`,[cancellationTrip.id])).rows;
  assert.deepEqual(cancellationEntries,[
    {kind:'card_credit',amount_cents:1160},
    {kind:'commission',amount_cents:-232},
    {kind:'isr',amount_cents:-21},
    {kind:'vat',amount_cents:-80},
  ]);
  assert.equal((await db.query('select count(*)::int n from public.driver_wallet_entries where trip_id=$1',[cancellationTrip.id])).rows[0].n,4);
  assert.ok(cancellationPayment.id);

  // Promotions are posted only by Operations with a unique reconciliation
  // reference, and credit the same tax treatment shown in the trip detail.
  await as(admin,'aal2');
  await rpc('finance_funding',{driver_id:d,kind:'promotion',trip_id:card.id,amount_cents:1160,request_key:crypto.randomUUID(),reference:'PROMO-TRIP-TEST',note:'Promoción del viaje conciliada por Operaciones'});
  await assert.rejects(()=>rpc('finance_funding',{driver_id:d,kind:'promotion',trip_id:card.id,amount_cents:1160,request_key:crypto.randomUUID(),reference:'PROMO-TRIP-REPEAT',note:'Intento duplicado de promoción'}),/Promoción ya abonada/);
  await db.exec('reset role');
  assert.deepEqual((await db.query(`select kind,amount_cents from public.driver_wallet_entries where trip_id=$1 and entry_key like 'promotion%' order by entry_key`,[card.id])).rows,[
    {kind:'isr',amount_cents:-21},
    {kind:'vat',amount_cents:-80},
    {kind:'promotion_credit',amount_cents:1160},
  ]);

  // A correction cannot exist without the terminal trip, evidence and a unique
  // reference. Repeating the same request remains idempotent and adds no row.
  await as(admin,'aal2');
  await assert.rejects(()=>rpc('finance_funding',{driver_id:d,kind:'adjustment',amount_cents:250,request_key:crypto.randomUUID(),reference:'ADJ-NO-TRIP',note:'Corrección sin viaje'}),/viaje finalizado/);
  const adjustmentKey=crypto.randomUUID();
  const adjustment={driver_id:d,kind:'adjustment',trip_id:card.id,amount_cents:250,request_key:adjustmentKey,reference:'ADJ-TRIP-TEST',note:'Corrección documentada por Operaciones'};
  const adjustmentResult=await rpc('finance_funding',adjustment);
  assert.equal((await rpc('finance_funding',adjustment)).entry.id,adjustmentResult.entry.id);
  await db.exec('reset role');
  const adjustmentEntry=(await db.query(`select trip_id,kind,amount_cents,detail->>'reference' reference,detail->>'note' note from public.driver_wallet_entries where id=$1`,[adjustmentResult.entry.id])).rows[0];
  assert.deepEqual(adjustmentEntry,{trip_id:card.id,kind:'adjustment',amount_cents:250,reference:'ADJ-TRIP-TEST',note:'Corrección documentada por Operaciones'});
  await db.close();
});

test('Payouts: signature, intermediate states and authoritative amounts', async () => {
 const { privateKey, publicKey } = generateKeyPairSync('ed25519');
 const body = JSON.stringify({ external_reference: '1234567' });
 const signature = await signPayout(body, privateKey.export({ format: 'pem', type: 'pkcs8' }));
 assert.ok(verify(null, Buffer.from(body), publicKey, Buffer.from(signature, 'base64')));
 assert.ok(!settledPayout({ status: 'approved' }));
 assert.ok(!settledPayout({ status: 'success', status_detail: 'in_progress' }));
 assert.ok(settledPayout({ status: 'processed', status_detail: 'approved' }));
 const w = { id: 'withdrawal', provider_transaction_id: 'txn', provider_reference: 123, net_cents: 9700 };
 const t = { id: 'txn', external_reference: '123', amount: { currency: 'MXN', value: 97 }, status: 'processed', status_detail: 'approved' };
 assert.equal(payoutEvent(w,t).amount_cents,9700);
 assert.throws(()=>payoutEvent(w,{...t,amount:{currency:'MXN',value:100}}),/no coincide/);
});
