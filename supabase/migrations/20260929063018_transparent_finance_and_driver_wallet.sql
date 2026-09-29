-- Versioned, integer-cent financial accounting. Existing journeys are not
-- retroactively taxed or made withdrawable without reconciliation.
create table public.finance_settings (
 id boolean primary key default true check(id), version text not null default 'MX-CHIH-2026.09',
 activated_at timestamptz not null default now(), vat_bps integer not null default 1600 check(vat_bps=1600),
 state_bps integer not null default 150 check(state_bps=150),
 dynamic_enabled boolean not null default false, dynamic_max_bps integer not null default 15000 check(dynamic_max_bps between 10000 and 20000),
 level_discounts jsonb not null default '{"Activo":0,"Destacado":0,"Élite":0,"Referente":0}',
 payouts_enabled boolean not null default true, updated_at timestamptz not null default now()
);
insert into public.finance_settings(id) values(true);
create table public.driver_fiscal_profiles (
 driver_id uuid primary key references public.drivers(id), entity text not null default 'individual' check(entity in ('individual','company')),
 rfc text not null default '', rfc_provided boolean not null default false,
 verified_by uuid references public.profiles(id), verified_at timestamptz,
 payout_kind text not null default 'bank' check(payout_kind in ('mercado_pago','bank')),
 payout_destination text not null default '', payout_holder text not null default '', payout_verified_at timestamptz,
 weekly_auto boolean not null default false, updated_at timestamptz not null default now()
);
create table public.driver_wallet_entries (
 id uuid primary key default gen_random_uuid(), driver_id uuid not null references public.drivers(id),
 trip_id uuid references public.trips(id), payment_id uuid references public.payments(id),
 entry_key text not null unique, kind text not null, amount_cents bigint not null,
 detail jsonb not null default '{}', created_at timestamptz not null default now()
);
create index driver_wallet_entries_driver_date on public.driver_wallet_entries(driver_id,created_at);
create index driver_wallet_entries_trip on public.driver_wallet_entries(trip_id) where trip_id is not null;
create index driver_wallet_entries_payment on public.driver_wallet_entries(payment_id) where payment_id is not null;
create table public.driver_withdrawals (
 id uuid primary key default gen_random_uuid(), driver_id uuid not null references public.drivers(id),
 request_key uuid not null, mode text not null check(mode in ('daily','weekly')),
 gross_cents bigint not null check(gross_cents>0), fee_cents bigint not null check(fee_cents>=0),
 fee_vat_cents bigint not null check(fee_vat_cents>=0), net_cents bigint not null check(net_cents>0),
 status text not null default 'requested' check(status in ('requested','processing','paid','rejected')),
 destination jsonb not null, scheduled_for timestamptz not null default now(),
 transfer_reference text, reviewed_by uuid references public.profiles(id), note text not null default '',
 created_at timestamptz not null default now(), paid_at timestamptz,
 unique(driver_id,request_key), check(gross_cents=fee_cents+net_cents)
);
create index driver_fiscal_profiles_verified_by on public.driver_fiscal_profiles(verified_by) where verified_by is not null;
create index driver_withdrawals_reviewed_by on public.driver_withdrawals(reviewed_by) where reviewed_by is not null;
create index driver_withdrawals_driver_date on public.driver_withdrawals(driver_id,created_at);
create index driver_withdrawals_status on public.driver_withdrawals(status,scheduled_for);
create unique index driver_withdrawals_reference on public.driver_withdrawals(transfer_reference) where status='paid';
do $$ declare tab text; begin foreach tab in array array['finance_settings','driver_fiscal_profiles','driver_wallet_entries','driver_withdrawals'] loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('revoke all on public.%I from public,anon,authenticated',tab);
 execute format('create policy finance_rpc_only on public.%I for all to public using (false) with check (false)',tab);
 end loop; end $$;
alter table public.payments add column funds_available_at timestamptz;
alter table public.quotes add column financial_terms jsonb not null default '{}';
alter table public.trips add column financial_terms jsonb not null default '{}', add column financial_breakdown jsonb not null default '{}';

create function private.finance_admin() returns void language plpgsql security definer set search_path='' as $$ begin
 if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
 raise exception 'Operaciones y verificación en dos pasos requeridas.' using errcode='42501'; end if;
end $$;
create function private.finance_post(d uuid,t uuid,p uuid,k text,kind_value text,cents bigint,extra jsonb default '{}') returns void
language sql security definer set search_path='' as $$
 insert into public.driver_wallet_entries(driver_id,trip_id,payment_id,entry_key,kind,amount_cents,detail)
 select d,t,p,k,kind_value,cents,extra where cents<>0 on conflict(entry_key) do nothing
$$;
create function private.finance_split(gross bigint,tip bigint,commission bigint,electronic boolean,terms jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare base bigint:=round(gross/1.16); vat bigint:=gross-base; cb bigint:=round(commission/1.16);
 isr_rate integer:=case when coalesce((terms->>'rfc_provided')::boolean,false) then case when terms->>'entity'='company' then 250 else 210 end else 2000 end;
 isr bigint:=case when electronic then round((base+tip)*isr_rate/10000.0) else 0 end;
 withheld bigint:=case when not electronic then 0 when coalesce((terms->>'rfc_provided')::boolean,false) then round(vat/2.0) else vat end;
begin
 return jsonb_build_object('taxable_base_cents',base,'fare_vat_cents',vat,'isr_bps',isr_rate,
 'isr_withheld_cents',isr,'vat_withheld_cents',withheld,'commission_cents',commission,
 'commission_base_cents',cb,'commission_vat_cents',commission-cb,'tip_cents',tip,
 'net_cents',gross+tip-commission-isr-withheld,'cash_tax_responsibility',not electronic);
end $$;

create function private.finance_quote_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; q public.quotes; settings public.finance_settings; mult integer:=10000; demand integer; supply integer; extra integer:=0; parts jsonb;
begin
 result:=private.quote_v5(payload); select * into q from public.quotes where id=(result->>'id')::uuid;
 select * into settings from public.finance_settings where id;
 if settings.dynamic_enabled then
 select count(*) into demand from public.trips where status='requested' and driver_id is null;
 select count(*) into supply from public.drivers d join public.driver_presence dp on dp.driver_id=d.id where d.online and d.approved and d.account_active and dp.heartbeat_at>now()-interval '1 minute';
 mult:=least(settings.dynamic_max_bps,case when demand>greatest(supply,1)*2 then 15000 when demand>greatest(supply,1) then 12500 else 10000 end);
 extra:=round(q.fare_cents*(mult-10000)/10000.0);
 end if;
 parts:=jsonb_build_object('version',settings.version,'vat_included',true,'vat_bps',1600,'state_bps',150,
 'base_cents',q.fare_cents-q.distance_charge_cents-q.time_charge_cents-q.minimum_adjustment_cents-q.zone_surcharge_cents-q.accessibility_surcharge_cents-q.pickup_surcharge_cents,
 'distance_cents',q.distance_charge_cents,'time_cents',q.time_charge_cents,'minimum_cents',q.minimum_adjustment_cents,
 'zone_cents',q.zone_surcharge_cents,'accessibility_cents',q.accessibility_surcharge_cents,'pickup_cents',q.pickup_surcharge_cents,
 'dynamic_bps',mult,'dynamic_cents',extra,'tolls_cents',0,'waiting_cents',0,'price_mode','upfront',
 'level_discounts',settings.level_discounts);
 update public.quotes set fare_cents=fare_cents+extra,financial_terms=parts where id=q.id returning * into q;
 return to_jsonb(q)||jsonb_build_object('fare_base_without_vat_cents',round(q.fare_cents/1.16),'fare_vat_cents',q.fare_cents-round(q.fare_cents/1.16));
end $$;

create function private.finance_snapshot_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare f public.driver_fiscal_profiles; terms jsonb; level_value text; discount integer:=0; original integer; c integer; gross bigint; tip bigint; split jsonb; promo_split jsonb;
begin
 if tg_op='INSERT' then select financial_terms into terms from public.quotes where id=new.quote_id; new.financial_terms:=coalesce(terms,'{}'); end if;
 if new.financial_terms='{}' then return new; end if;
 if new.driver_id is not null and (tg_op='INSERT' or old.driver_id is distinct from new.driver_id) then
 select * into f from public.driver_fiscal_profiles where driver_id=new.driver_id;
 level_value:=private.reward_metrics(new.driver_id)->>'level';
 discount:=coalesce((new.financial_terms->'level_discounts'->>level_value)::integer,0);
 original:=private.driver_commission_bps(new.driver_id,new.payment_method);
 select billing_mode into new.billing_mode from public.drivers where id=new.driver_id;
 new.commission_bps_applied:=greatest(0,original-discount);
 new.commission_cents:=round(new.fare_cents*new.commission_bps_applied/10000.0);
 new.financial_terms:=new.financial_terms||jsonb_build_object('entity',coalesce(f.entity,'individual'),'rfc_provided',coalesce(f.rfc_provided,false),
 'fiscal_locked_at',now(),'level',level_value,'level_discount_bps',discount,'original_commission_bps',original,'commission_bps',new.commission_bps_applied);
 end if;
 if new.driver_id is null then return new; end if;
 gross:=case when new.status='cancelled' then new.cancellation_fee_cents else greatest(0,new.fare_cents-new.reward_discount_cents) end;
 tip:=case when new.status='cancelled' then 0 else new.tip_cents end;
 c:=case when new.status='cancelled' then new.cancellation_commission_cents else new.commission_cents end;
 split:=private.finance_split(gross,tip,c,new.payment_method='card',new.financial_terms);
 promo_split:=private.finance_split(case when new.status='cancelled' then 0 else new.reward_discount_cents end,0,0,true,new.financial_terms);
 new.financial_breakdown:=split||jsonb_build_object('version',new.financial_terms->>'version','fare_cents',new.fare_cents,'passenger_total_cents',gross+tip,
 'promotion_pending_cents',case when new.status='cancelled' then 0 else new.reward_discount_cents end,
 'contractual_net_cents',(split->>'net_cents')::bigint+(promo_split->>'net_cents')::bigint,
 'state_contribution_cents',round(gross*150/10000.0),'state_payer','Yavoi!', 'vat_included',true,
 'cash_commission_due_cents',case when new.payment_method='cash' then c else 0 end,'level',new.financial_terms->>'level');
 return new;
end $$;
create trigger finance_snapshot before insert or update on public.trips for each row execute function private.finance_snapshot_trigger();

create function private.finance_reconcile_trip(target uuid) returns void language plpgsql security definer set search_path='' as $$
declare t public.trips; p public.payments; s jsonb; gross bigint; tips bigint; fee bigint; key_value text; cancelled boolean; existing bigint;
begin
 select * into t from public.trips where id=target;
 if not found or t.driver_id is null or t.financial_terms='{}' or t.status not in ('completed','cancelled') then return; end if;
 -- The driver row is also the wallet mutex used for simultaneous withdrawals.
 perform 1 from public.drivers where id=t.driver_id for update;
 cancelled:=t.status='cancelled';
 if cancelled and t.cancellation_fee_cents=0 then return; end if;
 if t.payment_method='cash' then
 if cancelled and not exists(select 1 from public.payments where trip_id=t.id and kind='cancellation_fee' and status='approved') then return; end if;
 fee:=case when cancelled then t.cancellation_commission_cents else t.commission_cents end;
 perform private.finance_post(t.driver_id,t.id,null,'trip:'||t.id||':cash-commission','cash_commission',-fee);
 return;
 end if;
 select * into p from public.payments where trip_id=t.id and kind='ride' and provider='mercado_pago';
 if not found then return; end if;
 key_value:='trip:'||t.id;
 if p.status='refunded' and not cancelled then
 -- Reverse every settled entry once; tax adjustment remains traceable, not deleted.
 for s in select to_jsonb(e) from public.driver_wallet_entries e where e.trip_id=t.id and e.entry_key like key_value||':%' and e.kind not in ('refund','promotion_credit') loop
 perform private.finance_post(t.driver_id,t.id,p.id,'refund:'||(s->>'id'),'refund',-(s->>'amount_cents')::bigint,jsonb_build_object('reverses',s->>'id','reversed_kind',s->>'kind'));
 end loop; return;
 end if;
 if (not cancelled and p.status<>'approved') or (cancelled and p.status not in ('approved','refunded')) then return; end if;
 gross:=case when cancelled then least(t.cancellation_fee_cents,p.retained_amount_cents) else greatest(0,t.fare_cents-t.reward_discount_cents) end;
 tips:=case when cancelled then 0 else t.tip_cents end;
 fee:=case when cancelled then t.cancellation_commission_cents else t.commission_cents end;
 if cancelled and gross=0 then return; end if;
 s:=private.finance_split(gross,tips,fee,true,t.financial_terms)||jsonb_build_object('collected_at',p.provider_approved_at);
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':credit','card_credit',gross+tips,jsonb_build_object('collected_at',p.provider_approved_at));
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':commission','commission',-fee);
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':isr','isr',-(s->>'isr_withheld_cents')::bigint,s);
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':iva','vat',-(s->>'vat_withheld_cents')::bigint,s);
end $$;
create function private.finance_trip_journal_trigger() returns trigger language plpgsql security definer set search_path='' as $$ begin
 perform private.finance_reconcile_trip(new.id); return new; end $$;
create trigger finance_trip_journal after insert or update of status,payment_status on public.trips for each row execute function private.finance_trip_journal_trigger();
create function private.finance_payment_journal_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare t public.trips; s jsonb; gross bigint; k text;
begin
 if new.trip_id is not null then perform private.finance_reconcile_trip(new.trip_id); end if;
 if new.kind='tip' and new.provider='mercado_pago' and new.trip_id is not null then
 select * into t from public.trips where id=new.trip_id;
 if t.driver_id is not null and t.financial_terms<>'{}' and t.status='completed' then
 perform 1 from public.drivers where id=t.driver_id for update; k:='tip:'||new.id;
 if new.status='approved' then
 s:=private.finance_split(0,new.amount_cents,0,true,t.financial_terms)||jsonb_build_object('collected_at',new.provider_approved_at);
 perform private.finance_post(t.driver_id,t.id,new.id,k||':credit','card_tip',new.amount_cents);
 perform private.finance_post(t.driver_id,t.id,new.id,k||':isr','isr',-(s->>'isr_withheld_cents')::bigint,s);
 elsif new.status='refunded' then
 select coalesce(sum(amount_cents),0) into gross from public.driver_wallet_entries where entry_key like k||':%';
 perform private.finance_post(t.driver_id,t.id,new.id,k||':refund','refund',-gross);
 end if; end if;
 end if;
 return new;
end $$;
create trigger finance_payment_journal after insert or update of status on public.payments for each row execute function private.finance_payment_journal_trigger();

create function private.finance_profile_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); destination text:=trim(coalesce(payload->>'payout_destination','')); holder text:=trim(coalesce(payload->>'payout_holder','')); kind_value text:=payload->>'payout_kind'; f public.driver_fiscal_profiles;
begin
 if uid is null or not exists(select 1 from public.profiles where id=uid and role='driver' and not suspended) then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
 if kind_value not in ('mercado_pago','bank') or length(holder)<3 or length(holder)>160 or length(destination)>160 then raise exception 'Revisa la cuenta y el titular.'; end if;
 if (kind_value='mercado_pago' and destination !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') or (kind_value='bank' and destination !~ '^[0-9]{18}$') then raise exception 'Indica un correo de Mercado Pago o una CLABE de 18 dígitos.'; end if;
 if kind_value='bank' and mod((select sum(substr(destination,i,1)::int*(array[3,7,1])[(i-1)%3+1]) from generate_series(1,17) i),10)<>mod(10-substr(destination,18,1)::int,10) then raise exception 'La CLABE no pasa la validación.'; end if;
 perform 1 from public.drivers where id=uid for update;
 insert into public.driver_fiscal_profiles(driver_id,payout_kind,payout_destination,payout_holder,weekly_auto) values(uid,kind_value,destination,holder,coalesce((payload->>'weekly_auto')::boolean,false))
 on conflict(driver_id) do update set payout_kind=excluded.payout_kind,payout_destination=excluded.payout_destination,payout_holder=excluded.payout_holder,weekly_auto=excluded.weekly_auto,
 payout_verified_at=case when public.driver_fiscal_profiles.payout_destination=excluded.payout_destination and public.driver_fiscal_profiles.payout_holder=excluded.payout_holder and public.driver_fiscal_profiles.payout_kind=excluded.payout_kind then public.driver_fiscal_profiles.payout_verified_at else null end,updated_at=now() returning * into f;
 return jsonb_build_object('ok',true,'profile',to_jsonb(f));
end $$;
create function private.finance_verify_profile_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid:=(payload->>'driver_id')::uuid; rfc_value text:=upper(trim(coalesce(payload->>'rfc',''))); entity_value text:=payload->>'entity'; f public.driver_fiscal_profiles;
begin
 perform private.finance_admin();
 if entity_value not in ('individual','company') or length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Revisa el tipo fiscal y registra el motivo.'; end if;
 if rfc_value<>'' and (rfc_value !~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$' or length(rfc_value)<>case when entity_value='individual' then 13 else 12 end or rfc_value in ('XAXX010101000','XEXX010101000')) then raise exception 'RFC inválido; registra el RFC propio del conductor.'; end if;
 perform 1 from public.drivers where id=target for update;
 insert into public.driver_fiscal_profiles(driver_id,entity,rfc,rfc_provided,verified_by,verified_at) values(target,entity_value,rfc_value,rfc_value<>'',auth.uid(),now())
 on conflict(driver_id) do update set entity=excluded.entity,rfc=excluded.rfc,rfc_provided=excluded.rfc_provided,verified_by=excluded.verified_by,verified_at=now(),
 payout_verified_at=case when coalesce((payload->>'verify_destination')::boolean,false) and public.driver_fiscal_profiles.payout_destination<>'' then now() else public.driver_fiscal_profiles.payout_verified_at end,updated_at=now() returning * into f;
 insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'finance_profile_verified',target,jsonb_build_object('entity',entity_value,'rfc_provided',f.rfc_provided,'note',payload->>'note'));
 return jsonb_build_object('ok',true,'profile',to_jsonb(f));
end $$;

create function private.finance_wallet_data(target uuid,requested_week date default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare w date:=coalesce(requested_week,date_trunc('week',timezone('America/Chihuahua',now()))::date); balance bigint; reserved bigint; held bigint; days jsonb; history jsonb; pending bigint; cash bigint; earned bigint; net_week bigint; f public.driver_fiscal_profiles; cutoff timestamptz;
begin
 select activated_at into cutoff from public.finance_settings where id;
 select * into f from public.driver_fiscal_profiles where driver_id=target;
 select coalesce(sum(amount_cents),0) into balance from public.driver_wallet_entries where driver_id=target;
 select coalesce(sum(gross_cents),0) into reserved from public.driver_withdrawals where driver_id=target and status in ('requested','processing');
 select coalesce(sum(greatest(0,x.net)),0) into held from (select sum(e.amount_cents) net from public.driver_wallet_entries e join public.payments pay on pay.id=e.payment_id where e.driver_id=target and pay.status='approved' and (pay.funds_available_at is null or pay.funds_available_at>now()) group by pay.id) x;
 select coalesce(sum(reimbursement_cents),0) into pending from public.driver_promotion_reimbursements where driver_id=target and status in ('pending','overdue');
 select coalesce(sum(total_cents),0),coalesce(sum(case when financial_breakdown<>'{}' then (financial_breakdown->>'contractual_net_cents')::bigint else fare_cents-commission_cents+tip_cents end),0)
 into cash,earned from public.trips where driver_id=target and status='completed' and timezone('America/Chihuahua',completed_at)::date>=w and timezone('America/Chihuahua',completed_at)::date<w+7;
 select coalesce(sum(total_cents),0) into cash from public.trips where driver_id=target and status='completed' and payment_method='cash' and timezone('America/Chihuahua',completed_at)::date>=w and timezone('America/Chihuahua',completed_at)::date<w+7;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]') into days from (
 select day::date,coalesce((select sum(case when t.financial_breakdown<>'{}' then (t.financial_breakdown->>'contractual_net_cents')::bigint else t.fare_cents-t.commission_cents+t.tip_cents end) from public.trips t where t.driver_id=target and t.status='completed' and timezone('America/Chihuahua',t.completed_at)::date=day::date),0) + coalesce((select sum(e.amount_cents) from public.driver_wallet_entries e where e.driver_id=target and (e.kind in ('card_tip','incentive','refund') or e.entry_key like 'tip:%:isr' or e.entry_key like 'funding-isr:%' or e.entry_key like 'funding-vat:%') and timezone('America/Chihuahua',e.created_at)::date=day::date),0) net_cents,
 (select count(*) from public.trips t where t.driver_id=target and t.status='completed' and timezone('America/Chihuahua',t.completed_at)::date=day::date) trips
 from generate_series(w::timestamp,(w+6)::timestamp,interval '1 day') day) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into history from (select * from public.driver_wallet_entries where driver_id=target order by created_at desc limit 150) x;
 select coalesce(sum((day->>'net_cents')::bigint),0) into earned from jsonb_array_elements(days) day;
 return jsonb_build_object('week_start',w,'days',days,'week_net_cents',earned,'week_cash_cents',cash,
 'balance_cents',balance,'debt_cents',greatest(0,-balance),'reserved_cents',reserved,'held_cents',held,'available_cents',greatest(0,balance-reserved-held),
 'promotion_pending_cents',greatest(0,pending-(select coalesce(sum(amount_cents),0) from public.driver_wallet_entries where driver_id=target and kind='promotion_credit')),'entries',history,'profile',coalesce(to_jsonb(f),'{}'),
 'withdrawals',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select * from public.driver_withdrawals where driver_id=target order by created_at desc limit 50)x),'[]'),
 'accounting_from',cutoff,'payouts_enabled',(select payouts_enabled from public.finance_settings where id),
 'next_weekly_at',((date_trunc('week',timezone('America/Chihuahua',now()))::date+7)+time '07:00') at time zone 'America/Chihuahua');
end $$;
create function private.finance_wallet_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='driver' and not suspended) then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
 return private.finance_wallet_data(auth.uid(),nullif(payload->>'week_start','')::date);
end $$;

create function private.finance_withdraw_internal(target uuid,mode_value text,amount bigint,key_value uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare f public.driver_fiscal_profiles; result public.driver_withdrawals; bal bigint; reserved bigint; fee bigint; due timestamptz:=now(); local_time timestamp:=timezone('America/Chihuahua',now());
begin
 perform 1 from public.drivers where id=target for update;
 select * into result from public.driver_withdrawals where driver_id=target and request_key=key_value;
 if found then return to_jsonb(result); end if;
 if mode_value not in ('daily','weekly') then raise exception 'Modalidad de retiro inválida.'; end if;
 select * into f from public.driver_fiscal_profiles where driver_id=target;
 if not found or f.payout_verified_at is null then raise exception 'Registra tu cuenta y espera su validación por Operaciones.'; end if;
 if not (select payouts_enabled from public.finance_settings where id) then raise exception 'Los retiros están pendientes de habilitación por Operaciones.'; end if;
 select coalesce(sum(amount_cents),0) into bal from public.driver_wallet_entries where driver_id=target;
 select coalesce(sum(gross_cents),0) into reserved from public.driver_withdrawals where driver_id=target and status in ('requested','processing');
 bal:=bal-coalesce((private.finance_wallet_data(target)->>'held_cents')::bigint,0);
 if amount is null then amount:=bal-reserved; end if;
 if amount<100 or amount>bal-reserved then raise exception 'El importe supera tu saldo disponible o es menor de $1.00.'; end if;
 if mode_value='daily' and exists(select 1 from public.driver_withdrawals where driver_id=target and mode='daily' and status<>'rejected' and timezone('America/Chihuahua',created_at)::date=local_time::date) then raise exception 'Ya solicitaste tu retiro diario de hoy.'; end if;
 if mode_value='weekly' then
 due:=(date_trunc('week',local_time)+time '07:00') at time zone 'America/Chihuahua';
 if local_time::date<>date_trunc('week',local_time)::date or local_time::time<time '07:00' then due:=due+interval '7 days'; end if;
 if exists(select 1 from public.driver_withdrawals where driver_id=target and mode='weekly' and scheduled_for=due and status<>'rejected') then raise exception 'Ya hay un retiro semanal para este lunes.'; end if;
 end if;
 fee:=case when mode_value='daily' then round(amount*300/10000.0) else 0 end;
 insert into public.driver_withdrawals(driver_id,request_key,mode,gross_cents,fee_cents,fee_vat_cents,net_cents,destination,scheduled_for)
 values(target,key_value,mode_value,amount,fee,fee-round(fee/1.16),amount-fee,jsonb_build_object('kind',f.payout_kind,'destination',f.payout_destination,'holder',f.payout_holder),due) returning * into result;
 return to_jsonb(result);
end $$;
create function private.finance_withdraw_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='driver' and not suspended) then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
 return private.finance_withdraw_internal(auth.uid(),payload->>'mode',(payload->>'amount_cents')::bigint,(payload->>'request_key')::uuid);
end $$;
create function private.finance_review_withdrawal_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare item public.driver_withdrawals; target uuid; action_value text:=payload->>'status'; bal bigint; reserved bigint; reference_value text:=trim(coalesce(payload->>'reference',''));
begin
 perform private.finance_admin(); select driver_id into target from public.driver_withdrawals where id=(payload->>'withdrawal_id')::uuid;
 perform 1 from public.drivers where id=target for update;
 select * into item from public.driver_withdrawals where id=(payload->>'withdrawal_id')::uuid for update;
 if not found then raise exception 'Retiro no encontrado.'; end if;
 if item.status in ('paid','rejected') then raise exception 'Este retiro ya está cerrado.'; end if;
 if item.provider_body is not null then raise exception 'Este retiro está en transferencia automática; verifica el resultado con Mercado Pago antes de realizar otro pago.'; end if;
 if action_value not in ('processing','paid','rejected') or length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Revisa estado y nota de conciliación.'; end if;
 if action_value<>'rejected' and item.scheduled_for>now() then raise exception 'El retiro semanal se habilita el lunes a las 7:00 a.m.'; end if;
 select coalesce(sum(amount_cents),0) into bal from public.driver_wallet_entries where driver_id=target;
 select coalesce(sum(gross_cents),0) into reserved from public.driver_withdrawals where driver_id=target and status in ('requested','processing') and id<>item.id;
 bal:=bal-coalesce((private.finance_wallet_data(target)->>'held_cents')::bigint,0);
 if action_value<>'rejected' and item.gross_cents>bal-reserved then raise exception 'Saldo insuficiente tras ajustes o reembolsos. Revisa el retiro.'; end if;
 if action_value='paid' then
 if length(reference_value)<5 then raise exception 'Registra la referencia real de la transferencia confirmada.'; end if;
 perform private.finance_post(target,null,null,'withdraw:'||item.id||':net','withdrawal',-item.net_cents,jsonb_build_object('withdrawal_id',item.id,'reference',reference_value));
 perform private.finance_post(target,null,null,'withdraw:'||item.id||':fee','withdrawal_fee',-item.fee_cents,jsonb_build_object('withdrawal_id',item.id,'vat_cents',item.fee_vat_cents));
 end if;
 update public.driver_withdrawals set status=action_value,transfer_reference=case when action_value='paid' then reference_value else transfer_reference end,
 reviewed_by=auth.uid(),note=left(payload->>'note',1000),paid_at=case when action_value='paid' then now() end where id=item.id returning * into item;
 insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'wallet_withdrawal_reviewed',item.id,jsonb_build_object('status',action_value,'gross_cents',item.gross_cents,'reference',reference_value,'note',payload->>'note'));
 return to_jsonb(item);
end $$;

-- Operations posts only reconciled funding; a pending promotion or old ledger
-- number can never be spent merely because it appears on the dashboard.
create function private.finance_funding_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare fiscal public.driver_fiscal_profiles; target uuid:=(payload->>'driver_id')::uuid; amount bigint:=(payload->>'amount_cents')::bigint; key_value uuid:=(payload->>'request_key')::uuid; kind_value text:=payload->>'kind'; note_value text:=trim(coalesce(payload->>'note','')); reference_value text:=trim(coalesce(payload->>'reference','')); t public.trips; s jsonb; expected bigint;
begin
 perform private.finance_admin();
 if amount<1 or amount>100000000 or kind_value not in ('opening','promotion','incentive','commission_payment','adjustment') or length(note_value)<5 or length(reference_value)<5 or key_value is null then raise exception 'Indica importe, referencia comprobable y motivo.'; end if;
 perform 1 from public.drivers where id=target for update;
 if not found then raise exception 'Conductor no encontrado.'; end if;
 if kind_value='promotion' then
 select * into t from public.trips where id=(payload->>'trip_id')::uuid and driver_id=target and status='completed';
 if not found or t.financial_terms='{}' or t.reward_discount_cents<>amount then raise exception 'La promoción debe corresponder a un viaje y al importe pendiente exacto.'; end if;
 if exists(select 1 from public.driver_wallet_entries where entry_key='promotion:'||t.id) then raise exception 'Promoción ya abonada.'; end if;
 if exists(select 1 from public.driver_promotion_reimbursements where driver_id=target and week_start=date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date and status='paid') then raise exception 'La promoción ya se transfirió externamente.'; end if;
 s:=private.finance_split(amount,0,0,true,t.financial_terms);
 perform private.finance_post(target,t.id,null,'promotion:'||t.id,'promotion_credit',amount,jsonb_build_object('reference',reference_value,'note',note_value));
 perform private.finance_post(target,t.id,null,'promotion-isr:'||t.id,'isr',-(s->>'isr_withheld_cents')::bigint,s);
 perform private.finance_post(target,t.id,null,'promotion-vat:'||t.id,'vat',-(s->>'vat_withheld_cents')::bigint,s);
 else
 if kind_value='incentive' then
 select * into fiscal from public.driver_fiscal_profiles where driver_id=target;
 s:=private.finance_split(amount,0,0,true,jsonb_build_object('rfc_provided',coalesce(fiscal.rfc_provided,false),'entity',coalesce(fiscal.entity,'individual')));
 perform private.finance_post(target,null,null,'funding-isr:'||key_value,'isr',-(s->>'isr_withheld_cents')::bigint,s);
 perform private.finance_post(target,null,null,'funding-vat:'||key_value,'vat',-(s->>'vat_withheld_cents')::bigint,s);
 end if;
 perform private.finance_post(target,null,null,'funding:'||key_value,kind_value,amount,jsonb_build_object('reference',reference_value,'note',note_value));
 end if;
 insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'wallet_funding_reconciled',target,jsonb_build_object('kind',kind_value,'amount_cents',amount,'reference',reference_value,'note',note_value));
 return jsonb_build_object('ok',true);
end $$;

create function private.finance_settings_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare levels jsonb:=coalesce(payload->'level_discounts','{}'); v jsonb;
begin
 perform private.finance_admin();
 if length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Registra el motivo del cambio.'; end if;
 if coalesce((payload->>'dynamic_max_bps')::integer,15000) not between 10000 and 20000 or jsonb_typeof(levels)<>'object' then raise exception 'Configuración inválida.'; end if;
 for v in select value from jsonb_each(levels) loop if v::text::integer not between 0 and 5000 then raise exception 'Beneficio por nivel fuera de rango.'; end if; end loop;
 update public.finance_settings set dynamic_enabled=coalesce((payload->>'dynamic_enabled')::boolean,false),dynamic_max_bps=coalesce((payload->>'dynamic_max_bps')::integer,15000),level_discounts=levels,
 payouts_enabled=coalesce((payload->>'payouts_enabled')::boolean,false),updated_at=now() where id;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'finance_settings_changed',payload);
 return jsonb_build_object('ok',true);
end $$;
create function private.finance_operations_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare month_value date:=coalesce(nullif(payload->>'month','')::date,date_trunc('month',timezone('America/Chihuahua',now()))::date); result jsonb;
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Acceso de Operaciones requerido.' using errcode='42501'; end if;
 return jsonb_build_object('settings',(select to_jsonb(s) from public.finance_settings s where id),
 'drivers',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',p.full_name,'fiscal',coalesce(to_jsonb(f),'{}'),'wallet',private.finance_wallet_data(d.id))),'[]') from public.drivers d join public.profiles p on p.id=d.id left join public.driver_fiscal_profiles f on f.driver_id=d.id),
 'withdrawals',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select w.*,p.full_name driver_name from public.driver_withdrawals w join public.profiles p on p.id=w.driver_id order by w.created_at desc limit 100)x),'[]'),
 'month',month_value,
 'tax_summary',(select jsonb_build_object('isr_cents',coalesce(-sum(amount_cents) filter(where kind='isr' or (kind='refund' and detail->>'reversed_kind'='isr')),0),'vat_cents',coalesce(-sum(amount_cents) filter(where kind='vat' or (kind='refund' and detail->>'reversed_kind'='vat')),0)) from public.driver_wallet_entries where timezone('America/Chihuahua',coalesce(nullif(detail->>'collected_at','')::timestamptz,created_at))::date>=month_value and timezone('America/Chihuahua',coalesce(nullif(detail->>'collected_at','')::timestamptz,created_at))::date<month_value+interval '1 month'),
 'state_summary',(select coalesce(sum((financial_breakdown->>'state_contribution_cents')::bigint),0) from public.trips where status='completed' and payment_status not in ('refunded','refund_pending') and financial_breakdown<>'{}' and timezone('America/Chihuahua',completed_at)::date>=month_value and timezone('America/Chihuahua',completed_at)::date<month_value+interval '1 month'));
end $$;
create function private.finance_weekly_queue() returns integer language plpgsql security definer set search_path='' as $$
declare f public.driver_fiscal_profiles; amount bigint; count_value integer:=0;
begin
 if extract(isodow from timezone('America/Chihuahua',now()))<>1 or timezone('America/Chihuahua',now())::time<time '07:00' or not(select payouts_enabled from public.finance_settings where id) then return 0; end if;
 for f in select * from public.driver_fiscal_profiles where weekly_auto and payout_verified_at is not null loop
 perform 1 from public.drivers where id=f.driver_id for update;
 if exists(select 1 from public.driver_withdrawals where driver_id=f.driver_id and mode='weekly' and timezone('America/Chihuahua',scheduled_for)::date=timezone('America/Chihuahua',now())::date and status<>'rejected') then continue; end if;
 select coalesce(sum(amount_cents),0)-(select coalesce(sum(gross_cents),0) from public.driver_withdrawals where driver_id=f.driver_id and status in ('requested','processing')) into amount from public.driver_wallet_entries where driver_id=f.driver_id;
 amount:=amount-coalesce((private.finance_wallet_data(f.driver_id)->>'held_cents')::bigint,0);
 if amount>=100 then perform private.finance_withdraw_internal(f.driver_id,'weekly',amount,gen_random_uuid());count_value:=count_value+1;end if;
 end loop; return count_value;
end $$;

-- Wrappers enrich existing flows without replacing dispatch, cancellations,
-- cash confirmation, trip navigation or profile authorization.
create function private.finance_dashboard_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb:=private.dashboard_v18(payload); begin
 if exists(select 1 from public.profiles where id=auth.uid() and role='driver') then result:=result||jsonb_build_object('finance_wallet',private.finance_wallet_data(auth.uid())); end if;
 return result;
end $$;
create function private.finance_offers_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb:=private.offers_v10(payload); o jsonb; t public.trips; f public.driver_fiscal_profiles; terms jsonb; split jsonb; c integer; level_value text; reduction integer; output jsonb:='[]';
begin
 select * into f from public.driver_fiscal_profiles where driver_id=auth.uid();
 for o in select value from jsonb_array_elements(result) loop
 select * into t from public.trips where id=(o->>'id')::uuid;
 if t.financial_terms<>'{}' then
 terms:=t.financial_terms||jsonb_build_object('entity',coalesce(f.entity,'individual'),'rfc_provided',coalesce(f.rfc_provided,false));
 level_value:=private.reward_metrics(auth.uid())->>'level'; reduction:=coalesce((terms->'level_discounts'->>level_value)::integer,0);
 c:=round(t.fare_cents*greatest(0,private.driver_commission_bps(auth.uid(),t.payment_method)-reduction)/10000.0);
 split:=private.finance_split(greatest(0,t.fare_cents-t.reward_discount_cents),t.tip_cents,c,t.payment_method='card',terms);
 o:=o||jsonb_build_object('net_cents',(split->>'net_cents')::bigint+(private.finance_split(t.reward_discount_cents,0,0,true,terms)->>'net_cents')::bigint,'commission_cents',c,'financial_breakdown',split||jsonb_build_object('promotion_pending_cents',t.reward_discount_cents,'state_payer','Yavoi!','level',level_value));
 end if; output:=output||jsonb_build_array(o); end loop; return output;
end $$;

do $$ declare fn record; begin for fn in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname like 'finance_%' loop
 execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
 if fn.proname in ('finance_quote_v1','finance_profile_v1','finance_verify_profile_v1','finance_wallet_v1','finance_withdraw_v1','finance_review_withdrawal_v1','finance_funding_v1','finance_settings_v1','finance_operations_v1','finance_dashboard_v1','finance_offers_v1') then execute format('grant execute on function %s to authenticated',fn.signature); end if;
 end loop; end $$;
do $$ begin if exists(select 1 from pg_available_extensions where name='pg_cron') and not exists(select 1 from pg_extension where extname='pg_cron') then execute 'create extension pg_cron'; end if; end $$;
-- pg_cron is optional locally. Production installs one idempotent weekly job.
do $$ begin if exists(select 1 from pg_extension where extname='pg_cron') then
 if exists(select 1 from cron.job where jobname='yavoi-weekly-wallet') then perform cron.unschedule('yavoi-weekly-wallet'); end if;
 perform cron.schedule('yavoi-weekly-wallet','*/10 * * * *','select private.finance_weekly_queue()');
 end if; end $$;

create or replace function private.record_cash_commission_settlement() returns trigger
language plpgsql security definer set search_path='' as $$
declare start_day date;
begin
  if new.financial_terms='{}' and new.status='completed' and old.status is distinct from 'completed' and new.payment_method='cash'
    and new.billing_mode='commission' and new.commission_cents>0 then
    start_day:=date_trunc('week',timezone('America/Chihuahua',coalesce(new.completed_at,now())))::date;
    insert into public.driver_commission_settlements(
      driver_id,week_start,due_at,gross_cash_cents,commission_due_cents
    ) values(
      new.driver_id,start_day,(start_day+7)::timestamp at time zone 'America/Chihuahua',
      new.fare_cents,new.commission_cents
    )
    on conflict(driver_id,week_start) do update set
      gross_cash_cents=public.driver_commission_settlements.gross_cash_cents+excluded.gross_cash_cents,
      commission_due_cents=public.driver_commission_settlements.commission_due_cents+excluded.commission_due_cents,
      updated_at=now();
  end if;
  return new;
end $$;


create function private.finance_promotion_review_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.driver_promotion_reimbursements;
begin
 perform private.finance_admin(); select * into r from public.driver_promotion_reimbursements where id=(payload->>'reimbursement_id')::uuid;
 perform 1 from public.drivers where id=r.driver_id for update;
 if exists(select 1 from public.trips t where t.driver_id=r.driver_id and t.financial_terms<>'{}' and t.reward_discount_cents>0 and t.status='completed' and date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date=r.week_start) then raise exception 'Esta semana ya tiene promociones abonadas en billetera. Concilia cada viaje pendiente desde Billeteras para evitar duplicar transferencias.'; end if;
 return private.review_driver_promotion_reimbursement_v1(payload);
end $$;
revoke all on function private.finance_promotion_review_v1(jsonb) from public,anon;
grant execute on function private.finance_promotion_review_v1(jsonb) to authenticated;
create unique index driver_wallet_funding_reference on public.driver_wallet_entries(driver_id,(detail->>'reference')) where kind in ('opening','incentive','commission_payment','adjustment');

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v6(payload) when 'dashboard' then private.finance_dashboard_v1(payload)
   when 'onboard' then private.onboard_referral_v2(payload) when 'profile' then private.profile_v5(payload)
   when 'quote' then private.finance_quote_v1(payload) when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload) when 'trip' then private.trip_v14(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v10(payload) when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v4(payload) when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload) when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v5(payload) when 'offers' then private.finance_offers_v1(payload) when 'accept' then private.accept_offer_v5(payload)
   when 'push_subscription' then private.push_subscription_v1(payload)
   when 'reject_offer' then private.reject_offer_v1(payload) when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload) when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload) when 'ride_preferences' then private.ride_preferences_v1(payload)
   when 'transition' then private.transition_v10(payload) when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload) when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload) when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v5(payload) when 'review_reward_redemption' then private.review_reward_redemption_v2(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload) when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v3(payload) when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload) when 'upsert_feature_card' then private.upsert_feature_card_v1(payload)
   when 'set_feature_card_active' then private.set_feature_card_active_v1(payload) when 'operations_report' then private.operations_report_v5(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload) when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload) when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload) when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'review_driver_promotion_reimbursement' then private.finance_promotion_review_v1(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload) when 'refund_checkout' then private.refund_checkout_v2(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload) when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload) when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'scheduled_operations' then private.scheduled_operations_v1(payload) when 'confirm_scheduled_trip' then private.confirm_scheduled_trip_v1(payload)
   when 'assign_scheduled_trip' then private.assign_scheduled_trip_v1(payload) when 'category' then private.category_v3(payload)
   when 'upsert_service_shift' then private.upsert_service_shift_v1(payload) when 'set_driver_shift' then private.set_driver_shift_v1(payload)
   when 'finance_wallet' then private.finance_wallet_v1(payload)
   when 'finance_profile' then private.finance_profile_v1(payload)
   when 'finance_verify_profile' then private.finance_verify_profile_v1(payload)
   when 'finance_withdraw' then private.finance_withdraw_v1(payload)
   when 'finance_review_withdrawal' then private.finance_review_withdrawal_v1(payload)
   when 'finance_funding' then private.finance_funding_v1(payload)
   when 'finance_settings' then private.finance_settings_v1(payload)
   when 'finance_operations' then private.finance_operations_v1(payload)
   else private.dispatch(command,payload) end
$$;

alter function public.yavoi_payment_event(jsonb) rename to yavoi_payment_event_before_finance;
revoke all on function public.yavoi_payment_event_before_finance(jsonb) from public,anon,authenticated,service_role;
create function public.yavoi_payment_event(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare pay public.payments; result jsonb;
begin
 select * into pay from public.payments where id=(payload->>'external_reference')::uuid for update;
 if not found then raise exception 'Referencia de pago inválida.'; end if;
 if pay.status='refunded' and payload->>'status' not in ('refunded','charged_back') then return jsonb_build_object('ok',true,'ignored','terminal_payment'); end if;
 if pay.status='approved' and payload->>'status' in ('pending','in_process','rejected','cancelled') then return jsonb_build_object('ok',true,'ignored','stale_payment'); end if;
 if payload->>'status'='charged_back' then payload:=payload||jsonb_build_object('status','refunded','status_detail','provider_chargeback'); end if;
 if nullif(payload->>'funds_available_at','') is not null then update public.payments set funds_available_at=(payload->>'funds_available_at')::timestamptz where id=pay.id; end if;
 result:=public.yavoi_payment_event_before_finance(payload);
 return result;
end $$;
revoke all on function public.yavoi_payment_event(jsonb) from public,anon,authenticated;
grant execute on function public.yavoi_payment_event(jsonb) to service_role;

-- Optional bank-transfer worker. It remains on manual reconciliation until
-- Mercado Pago authorizes Payouts and registers the signing public key.
alter table public.finance_settings add column payout_provider text not null default 'manual' check(payout_provider in ('manual','mercado_pago'));
create sequence private.payout_reference_seq maxvalue 9999999 no cycle;
alter table public.driver_withdrawals add column provider_reference bigint not null default nextval('private.payout_reference_seq'),
 add column provider_payout_id text, add column provider_transaction_id text,
 add column provider_body jsonb, add column worker_lease_until timestamptz,
 add column provider_status text not null default '';
create unique index driver_withdrawals_provider_reference on public.driver_withdrawals(provider_reference);
create function public.yavoi_payout_worker(command text,payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.driver_withdrawals; f public.driver_fiscal_profiles; jobs jsonb:='[]'; account_value jsonb; body_value jsonb; target uuid; result jsonb;
begin
 if command='claim' then
 if not(select payouts_enabled and payout_provider='mercado_pago' from public.finance_settings where id) then return '[]'; end if;
 perform private.finance_weekly_queue();
 for target in select d.id from public.drivers d where exists(select 1 from public.driver_withdrawals x where x.driver_id=d.id and (x.status in ('requested','processing') or (x.status='paid' and x.provider_transaction_id is not null and x.paid_at>now()-interval '7 days')) and x.scheduled_for<=now() and coalesce(x.worker_lease_until,'-infinity')<=now()) order by d.id for update of d skip locked limit 10 loop
 select * into w from public.driver_withdrawals where driver_id=target and (status in ('requested','processing') or (status='paid' and provider_transaction_id is not null and paid_at>now()-interval '7 days')) and scheduled_for<=now() and coalesce(worker_lease_until,'-infinity')<=now() order by created_at for update limit 1;
 if not found then continue; end if;
 if w.status='paid' then
 update public.driver_withdrawals set worker_lease_until=now()+interval '6 hours' where id=w.id;
 jobs:=jobs||jsonb_build_array(to_jsonb(w)); continue;
 end if;
  -- Available excludes this reservation; compare total balance minus other
 -- reservations and held funds explicitly.
 result:=private.finance_wallet_data(target);
 if (result->>'balance_cents')::bigint-(result->>'reserved_cents')::bigint+w.gross_cents-(result->>'held_cents')::bigint<w.gross_cents then continue; end if;
 select * into f from public.driver_fiscal_profiles where driver_id=target;
 if w.provider_body is null then
 account_value:=case when w.destination->>'kind'='mercado_pago' then jsonb_build_object('email',w.destination->>'destination')
 else jsonb_build_object('number',w.destination->>'destination','bank_id',substr(w.destination->>'destination',1,3),'holder',w.destination->>'holder') end;
 if f.rfc_provided and w.destination->>'kind'='bank' then account_value:=account_value||jsonb_build_object('owner_type','RFC','owner_value',f.rfc); end if;
 body_value:=jsonb_build_object('external_reference',w.provider_reference::text,'description','Yavoi! retiro de ganancias',
 'transactions',jsonb_build_array(jsonb_build_object('type','account','account',account_value,'amount',jsonb_build_object('currency','MXN','value',w.net_cents/100.0),'external_reference',w.provider_reference::text,'description','Yavoi! ganancias del conductor')));
 else body_value:=w.provider_body; end if;
 update public.driver_withdrawals set status='processing',provider_body=body_value,worker_lease_until=now()+interval '2 minutes' where id=w.id returning * into w;
 jobs:=jobs||jsonb_build_array(to_jsonb(w));
 end loop; return jobs;
 end if;
 select driver_id into target from public.driver_withdrawals where id=(payload->>'withdrawal_id')::uuid;
 perform 1 from public.drivers where id=target for update;
 select * into w from public.driver_withdrawals where id=(payload->>'withdrawal_id')::uuid for update;
 if not found then raise exception 'Retiro no encontrado.'; end if;
 if command='registered' then
 if w.status<>'processing' then raise exception 'Estado de retiro inválido.'; end if;
 if coalesce(payload->>'payout_id','')='' or coalesce(payload->>'transaction_id','')='' then raise exception 'Identificadores del proveedor requeridos.'; end if;
 update public.driver_withdrawals set provider_payout_id=payload->>'payout_id',provider_transaction_id=payload->>'transaction_id',provider_status='created',worker_lease_until=now()+interval '10 minutes' where id=w.id;
 elsif command='result' then
 if w.provider_transaction_id is null or w.provider_transaction_id is distinct from payload->>'transaction_id' or w.provider_reference::text is distinct from payload->>'external_reference' or w.net_cents is distinct from (payload->>'amount_cents')::bigint or payload->>'currency' is distinct from 'MXN' then raise exception 'La transferencia no coincide con el retiro.'; end if;
 if w.status='paid' and payload->>'status'='refunded' then
 perform private.finance_post(target,null,null,'withdraw-return:'||w.id||':net','withdrawal_return',w.net_cents,jsonb_build_object('withdrawal_id',w.id,'reference',w.provider_transaction_id));
 perform private.finance_post(target,null,null,'withdraw-return:'||w.id||':fee','withdrawal_fee_return',w.fee_cents,jsonb_build_object('withdrawal_id',w.id));
 update public.driver_withdrawals set status='rejected',note='El banco devolvió la transferencia. Saldo restituido.',provider_status='refunded',worker_lease_until=null where id=w.id;
 return jsonb_build_object('ok',true);
 end if;
 if w.status in ('paid','rejected') then return jsonb_build_object('ok',true,'ignored',true); end if;
 if (payload->>'status'='processed' and payload->>'status_detail'='approved') or (payload->>'status'='success' and payload->>'status_detail'='accredited') then
 perform private.finance_post(target,null,null,'withdraw:'||w.id||':net','withdrawal',-w.net_cents,jsonb_build_object('withdrawal_id',w.id,'reference',w.provider_transaction_id));
 perform private.finance_post(target,null,null,'withdraw:'||w.id||':fee','withdrawal_fee',-w.fee_cents,jsonb_build_object('withdrawal_id',w.id,'vat_cents',w.fee_vat_cents));
 update public.driver_withdrawals set status='paid',paid_at=now(),transfer_reference='MP:'||w.provider_transaction_id,provider_status='confirmed',worker_lease_until=now()+interval '6 hours' where id=w.id;
 elsif payload->>'status' in ('canceled','rejected','error') then
 update public.driver_withdrawals set status='rejected',note='Mercado Pago: '||left(coalesce(payload->>'status_detail',''),180),provider_status=payload->>'status',worker_lease_until=null where id=w.id;
 else update public.driver_withdrawals set provider_status=left(payload->>'status',60),worker_lease_until=now()+interval '10 minutes' where id=w.id; end if;
 elsif command='error' then
 update public.driver_withdrawals set note=left(coalesce(payload->>'message','Requiere revisión del proveedor'),240),worker_lease_until=now()+interval '10 minutes' where id=w.id and status='processing';
 else raise exception 'Acción de transferencia inválida.'; end if;
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.yavoi_payout_worker(text,jsonb) from public,anon,authenticated;
grant execute on function public.yavoi_payout_worker(text,jsonb) to service_role;
-- Only Operations with MFA can opt in to automatic transfer processing.
create function private.finance_provider_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$ begin
 perform private.finance_admin();
 if payload->>'provider' not in ('manual','mercado_pago') or length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Revisa proveedor y nota.'; end if;
 update public.finance_settings set payout_provider=payload->>'provider',updated_at=now() where id;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'payout_provider_changed',payload);
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.finance_provider_v1(jsonb) from public,anon;
grant execute on function private.finance_provider_v1(jsonb) to authenticated;
-- Preserve router extensibility without another copied command list.
alter function public.yavoi(text,jsonb) rename to yavoi_before_payout_provider;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case when command='finance_provider' then private.finance_provider_v1(payload) else public.yavoi_before_payout_provider(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

create function private.finance_run_payout_worker() returns void language plpgsql security definer set search_path='' as $$
begin
 if (select payouts_enabled and payout_provider='mercado_pago' from public.finance_settings where id)
 and exists(select 1 from vault.decrypted_secrets where name='yavoi_payout_worker_token') then
 perform net.http_post(url:='https://asjlyureqokifjkpdwgc.supabase.co/functions/v1/driver-payouts',
 headers:=jsonb_build_object('Content-Type','application/json','x-yavoi-payout-token',(select decrypted_secret from vault.decrypted_secrets where name='yavoi_payout_worker_token' limit 1)),body:='{}',timeout_milliseconds:=1000);
 end if;
end $$;
revoke all on function private.finance_run_payout_worker() from public,anon,authenticated;
do $$ begin if exists(select 1 from pg_extension where extname='pg_cron') and exists(select 1 from pg_extension where extname='pg_net') then
 if exists(select 1 from cron.job where jobname='yavoi-payout-worker') then perform cron.unschedule('yavoi-payout-worker'); end if;
 perform cron.schedule('yavoi-payout-worker','*/10 * * * *','select private.finance_run_payout_worker()');
 end if; end $$;

-- Service-only financial context for the same offer shown in the driver popup.
create function public.yavoi_offer_finance(offer_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.trip_offers; t public.trips; f public.driver_fiscal_profiles; terms jsonb; split jsonb; c bigint; level_value text;
begin
 select * into o from public.trip_offers where id=offer_id and status='offered' and expires_at>now();
 if not found then return null; end if;
 select * into t from public.trips where id=o.trip_id;
 if t.financial_terms='{}' then return null; end if;
 select * into f from public.driver_fiscal_profiles where driver_id=o.driver_id;
 terms:=t.financial_terms||jsonb_build_object('entity',coalesce(f.entity,'individual'),'rfc_provided',coalesce(f.rfc_provided,false));
 level_value:=private.reward_metrics(o.driver_id)->>'level';
 c:=round(t.fare_cents*greatest(0,private.driver_commission_bps(o.driver_id,t.payment_method)-coalesce((terms->'level_discounts'->>level_value)::integer,0))/10000.0);
 split:=private.finance_split(greatest(0,t.fare_cents-t.reward_discount_cents),t.tip_cents,c,t.payment_method='card',terms);
 return jsonb_build_object('net_cents',(split->>'net_cents')::bigint+(private.finance_split(t.reward_discount_cents,0,0,true,terms)->>'net_cents')::bigint,'promotion_pending_cents',t.reward_discount_cents);
end $$;
revoke all on function public.yavoi_offer_finance(uuid) from public,anon,authenticated;
grant execute on function public.yavoi_offer_finance(uuid) to service_role;

alter function private.trip_receipt_payload_v1(uuid) rename to trip_receipt_payload_before_finance;
create function private.trip_receipt_payload_v1(target uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=private.trip_receipt_payload_before_finance(target); t public.trips; split jsonb;
begin
 select * into t from public.trips where id=target;
 if result is null or t.financial_terms='{}' then return result; end if;
 split:=private.finance_split(greatest(0,t.fare_cents-t.reward_discount_cents),t.tip_cents,0,false,t.financial_terms);
 return jsonb_set(result,'{trip}',result->'trip'||jsonb_build_object('fare_cents',t.fare_cents,'discount_cents',t.reward_discount_cents,'tip_cents',t.tip_cents,'service_base_cents',split->'taxable_base_cents','vat_cents',split->'fare_vat_cents'));
end $$;
revoke all on function private.trip_receipt_payload_v1(uuid) from public,anon,authenticated;

-- Monthly statements can export all entries, without the dashboard history cap.
create function private.finance_statement_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid:=coalesce(nullif(payload->>'driver_id','')::uuid,auth.uid()); month_value date:=date_trunc('month',coalesce(nullif(payload->>'month','')::date,timezone('America/Chihuahua',now())::date))::date;
begin
 if auth.uid() is null or not (private.is_admin() or (target=auth.uid() and exists(select 1 from public.profiles where id=target and role='driver' and not suspended))) then raise exception 'Acceso de titular u Operaciones requerido.' using errcode='42501'; end if;
 return jsonb_build_object('month',month_value,'driver_id',target,'entries',coalesce((select jsonb_agg(jsonb_build_object('date',e.created_at,'kind',e.kind,'amount_cents',e.amount_cents,'trip_id',e.trip_id,'reference',e.detail->>'reference') order by e.created_at) from public.driver_wallet_entries e where e.driver_id=target and e.created_at>=month_value::timestamp at time zone 'America/Chihuahua' and e.created_at<(month_value+interval '1 month') at time zone 'America/Chihuahua'),'[]'));
end $$;
revoke all on function private.finance_statement_v1(jsonb) from public,anon,authenticated;
grant execute on function private.finance_statement_v1(jsonb) to authenticated;
alter function public.yavoi(text,jsonb) rename to yavoi_before_finance_statement;
revoke all on function public.yavoi_before_finance_statement(text,jsonb) from public,anon,authenticated;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$ begin
 if command='finance_statement' then return private.finance_statement_v1(payload); end if;
 return public.yavoi_before_finance_statement(command,payload);
end $$;
-- The forwarding function runs as invoker: authenticated can call it, and all
-- finance mutation methods still enforce their own admin + MFA checks.
grant execute on function public.yavoi_before_finance_statement(text,jsonb) to authenticated;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
