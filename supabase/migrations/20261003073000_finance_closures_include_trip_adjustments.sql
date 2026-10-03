-- Bring post-acceptance wait and mutually accepted fare changes into every live
-- financial report. Existing saved closures stay immutable snapshots.

create or replace function private.finance_trip_facts(a timestamptz,b timestamptz,target uuid default null)
returns table(id uuid,driver_id uuid,driver_name text,day date,status text,payment_method text,
 expected_cents bigint,collected_cents bigint,fare_cents bigint,discount_cents bigint,tip_cents bigint,
 commission_cents bigint,commission_base_cents bigint,commission_vat_cents bigint,
 isr_cents bigint,vat_cents bigint,promotion_credited_cents bigint,promotion_pending_cents bigint,
 driver_net_cents bigint,state_cents bigint,pending_payment boolean,legacy boolean,
 distance_cents bigint,time_cents bigint,dynamic_cents bigint,other_fare_cents bigint,
 destination text,ended_at timestamptz)
language sql stable security definer set search_path='' as $$
 select t.id,t.driver_id,coalesce(pr.full_name,'Sin asignar'),timezone('America/Chihuahua',coalesce(t.completed_at,t.cancelled_at,t.created_at))::date,t.status,t.payment_method,
 case when p.fully_refunded then 0 else x.expected end,coalesce(p.collected,0),case when t.status='completed' then t.fare_cents else t.cancellation_fee_cents end::bigint,
 case when p.fully_refunded then coalesce(j.promo,0) else x.discount end,case when t.status='completed' then (case when p.fully_refunded then 0 else t.tip_cents end)+coalesce(p.extra_tip,0) else 0 end::bigint,
 case when p.fully_refunded then 0 else x.commission end,case when p.fully_refunded then 0 else round(x.commission/1.16)::bigint end,case when p.fully_refunded then 0 else (x.commission-round(x.commission/1.16))::bigint end,
 coalesce(j.isr,0),coalesce(j.vat,0),coalesce(j.promo,0),case when t.payment_status='refunded' or p.fully_refunded then 0 else greatest(0,x.discount-coalesce(j.promo,0)) end,
 coalesce(p.collected,0)+coalesce(j.promo,0)-case when p.fully_refunded then 0 when coalesce(p.collected,0)>0 or x.expected=0 then x.commission else 0 end-coalesce(j.isr,0)-coalesce(j.vat,0),
 case when t.status='completed' then round(greatest(0,coalesce(p.collected,0)-coalesce(p.extra_tip,0)-t.tip_cents)*150/10000.0)::bigint else 0 end,
 coalesce(p.pending,false) or coalesce(p.collected,0)-coalesce(p.extra_tip,0)<>case when p.fully_refunded then 0 else x.expected end,
 t.financial_terms='{}',
 case when t.status='completed' then t.distance_charge_cents else 0 end::bigint,
 case when t.status='completed' then t.time_charge_cents else 0 end::bigint,
 case when t.status='completed' then coalesce((t.financial_terms->>'dynamic_cents')::bigint,0) else 0 end,
 case when t.status='completed' then greatest(0,t.fare_cents-t.distance_charge_cents-t.time_charge_cents-coalesce((t.financial_terms->>'dynamic_cents')::bigint,0)) else t.cancellation_fee_cents end::bigint,
 t.destination,coalesce(t.completed_at,t.cancelled_at,t.created_at)
 from public.trips t left join public.profiles pr on pr.id=t.driver_id
 left join public.driver_promotion_reimbursements reimb on reimb.driver_id=t.driver_id and reimb.week_start=date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date
 cross join lateral (select
 case when t.status='completed' then coalesce(nullif((t.financial_breakdown->>'passenger_total_cents')::bigint,0), private.trip_final_total_cents_v1(t,coalesce(t.completed_at,now()))::bigint) else t.cancellation_fee_cents end::bigint expected,
 case when t.status='completed' then t.reward_discount_cents else 0 end::bigint discount,
 case when t.payment_status='refunded' and t.status='completed' then 0 when t.status='completed' then coalesce(nullif((t.financial_breakdown->>'commission_cents')::bigint,0),t.commission_cents) else t.cancellation_commission_cents end::bigint commission) x
 left join lateral (select
 sum(case when pay.status in ('approved','refund_pending') then pay.amount_cents when pay.status='refunded' then pay.retained_amount_cents else 0 end)::bigint collected,
 sum(case when pay.kind='tip' and pay.status='approved' then pay.amount_cents else 0 end)::bigint extra_tip,
 bool_or(pay.status in ('created','pending','in_process','refund_pending')) pending,
 bool_or(pay.kind='ride' and pay.status='refunded' and pay.retained_amount_cents=0) fully_refunded
 from public.payments pay where pay.trip_id=t.id and pay.kind in ('ride','tip','cancellation_fee','trip_adjustment')) p on true
 left join lateral (select
 -coalesce(sum(e.amount_cents) filter(where e.kind='isr' or (e.kind='refund' and e.detail->>'reversed_kind'='isr')),0)::bigint isr,
 -coalesce(sum(e.amount_cents) filter(where e.kind='vat' or (e.kind='refund' and e.detail->>'reversed_kind'='vat')),0)::bigint vat,
 coalesce(sum(e.amount_cents) filter(where e.kind='promotion_credit'),0)::bigint promo
 from public.driver_wallet_entries e where e.trip_id=t.id) journal on true
 cross join lateral(select journal.isr,journal.vat,journal.promo+case when t.financial_terms='{}' and reimb.status='paid' then t.reward_discount_cents else 0 end::bigint promo) j
 where t.status in ('completed','cancelled') and coalesce(t.completed_at,t.cancelled_at,t.created_at)>=a and coalesce(t.completed_at,t.cancelled_at,t.created_at)<b
 and (target is null or t.driver_id=target)
$$;


create or replace function private.finance_report_v1(payload jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare meta jsonb:=private.finance_period(payload); a timestamptz:=(meta->>'starts_on')::date::timestamp at time zone 'America/Chihuahua'; b timestamptz:=(meta->>'ends_on')::date::timestamp at time zone 'America/Chihuahua';
 target uuid:=nullif(payload->>'driver_id','')::uuid; result jsonb;
begin
 perform private.finance_admin();
 with facts as materialized(select * from private.finance_trip_facts(a,b,target)),
 journals as materialized(select e.*,case when e.kind='refund' then coalesce(e.detail->>'reversed_kind','refund') when e.kind='withdrawal_return' then 'withdrawal' when e.kind='withdrawal_fee_return' then 'withdrawal_fee' else e.kind end effective_kind
 from public.driver_wallet_entries e where e.created_at>=a and e.created_at<b and (target is null or e.driver_id=target)),
 fiscal_journals as materialized(select e.*,case when e.kind='refund' then e.detail->>'reversed_kind' else e.kind end effective_kind from public.driver_wallet_entries e left join public.payments pay on pay.id=e.payment_id
 where (case when e.kind='refund' then e.created_at else coalesce(nullif(e.detail->>'collected_at','')::timestamptz,pay.provider_approved_at,e.created_at) end)>=a
 and (case when e.kind='refund' then e.created_at else coalesce(nullif(e.detail->>'collected_at','')::timestamptz,pay.provider_approved_at,e.created_at) end)<b
 and (target is null or e.driver_id=target)),
 documents as materialized(select d.*,case when d.reverses_id is null then 1 else -1 end sign from public.finance_documents d where d.occurred_on>=(meta->>'starts_on')::date and d.occurred_on<(meta->>'ends_on')::date and target is null),
 expenses as(select coalesce(sum(sign*(gross_cents-creditable_vat_cents)),0)::bigint net,coalesce(sum(sign*gross_cents),0)::bigint gross,coalesce(sum(sign*creditable_vat_cents),0)::bigint vat from documents where kind='expense'),
 fees as(select coalesce(sum(w.amount_cents),0)::bigint gross,coalesce(sum(round(w.amount_cents/1.16)),0)::bigint base from public.weekly_fees w where w.status='paid' and coalesce(w.verified_at,w.updated_at)>=a and coalesce(w.verified_at,w.updated_at)<b and (target is null or w.driver_id=target)),
 legacy_transfers as(select
 coalesce((select sum(c.commission_due_cents) from public.driver_commission_settlements c where c.status='paid' and coalesce(c.verified_at,c.updated_at)>=a and coalesce(c.verified_at,c.updated_at)<b and (target is null or c.driver_id=target)),0)::bigint commissions,
 coalesce((select sum(r.reimbursement_cents) from public.driver_promotion_reimbursements r where r.status='paid' and r.paid_at>=a and r.paid_at<b and (target is null or r.driver_id=target) and not exists(select 1 from public.driver_wallet_entries e where e.driver_id=r.driver_id and e.kind='promotion_credit' and e.trip_id in (select t.id from public.trips t where t.driver_id=r.driver_id and date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date=r.week_start))),0)::bigint promotions),
 state_flows as(select coalesce(sum(
 (case when pay.provider_approved_at>=a and pay.provider_approved_at<b then round(greatest(0,pay.amount_cents-case when pay.kind='ride' then t.tip_cents else 0 end)*150/10000.0) else 0 end)
 -(case when pay.status='refunded' and pay.updated_at>=a and pay.updated_at<b then round(greatest(0,coalesce(nullif(pay.refund_amount_cents,0),pay.amount_cents-pay.retained_amount_cents)-case when pay.kind='ride' and pay.retained_amount_cents=0 then t.tip_cents else 0 end)*150/10000.0) else 0 end)),0)::bigint amount
 from public.payments pay join public.trips t on t.id=pay.trip_id where t.status='completed' and pay.kind in ('ride','trip_adjustment') and pay.status in ('approved','refund_pending','refunded') and (target is null or pay.driver_id=target) and ((pay.provider_approved_at>=a and pay.provider_approved_at<b) or (pay.status='refunded' and pay.updated_at>=a and pay.updated_at<b))),
post_acceptance as(select coalesce(sum(case when t.payment_status='refunded' then 0 else coalesce((t.financial_breakdown->>'post_acceptance_adjustments_cents')::bigint,0) end),0)::bigint amount
 from public.trips t where t.status='completed' and coalesce(t.completed_at,t.created_at)>=a and coalesce(t.completed_at,t.created_at)<b and (target is null or t.driver_id=target)),
 processors as(select coalesce(sum(p.processing_fee_cents),0)::bigint fees from public.payments p where p.provider='mercado_pago' and p.provider_approved_at>=a and p.provider_approved_at<b and p.status in ('approved','refunded','refund_pending') and (target is null or p.driver_id=target)
 and not exists(select 1 from public.finance_documents d where d.payment_id=p.id and d.kind='expense' and d.reverses_id is null and not exists(select 1 from public.finance_documents r where r.reverses_id=d.id))),
 wallets as materialized(select e.driver_id,coalesce(pr.full_name,'Conductor') driver_name,
 coalesce(sum(e.amount_cents) filter(where e.created_at<a),0)::bigint opening_cents,
 coalesce(sum(e.amount_cents) filter(where e.created_at>=a),0)::bigint movement_cents,
 sum(e.amount_cents)::bigint closing_cents
 from public.driver_wallet_entries e left join public.profiles pr on pr.id=e.driver_id where e.created_at<b and (target is null or e.driver_id=target) group by e.driver_id,pr.full_name),
 ledger_totals as(select
 (select coalesce(-sum(amount_cents),0)::bigint from fiscal_journals where effective_kind='isr') isr,
 (select coalesce(-sum(amount_cents),0)::bigint from fiscal_journals where effective_kind='vat') vat,
 coalesce(-sum(amount_cents) filter(where effective_kind='withdrawal'),0)::bigint withdrawals,
 coalesce(-sum(amount_cents) filter(where effective_kind='withdrawal_fee'),0)::bigint withdrawal_fees,
 coalesce(-sum(coalesce((detail->>'vat_cents')::bigint,amount_cents-round(amount_cents/1.16))) filter(where kind='withdrawal_fee_return'),0)::bigint returned_fee_vat,
 coalesce(sum((detail->>'vat_cents')::bigint) filter(where kind='withdrawal_fee'),0)::bigint fee_vat,
 coalesce(sum(amount_cents) filter(where kind='incentive'),0)::bigint incentives,
 coalesce(sum(amount_cents) filter(where kind='promotion_credit'),0)::bigint promotions,
 coalesce(sum(amount_cents) filter(where kind='commission_payment'),0)::bigint commission_payments,
 coalesce(sum(amount_cents) filter(where kind='opening'),0)::bigint opening_adjustments,
 coalesce(sum(amount_cents) filter(where kind='adjustment'),0)::bigint adjustments,
 coalesce(-sum(amount_cents) filter(where kind='refund' and effective_kind in ('commission','cash_commission') and not exists(select 1 from facts f where f.id=journals.trip_id)),0)::bigint commission_refund_adjustment from journals),
 trip_totals as(select count(*)::integer trips,count(*) filter(where status='completed')::integer completed,count(*) filter(where status='cancelled')::integer cancelled,
 count(*) filter(where pending_payment)::integer exceptions,count(*) filter(where legacy)::integer historical,
 coalesce(sum(expected_cents),0)::bigint expected,coalesce(sum(collected_cents),0)::bigint collected,
 coalesce(sum(collected_cents) filter(where payment_method='cash'),0)::bigint cash,coalesce(sum(collected_cents) filter(where payment_method='card'),0)::bigint card,
 coalesce(sum(fare_cents),0)::bigint fares,coalesce(sum(discount_cents),0)::bigint discounts,coalesce(sum(tip_cents),0)::bigint tips,
 coalesce(sum(commission_cents),0)::bigint commission,coalesce(sum(commission_base_cents),0)::bigint commission_base,coalesce(sum(commission_vat_cents),0)::bigint commission_vat,
 coalesce(sum(driver_net_cents),0)::bigint driver_net,coalesce(sum(promotion_pending_cents),0)::bigint promo_pending,
 coalesce(sum(state_cents),0)::bigint state,
 coalesce(sum(distance_cents),0)::bigint distance,coalesce(sum(time_cents),0)::bigint time,coalesce(sum(dynamic_cents),0)::bigint dynamic,coalesce(sum(other_fare_cents),0)::bigint other from facts),
 payment_flows as(select
 coalesce(sum(p.amount_cents) filter(where p.provider_approved_at>=a and p.provider_approved_at<b),0)::bigint gross,
 coalesce(sum(coalesce(nullif(p.refund_amount_cents,0),p.amount_cents-p.retained_amount_cents)) filter(where p.status='refunded' and p.updated_at>=a and p.updated_at<b),0)::bigint refunds,
 coalesce(sum(p.amount_cents) filter(where p.provider='mercado_pago' and p.provider_approved_at>=a and p.provider_approved_at<b),0)::bigint electronic,
 coalesce(sum(coalesce(nullif(p.refund_amount_cents,0),p.amount_cents-p.retained_amount_cents)) filter(where p.provider='mercado_pago' and p.status='refunded' and p.updated_at>=a and p.updated_at<b),0)::bigint electronic_refunds,
 count(*) filter(where p.status='refund_pending')::integer refunds_pending
 from public.payments p where p.kind in ('ride','tip','cancellation_fee','trip_adjustment') and p.status in ('approved','refunded','refund_pending')
 and ((p.provider_approved_at>=a and p.provider_approved_at<b) or (p.status='refunded' and p.updated_at>=a and p.updated_at<b)) and (target is null or p.driver_id=target)),
 daily as(select g.day::date as day,coalesce(sum(f.collected_cents),0)::bigint collected_cents,coalesce(sum(f.commission_base_cents),0)::bigint commission_cents,coalesce(sum(f.driver_net_cents),0)::bigint driver_net_cents,count(f.id)::integer trips
 from generate_series((meta->>'starts_on')::date::timestamp,((meta->>'ends_on')::date-1)::timestamp,interval '1 day') g(day) left join facts f on f.day=g.day::date group by g.day),
 drivers as(select f.driver_id,f.driver_name,count(*)::integer trips,sum(f.collected_cents)::bigint collected_cents,sum(f.commission_cents)::bigint commission_cents,sum(f.driver_net_cents)::bigint driver_net_cents,sum(f.isr_cents)::bigint isr_cents,sum(f.vat_cents)::bigint vat_cents,sum(f.promotion_pending_cents)::bigint promotion_pending_cents from facts f group by f.driver_id,f.driver_name)
 select jsonb_build_object('meta',meta||jsonb_build_object('generated_at',now(),'driver_id',target,'accounting_from',(select activated_at from public.finance_settings where id),'version','FIN-2026.09.1'),
 'summary',jsonb_build_object('trips',t.trips,'completed',t.completed,'cancelled',t.cancelled,'pending_trips',t.exceptions,'historical_trips',t.historical,
 'expected_cents',t.expected,'collected_cents',t.collected,'difference_cents',t.collected-t.expected,'cash_cents',t.cash,'card_cents',t.card,
 'fare_cents',t.fares,'discount_cents',t.discounts,'tip_cents',t.tips,'post_acceptance_adjustments_cents',pa.amount,'distance_fare_cents',t.distance,'time_fare_cents',t.time,'dynamic_fare_cents',t.dynamic,'base_other_fare_cents',t.other,'commission_cents',t.commission,'commission_base_cents',t.commission_base,'commission_vat_cents',t.commission_vat,'commission_refund_adjustment_cents',l.commission_refund_adjustment,'driver_net_cents',t.driver_net,
 'promotion_pending_cents',t.promo_pending,'promotions_credited_cents',l.promotions,'incentives_cents',l.incentives,'withdrawals_cents',l.withdrawals,'withdrawal_fees_cents',l.withdrawal_fees,
 'weekly_fees_cents',fe.gross,'expenses_cents',ex.net,'expenses_gross_cents',ex.gross,'expense_vat_credit_cents',ex.vat,'processor_fees_cents',ps.fees,
 'operating_result_cents',t.commission_base+round(l.commission_refund_adjustment/1.16)::bigint+fe.base+(l.withdrawal_fees-l.fee_vat-l.returned_fee_vat)-t.discounts-l.incentives-ps.fees-ex.net-st.amount,
 'isr_withheld_cents',l.isr,'vat_withheld_cents',l.vat,'state_contribution_cents',st.amount,
 'company_vat_estimate_cents',case when target is null then (private.finance_company_cash(a,b)->>'vat_cents')::bigint-ex.vat-coalesce((select sum(sign*gross_cents) from documents where kind='fiscal_adjustment' and category='vat_credit'),0) else null end
 )||jsonb_build_object('journal_opening_cents',coalesce((select sum(opening_cents) from wallets),0),'journal_movement_cents',coalesce((select sum(movement_cents) from wallets),0),'journal_closing_cents',coalesce((select sum(closing_cents) from wallets),0),
 'wallet_payable_cents',coalesce((select sum(greatest(0,closing_cents)) from wallets),0),'wallet_receivable_cents',coalesce((select sum(greatest(0,-closing_cents)) from wallets),0),
 'cash_commission_payments_cents',l.commission_payments+lt.commissions,'legacy_promotion_transfers_cents',lt.promotions,'opening_adjustments_cents',l.opening_adjustments,'adjustments_cents',l.adjustments,
 'flow_gross_cents',p.gross,'flow_refunds_cents',p.refunds,'flow_net_cents',p.gross-p.refunds,'refunds_pending',p.refunds_pending,
 'platform_cash_flow_cents',p.electronic-p.electronic_refunds+fe.gross+l.commission_payments+lt.commissions-lt.promotions-l.withdrawals-ps.fees-ex.gross-coalesce((select sum(sign*gross_cents) from documents where kind='tax_payment'),0)),
 'daily',coalesce((select jsonb_agg(to_jsonb(d) order by day) from daily d),'[]'),
 'drivers',coalesce((select jsonb_agg(to_jsonb(d) order by collected_cents desc) from drivers d),'[]'),
 'wallets',coalesce((select jsonb_agg(to_jsonb(w) order by driver_name) from wallets w),'[]'),
 'trips',coalesce((select jsonb_agg(to_jsonb(f) order by ended_at desc,id) from facts f),'[]'),
 'documents',coalesce((select jsonb_agg(to_jsonb(d) order by occurred_on desc,created_at desc) from documents d),'[]'),
 'tax_payments',coalesce((select jsonb_agg(jsonb_build_object('category',category,'amount_cents',amount)) from (select d.category,sum(case when d.reverses_id is null then d.gross_cents else -d.gross_cents end)::bigint amount from public.finance_documents d where d.kind='tax_payment' and target is null and ((meta->>'period'='week' and d.occurred_on>=(meta->>'starts_on')::date and d.occurred_on<(meta->>'ends_on')::date) or (meta->>'period'='month' and d.period_start=(meta->>'starts_on')::date)) group by d.category)x),'[]'),
 'tax_assessments',coalesce((select jsonb_agg(jsonb_build_object('category',category,'amount_cents',amount)) from (select category,gross_cents::bigint amount from public.finance_documents d where d.reverses_id is null and not exists(select 1 from public.finance_documents reversal where reversal.reverses_id=d.id) and d.kind='tax_assessment' and d.period_start=(meta->>'starts_on')::date and meta->>'period'='month' and target is null)x),'[]'),
 'journal_totals',coalesce((select jsonb_agg(jsonb_build_object('kind',effective_kind,'amount_cents',amount,'count',n)) from (select effective_kind,sum(amount_cents)::bigint amount,count(*) n from journals group by effective_kind)x),'[]'),
 'corporate',case when target is null then private.finance_resico(case when meta->>'period'='month' then a else date_trunc('month',timezone('America/Chihuahua',b-interval '1 microsecond')) at time zone 'America/Chihuahua' end,b) else '{}'::jsonb end,
 'closure_history',coalesce((select jsonb_agg(to_jsonb(x) order by revision desc) from (select id,revision,status,note,created_at,checksum from public.finance_closures where period=meta->>'period' and starts_on=(meta->>'starts_on')::date)x),'[]'))
 into result from trip_totals t cross join ledger_totals l cross join expenses ex cross join fees fe cross join processors ps cross join payment_flows p cross join legacy_transfers lt cross join state_flows st cross join post_acceptance pa;
 return result;
end $$;

-- The public dispatcher is unchanged; replacing the private report functions
-- affects only future live reports and future closure revisions.
