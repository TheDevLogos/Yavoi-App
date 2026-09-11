-- Per-driver commercial models, weekly cash-commission settlements and
-- complete trip ratings. Historical trips retain the terms applied when the
-- driver accepted the service.
alter table public.drivers
  add column billing_mode text not null default 'weekly_fee'
    check(billing_mode in ('weekly_fee','commission')),
  add column weekly_fee_cents integer not null default 50000
    check(weekly_fee_cents between 0 and 100000),
  add column cash_commission_bps integer not null default 0
    check(cash_commission_bps between 0 and 5000),
  add column card_commission_bps integer not null default 1000
    check(card_commission_bps between 0 and 5000);

alter table public.trips
  add column billing_mode text not null default 'legacy'
    check(billing_mode in ('legacy','weekly_fee','commission')),
  add column commission_bps_applied integer not null default 0
    check(commission_bps_applied between 0 and 5000);

update public.trips
set commission_bps_applied=case when fare_cents>0 then least(5000,round(commission_cents*10000.0/fare_cents)::integer) else 0 end;

create table public.driver_commission_settlements (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  week_start date not null,
  due_at timestamptz not null,
  gross_cash_cents integer not null default 0 check(gross_cash_cents>=0),
  commission_due_cents integer not null default 0 check(commission_due_cents>=0),
  status text not null default 'pending'
    check(status in ('pending','submitted','paid','overdue','waived')),
  proof_path text,
  submitted_at timestamptz,
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  note text not null default '' check(char_length(note)<=1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(driver_id,week_start)
);
create index driver_commission_settlements_status_due
  on public.driver_commission_settlements(status,due_at);
create index driver_commission_settlements_verified_by
  on public.driver_commission_settlements(verified_by) where verified_by is not null;

alter table public.driver_commission_settlements enable row level security;
revoke all on public.driver_commission_settlements from anon,authenticated;
grant select on public.driver_commission_settlements to authenticated;
create policy driver_commission_settlements_read
  on public.driver_commission_settlements for select to authenticated
  using(driver_id=(select auth.uid()) or (select private.is_admin()));

create or replace function private.ensure_weekly_fee(target_driver uuid)
returns public.weekly_fees
language plpgsql security definer set search_path='' as $$
declare result public.weekly_fees;start_day date:=date_trunc('week',current_date)::date;d public.drivers;
begin
  select * into d from public.drivers where id=target_driver;
  if not found then return null;end if;
  if d.billing_mode<>'weekly_fee' then
    update public.weekly_fees set status='waived',note='Modalidad por comisión',updated_at=now()
    where driver_id=target_driver and status in ('pending','submitted','overdue');
    return null;
  end if;
  insert into public.weekly_fees(driver_id,week_start,due_at,amount_cents)
  values(target_driver,start_day,(start_day+7)::timestamp at time zone 'America/Chihuahua',d.weekly_fee_cents)
  on conflict(driver_id,week_start) do update set
    amount_cents=case when public.weekly_fees.status='waived' and public.weekly_fees.note='Modalidad por comisión' then excluded.amount_cents else public.weekly_fees.amount_cents end,
    due_at=case when public.weekly_fees.status='waived' and public.weekly_fees.note='Modalidad por comisión' then excluded.due_at else public.weekly_fees.due_at end,
    status=case when public.weekly_fees.status='waived' and public.weekly_fees.note='Modalidad por comisión' then 'pending' else public.weekly_fees.status end,
    proof_path=case when public.weekly_fees.status='waived' and public.weekly_fees.note='Modalidad por comisión' then null else public.weekly_fees.proof_path end,
    submitted_at=case when public.weekly_fees.status='waived' and public.weekly_fees.note='Modalidad por comisión' then null else public.weekly_fees.submitted_at end,
    note=case when public.weekly_fees.status='waived' and public.weekly_fees.note='Modalidad por comisión' then '' else public.weekly_fees.note end,
    updated_at=now()
  returning * into result;
  return result;
end $$;
revoke all on function private.ensure_weekly_fee(uuid) from public,anon,authenticated;

create function private.driver_commission_bps(target_driver uuid,method text)
returns integer language sql stable security definer set search_path='' as $$
  select case when method='cash' then cash_commission_bps else card_commission_bps end
  from public.drivers where id=target_driver
$$;
revoke all on function private.driver_commission_bps(uuid,text) from public,anon,authenticated;

create function private.set_driver_billing_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;mode_value text;weekly_value integer;cash_value integer;card_value integer;note_value text;result public.drivers;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede cambiar la modalidad de cobro.' using errcode='42501';
  end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>4000 then raise exception 'Solicitud inválida.';end if;
  target:=(payload->>'driver_id')::uuid;
  mode_value:=payload->>'billing_mode';
  weekly_value:=coalesce((payload->>'weekly_fee_cents')::integer,50000);
  cash_value:=coalesce((payload->>'cash_commission_bps')::integer,case when mode_value='weekly_fee' then 0 else 2000 end);
  card_value:=coalesce((payload->>'card_commission_bps')::integer,case when mode_value='weekly_fee' then 1000 else 2000 end);
  note_value:=trim(coalesce(payload->>'note',''));
  if mode_value not in ('weekly_fee','commission') then raise exception 'Modalidad de cobro inválida.';end if;
  if weekly_value not between 0 and 100000 or cash_value not between 0 and 5000 or card_value not between 0 and 5000 then raise exception 'Importes o porcentajes fuera de rango.';end if;
  if mode_value='weekly_fee' and cash_value<>0 then raise exception 'En la modalidad de aportación, el efectivo es 100%% para el conductor.';end if;
  if length(note_value)<5 then raise exception 'Registra el motivo del cambio.';end if;
  update public.drivers set billing_mode=mode_value,weekly_fee_cents=weekly_value,
    cash_commission_bps=cash_value,card_commission_bps=card_value,updated_at=now()
  where id=target returning * into result;
  if not found then raise exception 'Conductor no encontrado.';end if;
  if mode_value='commission' then
    update public.weekly_fees set status='waived',note='Modalidad por comisión',updated_at=now()
    where driver_id=target and status in ('pending','submitted','overdue');
  else
    perform private.ensure_weekly_fee(target);
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'driver_billing_changed',target,jsonb_build_object(
    'billing_mode',mode_value,'weekly_fee_cents',weekly_value,
    'cash_commission_bps',cash_value,'card_commission_bps',card_value,'note',left(note_value,500)
  ));
  return jsonb_build_object('ok',true,'driver',to_jsonb(result));
end $$;
revoke all on function private.set_driver_billing_v1(jsonb) from public,anon;
grant execute on function private.set_driver_billing_v1(jsonb) to authenticated;

create function private.offers_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();d public.drivers;waiting record;
begin
  select * into d from public.drivers where id=uid;
  if uid is null or not found or not d.approved or not d.online or not d.account_active or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then return '[]'::jsonb;end if;
  perform private.expire_trip_offers();
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then return '[]'::jsonb;end if;
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
  end loop;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.expires_at),'[]') from (
    select o.id as offer_id,o.expires_at,t.id,t.origin,t.destination,t.fare_cents,
      t.fare_cents-round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer+t.tip_cents as net_cents,
      round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer as commission_cents,
      private.driver_commission_bps(uid,t.payment_method) as commission_bps,d.billing_mode,
      t.cash_tender_cents,t.category,t.women_only,t.accessible,t.scheduled_at,t.distance_km,t.trip_eta_minutes,
      t.pickup_eta_minutes,t.service_zone,t.created_at,t.payment_method,t.payment_status,t.tip_cents,t.total_cents,
      t.party_size,t.service_notes,pr.full_name as passenger_name,pr.avatar_path as passenger_avatar_path,
      (select round(avg(stars),2) from public.ratings where recipient_id=t.passenger_id) as passenger_rating,
      (select count(*) from public.trips completed where completed.passenger_id=t.passenger_id and completed.status='completed') as passenger_trips,
      round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) as pickup_from_driver_km
    from public.trip_offers o join public.trips t on t.id=o.trip_id join public.profiles pr on pr.id=t.passenger_id
    join public.driver_presence dp on dp.driver_id=o.driver_id
    where o.driver_id=uid and o.status='offered' and o.expires_at>now() and t.status='requested' and t.driver_id is null
  )x);
end $$;
revoke all on function private.offers_v5(jsonb) from public,anon;
grant execute on function private.offers_v5(jsonb) to authenticated;

create function private.accept_offer_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();o public.trip_offers;t public.trips;d public.drivers;bps integer;commission_value integer;
begin
  select * into o from public.trip_offers where id=(payload->>'offer_id')::uuid and driver_id=uid for update;
  if uid is null or not found or o.status<>'offered' then raise exception 'La solicitud ya no está disponible.' using errcode='42501';end if;
  if o.expires_at<=now() then
    update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado' where id=o.id;
    perform private.auto_assign_trip(o.trip_id,(select preferred_driver_id from public.trips where id=o.trip_id));
    return jsonb_build_object('error','La solicitud venció y fue enviada a otra unidad.');
  end if;
  select * into d from public.drivers where id=uid for update;
  select * into t from public.trips where id=o.trip_id for update;
  if not d.online or not d.approved or not d.account_active or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then raise exception 'Tu unidad no está disponible.' using errcode='42501';end if;
  if t.status<>'requested' or t.driver_id is not null or (t.payment_method='card' and t.payment_status<>'paid') then raise exception 'La solicitud ya no está disponible.';end if;
  if exists(select 1 from public.trips busy where busy.driver_id=uid and busy.id<>t.id and busy.status not in ('completed','cancelled')) then raise exception 'Ya tienes un viaje activo.';end if;
  bps:=private.driver_commission_bps(uid,t.payment_method);
  commission_value:=round(t.fare_cents*bps/10000.0)::integer;
  update public.trip_offers set status='accepted',responded_at=now() where id=o.id;
  update public.trips set driver_id=uid,status='accepted',billing_mode=d.billing_mode,
    commission_bps_applied=bps,commission_cents=commission_value,updated_at=now()
  where id=t.id returning * into t;
  insert into public.trip_events(trip_id,actor_id,event,detail)
  values(t.id,uid,'accepted',jsonb_build_object('offer_id',o.id,'billing_mode',d.billing_mode,'commission_bps',bps));
  return to_jsonb(t);
end $$;
revoke all on function private.accept_offer_v2(jsonb) from public,anon;
grant execute on function private.accept_offer_v2(jsonb) to authenticated;

create function private.record_cash_commission_settlement() returns trigger
language plpgsql security definer set search_path='' as $$
declare start_day date;
begin
  if new.status='completed' and old.status is distinct from 'completed' and new.payment_method='cash'
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
revoke all on function private.record_cash_commission_settlement() from public,anon,authenticated;
create trigger record_cash_commission_settlement
after update of status on public.trips for each row execute function private.record_cash_commission_settlement();

create function private.submit_driver_settlement_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;settlement public.driver_commission_settlements;path_value text;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
  select * into settlement from public.driver_commission_settlements
  where id=(payload->>'settlement_id')::uuid and driver_id=uid for update;
  if not found or settlement.status in ('paid','waived') then raise exception 'Liquidación no disponible.';end if;
  path_value:=payload->>'proof_path';
  if not exists(select 1 from storage.objects where bucket_id='yavoi-payment-proofs' and name=path_value and (storage.foldername(name))[1]=uid::text) then raise exception 'Comprobante inválido.';end if;
  update public.driver_commission_settlements set proof_path=path_value,status='submitted',
    submitted_at=now(),updated_at=now() where id=settlement.id returning * into settlement;
  return to_jsonb(settlement);
end $$;
revoke all on function private.submit_driver_settlement_v1(jsonb) from public,anon;
grant execute on function private.submit_driver_settlement_v1(jsonb) to authenticated;

create function private.review_driver_settlement_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();settlement public.driver_commission_settlements;approved boolean;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede revisar liquidaciones.' using errcode='42501';
  end if;
  select * into settlement from public.driver_commission_settlements
  where id=(payload->>'settlement_id')::uuid for update;
  if not found then raise exception 'Liquidación no encontrada.';end if;
  approved:=coalesce((payload->>'approved')::boolean,false);
  if approved and settlement.proof_path is null then raise exception 'El conductor no ha enviado comprobante.';end if;
  update public.driver_commission_settlements set
    status=case when approved then 'paid' else 'pending' end,
    proof_path=case when approved then proof_path else null end,
    submitted_at=case when approved then submitted_at else null end,
    verified_by=uid,verified_at=now(),note=left(coalesce(payload->>'note',''),1000),updated_at=now()
  where id=settlement.id;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'review_driver_settlement',settlement.id,jsonb_build_object(
    'driver_id',settlement.driver_id,'approved',approved,
    'commission_due_cents',settlement.commission_due_cents,'note',left(coalesce(payload->>'note',''),500)
  ));
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.review_driver_settlement_v1(jsonb) from public,anon;
grant execute on function private.review_driver_settlement_v1(jsonb) to authenticated;

create function private.trip_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();t public.trips;base jsonb;
begin
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  base:=private.trip_v4(payload);
  return base||jsonb_build_object(
    'ratings',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') from (
      select r.id,r.author_id,r.recipient_id,r.stars,r.comment,r.comfort,r.safety,r.created_at,
        author.full_name as author_name,author.role as author_role,
        recipient.full_name as recipient_name,recipient.role as recipient_role
      from public.ratings r join public.profiles author on author.id=r.author_id
      join public.profiles recipient on recipient.id=r.recipient_id where r.trip_id=t.id
    )x),
    'billing',jsonb_build_object(
      'mode',t.billing_mode,'commission_bps',t.commission_bps_applied,
      'commission_cents',t.commission_cents,
      'driver_earnings_cents',t.fare_cents-t.commission_cents+t.tip_cents
    )
  );
end $$;
revoke all on function private.trip_v5(jsonb) from public,anon;
grant execute on function private.trip_v5(jsonb) to authenticated;

create function private.dashboard_v7(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  if p.role='admin' then
    update public.weekly_fees f set status='waived',note='Modalidad por comisión',updated_at=now()
    from public.drivers d where d.id=f.driver_id and d.billing_mode='commission'
      and f.status in ('pending','submitted','overdue');
    update public.driver_commission_settlements set status='overdue',updated_at=now()
    where status in ('pending','submitted') and due_at<now();
  elsif p.role='driver' and exists(select 1 from public.drivers where id=uid and billing_mode='commission') then
    update public.weekly_fees set status='waived',note='Modalidad por comisión',updated_at=now()
    where driver_id=uid and status in ('pending','submitted','overdue');
    update public.driver_commission_settlements set status='overdue',updated_at=now()
    where driver_id=uid and status in ('pending','submitted') and due_at<now();
  end if;
  base:=private.dashboard_v6(payload);
  return base||jsonb_build_object(
    'trips',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
      select t.*,
        (select stars from public.ratings r where r.trip_id=t.id and r.author_id=uid) as rating_given,
        (select stars from public.ratings r where r.trip_id=t.id and r.recipient_id=uid) as rating_received
      from public.trips t where t.passenger_id=uid or t.driver_id=uid or p.role='admin'
      order by t.created_at desc limit 200
    )x),
    'commission_settlements',(select coalesce(jsonb_agg(to_jsonb(x) order by x.week_start desc),'[]') from (
      select s.*,pr.full_name as driver_name,d.billing_mode,d.cash_commission_bps,d.card_commission_bps
      from public.driver_commission_settlements s join public.profiles pr on pr.id=s.driver_id
      join public.drivers d on d.id=s.driver_id
      where s.driver_id=uid or p.role='admin' order by s.week_start desc limit 500
    )x)
  );
end $$;
revoke all on function private.dashboard_v7(jsonb) from public,anon;
grant execute on function private.dashboard_v7(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v7(payload)
   when 'profile' then private.profile_v3(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v6(payload)
   when 'trip' then private.trip_v5(payload)
   when 'driver_profile' then private.driver_profile_v5(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v5(payload)
   when 'accept' then private.accept_offer_v2(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'transition' then private.transition_v4(payload)
   when 'rating' then private.rating_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v1(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'operations_report' then private.operations_report_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
   when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload)
   when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v1(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

alter publication supabase_realtime add table public.driver_commission_settlements;
