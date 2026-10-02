-- Waiting is an observable post-acceptance event.  The original quote stays
-- untouched; this immutable record explains every cent added after arrival.
create table public.trip_wait_charges (
  trip_id uuid primary key references public.trips(id) on delete cascade,
  arrived_at timestamptz not null default now(),
  free_until timestamptz not null,
  rate_cents_per_minute integer not null check(rate_cents_per_minute between 1 and 10000),
  status text not null default 'running' check(status in ('running','stopped')),
  stopped_at timestamptz,
  charged_cents integer not null default 0 check(charged_cents >= 0),
  created_at timestamptz not null default now()
);
alter table public.trip_wait_charges enable row level security;
revoke all on public.trip_wait_charges from public, anon, authenticated;
create policy trip_wait_charges_rpc_only on public.trip_wait_charges for all to public using (false) with check (false);

-- Cents are never rounded up: the displayed charge changes only after a full
-- cent has accrued.  That makes the per-second rate auditable and reproducible.
create function private.trip_wait_charge_cents_v1(waiting public.trip_wait_charges, at_time timestamptz default now())
returns integer language sql stable security definer set search_path='' as $$
  select case
    when waiting.status='stopped' then waiting.charged_cents
    when at_time <= waiting.free_until then 0
    else floor(extract(epoch from at_time - waiting.free_until) * waiting.rate_cents_per_minute / 60.0)::integer
  end
$$;
revoke all on function private.trip_wait_charge_cents_v1(public.trip_wait_charges,timestamptz) from public, anon, authenticated;

create function private.trip_post_acceptance_adjustments_cents_v1(target uuid, at_time timestamptz default now())
returns integer language plpgsql stable security definer set search_path='' as $$
declare manual_cents integer; waiting public.trip_wait_charges;
begin
  select coalesce(sum(amount_cents),0)::integer into manual_cents
  from public.trip_fare_adjustments where trip_id=target and status='accepted';
  select * into waiting from public.trip_wait_charges where trip_id=target;
  return manual_cents + coalesce(private.trip_wait_charge_cents_v1(waiting,at_time),0);
end $$;
revoke all on function private.trip_post_acceptance_adjustments_cents_v1(uuid,timestamptz) from public, anon, authenticated;

create function private.trip_final_total_cents_v1(item public.trips, at_time timestamptz default now())
returns integer language sql stable security definer set search_path='' as $$
  select case when item.status='cancelled' then coalesce(item.cancellation_fee_cents,0)
    else greatest(0, coalesce(item.total_cents,item.fare_cents,0) + private.trip_post_acceptance_adjustments_cents_v1(item.id,at_time)) end
$$;
revoke all on function private.trip_final_total_cents_v1(public.trips,timestamptz) from public, anon, authenticated;

-- Starting a ride freezes the wait exactly once.  The trigger also covers GPS
-- arrival because it watches the status transition instead of a UI action.
create function private.manage_trip_wait_charge_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare rate_value integer;
begin
  if new.status='arrived' and old.status='accepted' then
    select c.minute_cents into rate_value from public.categories c where c.id=new.category;
    insert into public.trip_wait_charges(trip_id,arrived_at,free_until,rate_cents_per_minute)
    values(new.id,now(),now()+interval '2 minutes',coalesce(rate_value,1))
    on conflict(trip_id) do nothing;
    insert into public.trip_events(trip_id,actor_id,event,detail)
    values(new.id,new.driver_id,'waiting_started',jsonb_build_object('free_seconds',120,'rate_cents_per_minute',coalesce(rate_value,1)));
  elsif new.status='in_progress' and old.status='arrived' then
    update public.trip_wait_charges as waiting set status='stopped',stopped_at=now(),
      charged_cents=private.trip_wait_charge_cents_v1(waiting,now())
    where waiting.trip_id=new.id and waiting.status='running';
    insert into public.trip_events(trip_id,actor_id,event,detail)
    select new.id,new.driver_id,'waiting_stopped',jsonb_build_object('charged_cents',charged_cents,'stopped_at',stopped_at)
    from public.trip_wait_charges where trip_id=new.id;
  end if;
  return new;
end $$;
revoke all on function private.manage_trip_wait_charge_v1() from public, anon, authenticated;
create trigger aa_manage_trip_wait_charge before update of status on public.trips
for each row execute function private.manage_trip_wait_charge_v1();

-- Financial snapshots include frozen post-acceptance amounts.  Original fare
-- and quote terms remain locked, while the final amount remains traceable.
create or replace function private.expected_trip_financial_breakdown_v1(item public.trips) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare gross bigint; tips bigint; commission bigint; split jsonb; promotion_split jsonb; additions integer; original_gross bigint;
begin
  additions:=case when item.status='cancelled' then 0 else private.trip_post_acceptance_adjustments_cents_v1(item.id) end;
  original_gross:=case when item.status='cancelled' then item.cancellation_fee_cents else greatest(0,item.fare_cents-item.reward_discount_cents) end;
  gross:=original_gross+additions;
  tips:=case when item.status='cancelled' then 0 else item.tip_cents end;
  commission:=case when item.status='cancelled' then item.cancellation_commission_cents else item.commission_cents + round(additions*coalesce(item.commission_bps_applied,0)/10000.0)::integer end;
  split:=private.finance_split(gross,tips,commission,item.payment_method='card',item.financial_terms);
  promotion_split:=private.finance_split(case when item.status='cancelled' then 0 else item.reward_discount_cents end,0,0,true,item.financial_terms);
  return split||jsonb_build_object(
    'version',item.financial_terms->>'version','fare_cents',item.fare_cents,'passenger_total_cents',gross+tips,
    'post_acceptance_adjustments_cents',additions,'promotion_pending_cents',case when item.status='cancelled' then 0 else item.reward_discount_cents end,
    'contractual_net_cents',(split->>'net_cents')::bigint+(promotion_split->>'net_cents')::bigint,
    'state_contribution_cents',round(gross*150/10000.0),'state_payer','Yavoi!','vat_included',true,
    'cash_commission_due_cents',case when item.payment_method='cash' then commission else 0 end,
    'commission_on_adjustments_cents',commission-item.commission_cents,'level',item.financial_terms->>'level'
  );
end $$;

create or replace function private.finance_snapshot_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare f public.driver_fiscal_profiles; terms jsonb; level_value text; discount integer:=0; original integer; c integer; gross bigint; tip bigint; split jsonb; promo_split jsonb; additions integer;
begin
 if tg_op='INSERT' then select financial_terms into terms from public.quotes where id=new.quote_id; new.financial_terms:=coalesce(terms,'{}'); end if;
 if new.financial_terms='{}' then return new; end if;
 if new.driver_id is not null and (tg_op='INSERT' or old.driver_id is distinct from new.driver_id) then
  select * into f from public.driver_fiscal_profiles where driver_id=new.driver_id;
  level_value:=private.reward_metrics(new.driver_id)->>'level'; discount:=coalesce((new.financial_terms->'level_discounts'->>level_value)::integer,0);
  original:=private.driver_commission_bps(new.driver_id,new.payment_method); select billing_mode into new.billing_mode from public.drivers where id=new.driver_id;
  new.commission_bps_applied:=greatest(0,original-discount); new.commission_cents:=round(new.fare_cents*new.commission_bps_applied/10000.0);
  new.financial_terms:=new.financial_terms||jsonb_build_object('entity',coalesce(f.entity,'individual'),'rfc_provided',coalesce(f.rfc_provided,false),'fiscal_locked_at',now(),'level',level_value,'level_discount_bps',discount,'original_commission_bps',original,'commission_bps',new.commission_bps_applied);
 end if;
 if new.driver_id is null then return new; end if;
 additions:=case when new.status='cancelled' then 0 else private.trip_post_acceptance_adjustments_cents_v1(new.id) end;
 gross:=case when new.status='cancelled' then new.cancellation_fee_cents else greatest(0,new.fare_cents-new.reward_discount_cents)+additions end;
 tip:=case when new.status='cancelled' then 0 else new.tip_cents end;
 c:=case when new.status='cancelled' then new.cancellation_commission_cents else new.commission_cents+round(additions*coalesce(new.commission_bps_applied,0)/10000.0)::integer end;
 split:=private.finance_split(gross,tip,c,new.payment_method='card',new.financial_terms); promo_split:=private.finance_split(case when new.status='cancelled' then 0 else new.reward_discount_cents end,0,0,true,new.financial_terms);
 new.financial_breakdown:=split||jsonb_build_object('version',new.financial_terms->>'version','fare_cents',new.fare_cents,'passenger_total_cents',gross+tip,'post_acceptance_adjustments_cents',additions,'promotion_pending_cents',case when new.status='cancelled' then 0 else new.reward_discount_cents end,'contractual_net_cents',(split->>'net_cents')::bigint+(promo_split->>'net_cents')::bigint,'state_contribution_cents',round(gross*150/10000.0),'state_payer','Yavoi!','vat_included',true,'cash_commission_due_cents',case when new.payment_method='cash' then c else 0 end,'commission_on_adjustments_cents',c-new.commission_cents,'level',new.financial_terms->>'level');
 return new;
end $$;

-- Accepted manual adjustments refresh the accounting snapshot immediately.
create or replace function private.trip_fare_adjustment_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.trips; adjustment public.trip_fare_adjustments; action_value text:=payload->>'action'; reason_value text:=payload->>'reason'; amount integer:=coalesce((payload->>'amount_cents')::integer,0); decision text:=payload->>'decision';
begin
 select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
 if not found or auth.uid() not in (t.passenger_id,t.driver_id) or t.status not in ('accepted','arrived','in_progress') then raise exception 'El ajuste sólo puede solicitarse por las personas de un viaje activo.'; end if;
 if action_value='propose' then
   if reason_value not in ('detour','route_change','extra_pickup') or amount<1 or amount>100000 then raise exception 'Selecciona motivo e importe válidos.'; end if;
   insert into public.trip_fare_adjustments(trip_id,proposed_by,reason,amount_cents) values(t.id,auth.uid(),reason_value,amount) returning * into adjustment;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'fare_adjustment_proposed',jsonb_build_object('adjustment_id',adjustment.id,'reason',reason_value,'amount_cents',amount));
 elsif action_value='decide' then
   select * into adjustment from public.trip_fare_adjustments where id=(payload->>'adjustment_id')::uuid and trip_id=t.id for update;
   if not found or adjustment.status<>'pending' or adjustment.proposed_by=auth.uid() or decision not in ('accepted','declined') then raise exception 'No puedes resolver este ajuste.'; end if;
   update public.trip_fare_adjustments set status=decision,decided_by=auth.uid(),decided_at=now() where id=adjustment.id returning * into adjustment;
   if decision='accepted' then update public.trips set financial_breakdown=private.expected_trip_financial_breakdown_v1(public.trips),updated_at=now() where id=t.id; end if;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'fare_adjustment_'||decision,jsonb_build_object('adjustment_id',adjustment.id,'reason',adjustment.reason,'amount_cents',adjustment.amount_cents));
 else raise exception 'Acción de ajuste inválida.'; end if;
 return to_jsonb(adjustment);
end $$;

create or replace function private.trip_v16(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare base jsonb:=private.trip_v15(payload); target uuid:=(payload->>'trip_id')::uuid; waiting public.trip_wait_charges; manual_cents integer; waiting_cents integer;
begin
 select * into waiting from public.trip_wait_charges where trip_id=target;
 select coalesce(sum(amount_cents),0)::integer into manual_cents from public.trip_fare_adjustments where trip_id=target and status='accepted';
 waiting_cents:=coalesce(private.trip_wait_charge_cents_v1(waiting,now()),0);
 return base || jsonb_build_object('waiting_charge',case when waiting.trip_id is null then null else jsonb_build_object('arrived_at',waiting.arrived_at,'free_until',waiting.free_until,'rate_cents_per_minute',waiting.rate_cents_per_minute,'status',waiting.status,'stopped_at',waiting.stopped_at,'charged_cents',waiting_cents,'free_seconds_remaining',greatest(0,floor(extract(epoch from waiting.free_until-now()))::integer)) end,'manual_adjustments_cents',manual_cents,'waiting_adjustments_cents',waiting_cents,'final_total_cents',(base->'trip'->>'total_cents')::integer+manual_cents+waiting_cents);
end $$;
revoke all on function private.trip_v16(jsonb) from public, anon;
grant execute on function private.trip_v16(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_automatic_waiting;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$ begin
 if command='trip' then return private.trip_v16(payload); end if;
 return public.yavoi_before_automatic_waiting(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public, anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
