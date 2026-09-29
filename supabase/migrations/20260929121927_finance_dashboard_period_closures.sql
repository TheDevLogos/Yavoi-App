-- Financial reporting reads the existing trip and wallet journals. Closing a
-- period never charges a passenger, funds a wallet or initiates a transfer.
alter table public.finance_settings add column company_regime text not null default 'resico_pm' check(company_regime='resico_pm'), add column company_isr_bps integer not null default 3000 check(company_isr_bps=3000);
create table public.finance_documents (
 id uuid primary key default gen_random_uuid(), request_key uuid not null unique,
 kind text not null check(kind in ('expense','tax_payment','tax_assessment','fiscal_adjustment')),
 category text not null, gross_cents bigint not null check(gross_cents between 0 and 100000000),
 creditable_vat_cents bigint not null default 0 check(creditable_vat_cents>=0 and creditable_vat_cents<=gross_cents),
 deductible_cents bigint not null default 0 check(deductible_cents>=0 and deductible_cents<=gross_cents-creditable_vat_cents),
 occurred_on date not null, period_start date,
 reference text not null unique check(length(reference) between 5 and 160),
 note text not null check(length(note) between 5 and 1000),
 payment_id uuid references public.payments(id),
 actor_id uuid not null references public.profiles(id), created_at timestamptz not null default now(),
 reverses_id uuid unique references public.finance_documents(id),
 check(kind='expense' or creditable_vat_cents=0),
 check(kind='expense' or period_start is not null)
);
create index finance_documents_date on public.finance_documents(occurred_on,kind);
create index finance_documents_payment on public.finance_documents(payment_id) where payment_id is not null;
create index finance_documents_actor on public.finance_documents(actor_id);
create table public.finance_closures (
 id uuid primary key default gen_random_uuid(), request_key uuid not null unique,
 period text not null check(period in ('week','month')), starts_on date not null, ends_on date not null,
 revision integer not null, status text not null check(status in ('closed','closed_with_exceptions')),
 report jsonb not null, checksum text not null,
 note text not null check(length(note) between 5 and 1000),
 actor_id uuid not null references public.profiles(id), created_at timestamptz not null default now(),
 unique(period,starts_on,revision), check(ends_on>starts_on)
);
create index finance_closures_actor on public.finance_closures(actor_id);
do $$ declare t text; begin foreach t in array array['finance_documents','finance_closures'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('create policy finance_rpc_only on public.%I for all to public using(false) with check(false)',t);
end loop; end $$;
create index trips_finance_period on public.trips((coalesce(completed_at,cancelled_at,created_at)),driver_id) where status in ('completed','cancelled');
create index payments_finance_approved on public.payments(provider_approved_at) where provider_approved_at is not null;
create index wallet_finance_date on public.driver_wallet_entries(created_at);

create function private.finance_period(payload jsonb) returns jsonb language plpgsql stable set search_path='' as $$
declare p text:=coalesce(payload->>'period','week'); anchor date:=coalesce(nullif(payload->>'anchor','')::date,timezone('America/Chihuahua',now())::date); a date; b date;
begin
 if p not in ('week','month') then raise exception 'Selecciona semana o mes.'; end if;
 a:=date_trunc(p,anchor::timestamp)::date;
 b:=case when p='week' then a+7 else (a+interval '1 month')::date end;
 return jsonb_build_object('period',p,'starts_on',a,'ends_on',b,'timezone','America/Chihuahua',
 'can_close',b::timestamp at time zone 'America/Chihuahua'<=now());
end $$;

-- One row per terminal trip; lateral aggregation prevents multiplying fares by
-- payment/tip/journal joins. Historical fiscal rates are never invented.
create function private.finance_trip_facts(a timestamptz,b timestamptz,target uuid default null)
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
 case when t.status='completed' then greatest(0,t.total_cents) else t.cancellation_fee_cents end::bigint expected,
 case when t.status='completed' then t.reward_discount_cents else 0 end::bigint discount,
 case when t.payment_status='refunded' and t.status='completed' then 0 when t.status='completed' then t.commission_cents else t.cancellation_commission_cents end::bigint commission) x
 left join lateral (select
 sum(case when pay.status in ('approved','refund_pending') then pay.amount_cents when pay.status='refunded' then pay.retained_amount_cents else 0 end)::bigint collected,
 sum(case when pay.kind='tip' and pay.status='approved' then pay.amount_cents else 0 end)::bigint extra_tip,
 bool_or(pay.status in ('created','pending','in_process','refund_pending')) pending,
 bool_or(pay.kind='ride' and pay.status='refunded' and pay.retained_amount_cents=0) fully_refunded
 from public.payments pay where pay.trip_id=t.id and pay.kind in ('ride','tip','cancellation_fee')) p on true
 left join lateral (select
 -coalesce(sum(e.amount_cents) filter(where e.kind='isr' or (e.kind='refund' and e.detail->>'reversed_kind'='isr')),0)::bigint isr,
 -coalesce(sum(e.amount_cents) filter(where e.kind='vat' or (e.kind='refund' and e.detail->>'reversed_kind'='vat')),0)::bigint vat,
 coalesce(sum(e.amount_cents) filter(where e.kind='promotion_credit'),0)::bigint promo
 from public.driver_wallet_entries e where e.trip_id=t.id) journal on true
 cross join lateral(select journal.isr,journal.vat,journal.promo+case when t.financial_terms='{}' and reimb.status='paid' then t.reward_discount_cents else 0 end::bigint promo) j
 where t.status in ('completed','cancelled') and coalesce(t.completed_at,t.cancelled_at,t.created_at)>=a and coalesce(t.completed_at,t.cancelled_at,t.created_at)<b
 and (target is null or t.driver_id=target)
$$;


-- RESICO for a Mexican legal entity: cash income, documented deductions and
-- cumulative 30% ISR (LISR 207-211). Driver retentions are separate liabilities.
create function private.finance_company_cash(a timestamptz,b timestamptz) returns jsonb language sql stable security definer set search_path='' as $$
 with amounts as (
 select e.created_at as event_at, -e.amount_cents gross from public.driver_wallet_entries e where e.kind in ('commission','withdrawal_fee')
 union all select e.created_at, -e.amount_cents from public.driver_wallet_entries e where e.kind='refund' and e.detail->>'reversed_kind'='commission'
 union all select e.created_at,-e.amount_cents from public.driver_wallet_entries e where e.kind='withdrawal_fee_return'
 union all select e.created_at,e.amount_cents from public.driver_wallet_entries e where e.kind='commission_payment'
 union all select coalesce(w.verified_at,w.updated_at),w.amount_cents from public.weekly_fees w where w.status='paid'
 union all select coalesce(c.verified_at,c.updated_at),c.commission_due_cents from public.driver_commission_settlements c where c.status='paid'
 union all select d.occurred_on::timestamp at time zone 'America/Chihuahua',case when d.reverses_id is null then d.gross_cents else -d.gross_cents end from public.finance_documents d where d.kind='fiscal_adjustment' and d.category='cash_commission_offset'
 ) select jsonb_build_object('gross_cents',coalesce(sum(gross),0),'base_cents',coalesce(sum(round(gross/1.16)),0),'vat_cents',coalesce(sum(gross-round(gross/1.16)),0)) from amounts where event_at>=a and event_at<b
$$;
create function private.finance_resico(a timestamptz,b timestamptz) returns jsonb language plpgsql stable security definer set search_path='' as $$
 declare y timestamptz:=date_trunc('year',timezone('America/Chihuahua',a)) at time zone 'America/Chihuahua'; m date:=date_trunc('month',timezone('America/Chihuahua',a))::date;
 incomes jsonb:=private.finance_company_cash(y,b); monthly jsonb:=private.finance_company_cash(a,b); deductions bigint; extra bigint; ptu bigint; losses bigint; credits bigint; previous bigint; base bigint; accrued bigint; due bigint; reconciled boolean;
 begin
 select coalesce(sum(case when d.kind in ('expense','tax_payment') then d.deductible_cents when d.kind='fiscal_adjustment' and d.category='other_deductions' then d.gross_cents else 0 end*(case when d.reverses_id is null then 1 else -1 end)),0),
 coalesce(sum(d.gross_cents*(case when d.reverses_id is null then 1 else -1 end)) filter(where d.kind='fiscal_adjustment' and d.category='income_extra'),0),
 coalesce(sum(d.gross_cents*(case when d.reverses_id is null then 1 else -1 end)) filter(where d.kind='fiscal_adjustment' and d.category='ptu'),0),
 coalesce(sum(d.gross_cents*(case when d.reverses_id is null then 1 else -1 end)) filter(where d.kind='fiscal_adjustment' and d.category='losses'),0),
 coalesce(sum(d.gross_cents*(case when d.reverses_id is null then 1 else -1 end)) filter(where d.kind='fiscal_adjustment' and d.category='isr_credit'),0)
 into deductions,extra,ptu,losses,credits from public.finance_documents d where d.occurred_on>=timezone('America/Chihuahua',y)::date and d.occurred_on<timezone('America/Chihuahua',b)::date;
 select coalesce(sum(gross_cents*(case when reverses_id is null then 1 else -1 end)),0) into previous from public.finance_documents where kind='tax_payment' and category='company_isr' and period_start>=timezone('America/Chihuahua',y)::date and period_start<m and occurred_on<timezone('America/Chihuahua',b)::date;
 select exists(select 1 from public.finance_documents d where d.kind='fiscal_adjustment' and d.category='opening_certified' and d.period_start=timezone('America/Chihuahua',y)::date and d.reverses_id is null and not exists(select 1 from public.finance_documents r where r.reverses_id=d.id)) into reconciled;
 base:=greatest(0,(incomes->>'base_cents')::bigint+extra-deductions-ptu-losses);accrued:=round(base*3000/10000.0);due:=greatest(0,accrued-previous-credits);
 return jsonb_build_object('regime','S.A.S. / RESICO persona moral','rate_bps',3000,'year_start',timezone('America/Chihuahua',y)::date,'month',m,
 'income_ytd_cents',(incomes->>'base_cents')::bigint+extra,'deductions_ytd_cents',deductions,'ptu_cents',ptu,'losses_cents',losses,'credits_cents',credits,'previous_payments_cents',previous,
 'taxable_base_ytd_cents',base,'isr_accrued_cents',accrued,'isr_due_cents',due,'cash_income_period_cents',(monthly->>'base_cents')::bigint,'output_vat_period_cents',(monthly->>'vat_cents')::bigint,
 'opening_reconciled',reconciled,'basis','Estimación con movimientos registrados. Conciliar comisiones compensadas, CFDI, deducciones y saldos del ejercicio.');
 end $$;

create function private.finance_report_v1(payload jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 (case when pay.provider_approved_at>=a and pay.provider_approved_at<b then round(greatest(0,pay.amount_cents-t.tip_cents)*150/10000.0) else 0 end)
 -(case when pay.status='refunded' and pay.updated_at>=a and pay.updated_at<b then round(greatest(0,coalesce(nullif(pay.refund_amount_cents,0),pay.amount_cents-pay.retained_amount_cents)-case when pay.retained_amount_cents=0 then t.tip_cents else 0 end)*150/10000.0) else 0 end)),0)::bigint amount
 from public.payments pay join public.trips t on t.id=pay.trip_id where t.status='completed' and pay.kind='ride' and pay.status in ('approved','refund_pending','refunded') and (target is null or pay.driver_id=target) and ((pay.provider_approved_at>=a and pay.provider_approved_at<b) or (pay.status='refunded' and pay.updated_at>=a and pay.updated_at<b))),
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
 from public.payments p where p.kind in ('ride','tip','cancellation_fee') and p.status in ('approved','refunded','refund_pending')
 and ((p.provider_approved_at>=a and p.provider_approved_at<b) or (p.status='refunded' and p.updated_at>=a and p.updated_at<b)) and (target is null or p.driver_id=target)),
 daily as(select g.day::date as day,coalesce(sum(f.collected_cents),0)::bigint collected_cents,coalesce(sum(f.commission_base_cents),0)::bigint commission_cents,coalesce(sum(f.driver_net_cents),0)::bigint driver_net_cents,count(f.id)::integer trips
 from generate_series((meta->>'starts_on')::date::timestamp,((meta->>'ends_on')::date-1)::timestamp,interval '1 day') g(day) left join facts f on f.day=g.day::date group by g.day),
 drivers as(select f.driver_id,f.driver_name,count(*)::integer trips,sum(f.collected_cents)::bigint collected_cents,sum(f.commission_cents)::bigint commission_cents,sum(f.driver_net_cents)::bigint driver_net_cents,sum(f.isr_cents)::bigint isr_cents,sum(f.vat_cents)::bigint vat_cents,sum(f.promotion_pending_cents)::bigint promotion_pending_cents from facts f group by f.driver_id,f.driver_name)
 select jsonb_build_object('meta',meta||jsonb_build_object('generated_at',now(),'driver_id',target,'accounting_from',(select activated_at from public.finance_settings where id),'version','FIN-2026.09.1'),
 'summary',jsonb_build_object('trips',t.trips,'completed',t.completed,'cancelled',t.cancelled,'pending_trips',t.exceptions,'historical_trips',t.historical,
 'expected_cents',t.expected,'collected_cents',t.collected,'difference_cents',t.collected-t.expected,'cash_cents',t.cash,'card_cents',t.card,
 'fare_cents',t.fares,'discount_cents',t.discounts,'tip_cents',t.tips,'distance_fare_cents',t.distance,'time_fare_cents',t.time,'dynamic_fare_cents',t.dynamic,'base_other_fare_cents',t.other,'commission_cents',t.commission,'commission_base_cents',t.commission_base,'commission_vat_cents',t.commission_vat,'commission_refund_adjustment_cents',l.commission_refund_adjustment,'driver_net_cents',t.driver_net,
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
 into result from trip_totals t cross join ledger_totals l cross join expenses ex cross join fees fe cross join processors ps cross join payment_flows p cross join legacy_transfers lt cross join state_flows st;
 return result;
end $$;

create function private.finance_document_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.finance_documents; old public.finance_documents; k text:=payload->>'kind'; category_value text:=payload->>'category'; gross bigint:=(payload->>'gross_cents')::bigint; vat bigint:=coalesce((payload->>'creditable_vat_cents')::bigint,0); deduction bigint:=coalesce((payload->>'deductible_cents')::bigint,0); key_value uuid:=(payload->>'request_key')::uuid;
begin
 perform private.finance_admin();
 if key_value is null then raise exception 'Falta la clave de registro.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('finance-document:'||key_value::text,0));
 select * into d from public.finance_documents where request_key=key_value; if found then return to_jsonb(d); end if;
 if payload->>'reverses_id' is not null then
 select * into old from public.finance_documents where id=(payload->>'reverses_id')::uuid for update;
 if not found or old.reverses_id is not null or exists(select 1 from public.finance_documents where reverses_id=old.id) then raise exception 'El registro no existe o ya está corregido.'; end if;
 k:=old.kind;category_value:=old.category;gross:=old.gross_cents;vat:=old.creditable_vat_cents;deduction:=old.deductible_cents;
 end if;
 if k is null or k not in ('expense','tax_payment','tax_assessment','fiscal_adjustment') or key_value is null or gross is null or gross not between 0 and 100000000 or vat<0 or vat>gross-round(gross/1.16) or (k<>'expense' and vat<>0) or deduction<0 or deduction>gross-vat then raise exception 'Revisa el importe y el IVA acreditable.'; end if;
 if deduction>0 and not(k='expense' or (k='tax_payment' and category_value='state_contribution')) then raise exception 'La deducción debe corresponder a un gasto validado o a una aportación estatal pagada.'; end if;
 if (k='expense' and category_value not in ('operations','marketing','processing_fee','insurance','technology','other')) or (k in ('tax_payment','tax_assessment') and category_value not in ('isr_withheld','vat_withheld','state_contribution','company_vat','company_isr')) or (k='fiscal_adjustment' and category_value not in ('income_extra','cash_commission_offset','other_deductions','ptu','losses','isr_credit','vat_credit','opening_certified')) or category_value is null then raise exception 'Concepto inválido.'; end if;
 if category_value='opening_certified' and (gross<>0 or extract(month from (payload->>'period_start')::date)<>1) then raise exception 'Certifica los saldos del ejercicio con importe cero y periodo de enero.'; end if;
 if k='fiscal_adjustment' and category_value in ('opening_certified','losses') and old.id is null and exists(select 1 from public.finance_documents a where a.kind=k and a.category=category_value and date_trunc('year',a.period_start::timestamp)=date_trunc('year',(payload->>'period_start')::date::timestamp) and a.reverses_id is null and not exists(select 1 from public.finance_documents r where r.reverses_id=a.id)) then raise exception 'Ya hay un saldo fiscal del ejercicio registrado. Corrígelo antes de registrar otro.'; end if;
 if k='tax_assessment' and old.id is null and exists(select 1 from public.finance_documents a where a.kind=k and a.category=category_value and a.period_start=date_trunc('month',(payload->>'period_start')::date::timestamp)::date and a.reverses_id is null and not exists(select 1 from public.finance_documents r where r.reverses_id=a.id)) then raise exception 'Ya existe una determinación vigente. Corrígela antes de registrar otra.'; end if;
 if (payload->>'occurred_on')::date>timezone('America/Chihuahua',now())::date then raise exception 'Registra únicamente movimientos ya confirmados.'; end if;
 if (vat>0 or deduction>0 or k in ('fiscal_adjustment','tax_assessment')) and coalesce((payload->>'fiscal_validated')::boolean,false)<>true then raise exception 'Valida el comprobante fiscal y su acreditamiento antes de registrar IVA.'; end if;
 insert into public.finance_documents(request_key,kind,category,gross_cents,creditable_vat_cents,deductible_cents,occurred_on,period_start,reference,note,payment_id,actor_id,reverses_id)
 values(key_value,k,category_value,gross,vat,deduction,(payload->>'occurred_on')::date,case when old.id is not null then old.period_start else date_trunc('month',nullif(payload->>'period_start','')::date::timestamp)::date end,trim(payload->>'reference'),trim(payload->>'note'),case when old.id is not null then old.payment_id else nullif(payload->>'payment_id','')::uuid end,auth.uid(),old.id) returning * into d;
 insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'finance_document_recorded',d.id,to_jsonb(d)-'actor_id');
 return to_jsonb(d);
end $$;

create function private.finance_close_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb; c public.finance_closures; m jsonb; exceptions integer; n integer;
begin
 perform private.finance_admin();
 select * into c from public.finance_closures where request_key=(payload->>'request_key')::uuid; if found then return to_jsonb(c)-'report'; end if;
 if nullif(payload->>'driver_id','') is not null then raise exception 'El cierre comprende a todos los conductores.'; end if;
 m:=private.finance_period(payload);
 if not (m->>'can_close')::boolean then raise exception 'El periodo sigue abierto. Puedes consultar el avance y cerrar cuando termine.'; end if;
 if length(trim(coalesce(payload->>'note','')))<5 or nullif(payload->>'request_key','') is null then raise exception 'Registra una nota de cierre.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('finance-close:'||(m->>'period')||':'||(m->>'starts_on'),0));
 select * into c from public.finance_closures where request_key=(payload->>'request_key')::uuid; if found then return to_jsonb(c)-'report'; end if;
 r:=private.finance_report_v1(payload);
 exceptions:=coalesce((r->'summary'->>'pending_trips')::integer,0)+coalesce((r->'summary'->>'historical_trips')::integer,0)+coalesce((r->'summary'->>'refunds_pending')::integer,0)+case when coalesce((r->'corporate'->>'opening_reconciled')::boolean,false) then 0 else 1 end+case when coalesce((r->'summary'->>'promotion_pending_cents')::bigint,0)>0 then 1 else 0 end;
 if exceptions>0 and coalesce((payload->>'accept_exceptions')::boolean,false)<>true then raise exception 'Hay partidas pendientes o históricas. Revisa las diferencias y confirma un cierre con observaciones.'; end if;
 select coalesce(max(revision),0)+1 into n from public.finance_closures where period=m->>'period' and starts_on=(m->>'starts_on')::date;
 insert into public.finance_closures(request_key,period,starts_on,ends_on,revision,status,report,checksum,note,actor_id)
 values((payload->>'request_key')::uuid,m->>'period',(m->>'starts_on')::date,(m->>'ends_on')::date,n,case when exceptions>0 then 'closed_with_exceptions' else 'closed' end,r,md5(r::text),trim(payload->>'note'),auth.uid()) returning * into c;
 insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'finance_period_closed',c.id,jsonb_build_object('period',c.period,'starts_on',c.starts_on,'revision',n,'checksum',c.checksum,'note',c.note));
 return to_jsonb(c)-'report';
end $$;
create function private.finance_closed_report_v1(payload jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.finance_closures; begin
 perform private.finance_admin();select * into c from public.finance_closures where id=(payload->>'closure_id')::uuid;
 if not found then raise exception 'Cierre no encontrado.'; end if;
 return c.report||jsonb_build_object('saved_closure',to_jsonb(c)-'report');
end $$;
revoke all on function private.finance_company_cash(timestamptz,timestamptz),private.finance_resico(timestamptz,timestamptz),private.finance_period(jsonb),private.finance_trip_facts(timestamptz,timestamptz,uuid),private.finance_report_v1(jsonb),private.finance_document_v1(jsonb),private.finance_close_v1(jsonb),private.finance_closed_report_v1(jsonb) from public,anon,authenticated;
grant execute on function private.finance_report_v1(jsonb),private.finance_document_v1(jsonb),private.finance_close_v1(jsonb),private.finance_closed_report_v1(jsonb) to authenticated;
alter function public.yavoi(text,jsonb) rename to yavoi_before_finance_reporting;
revoke all on function public.yavoi_before_finance_reporting(text,jsonb) from public,anon;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$ begin
 return case command when 'finance_report' then private.finance_report_v1(payload) when 'finance_document' then private.finance_document_v1(payload)
 when 'finance_close' then private.finance_close_v1(payload) when 'finance_closed_report' then private.finance_closed_report_v1(payload) else public.yavoi_before_finance_reporting(command,payload) end;
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;grant execute on function public.yavoi(text,jsonb) to authenticated;
