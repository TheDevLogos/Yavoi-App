import {test} from 'node:test';
import assert from 'node:assert/strict';
import {movePeriod,taxRows,financialWarnings,financialCsv,reportPrintBody,financePdf} from '../src/finance-report.js';
const fixture=()=>({meta:{period:'month',starts_on:'2026-09-01',ends_on:'2026-10-01',generated_at:'2026-09-29T12:00:00Z'},summary:{isr_withheld_cents:210,vat_withheld_cents:800,state_contribution_cents:174,company_vat_estimate_cents:320,collected_cents:11600},tax_assessments:[],tax_payments:[],corporate:{regime:'RESICO PM',isr_due_cents:600,income_ytd_cents:2000,deductions_ytd_cents:0,isr_accrued_cents:600,opening_reconciled:false,basis:'Conciliar comprobantes'},closure_history:[],daily:[{day:'2026-09-29',trips:1,collected_cents:11600,commission_cents:2000,driver_net_cents:8270}],drivers:[],trips:[],documents:[]});
test('Financial periods handle month ends and year rollover',()=>{
 assert.equal(movePeriod('2026-01-31','month',1),'2026-02-01');
 assert.equal(movePeriod('2026-12-31','month',1),'2027-01-01');
 assert.equal(movePeriod('2026-09-29','week',-1),'2026-09-22');
});
test('Fiscal rows distinguish estimates, validated assessments, payments and credits',()=>{
 const r=fixture();assert.equal(taxRows(r).find(x=>x.kind==='company_isr').due,600);
 r.tax_assessments=[{category:'company_isr',amount_cents:0}];r.tax_payments=[{category:'company_isr',amount_cents:100}];
 const row=taxRows(r).find(x=>x.kind==='company_isr');assert.equal(row.due,0);assert.equal(row.balance,-100);assert.equal(row.validated,true);
 r.meta.period='week';r.tax_assessments=[];assert.equal(taxRows(r).find(x=>x.kind==='company_isr').due,null);
 assert.ok(financialWarnings(r).some(x=>x.includes('enero')));
});
test('Financial exports preserve all rows, escape HTML and neutralise spreadsheet formula injection',()=>{
 const r=fixture();r.documents=[{occurred_on:'2026-09-29',kind:'expense',category:'operations',gross_cents:11600,creditable_vat_cents:1600,reference:'=SUM(1,2)',note:'<script>alert(1)</script>'}];
 assert.ok(financialCsv(r).includes("'=SUM(1,2)"));assert.ok(financialCsv(r).includes('ISR propio RESICO PM'));
 assert.ok(!reportPrintBody(r).includes('<script>'));assert.ok(reportPrintBody(r).includes('&lt;script&gt;'));
 r.trips=Array.from({length:75},(_,i)=>({id:`folio-${i}`,driver_name:'Conductor',day:'2026-09-29',status:'completed'}));
 assert.ok(financialCsv(r).includes('folio-74'));assert.ok(reportPrintBody(r).includes('folio-74'));
});
test('Financial PDF produces a valid complete document with fiscal section',async()=>{
 const doc=await financePdf(fixture());const bytes=Buffer.from(doc.output('arraybuffer'));assert.ok(bytes.toString('ascii',0,5)==='%PDF-');assert.ok(doc.getNumberOfPages()>=2);
});
