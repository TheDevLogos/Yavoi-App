-- Immutable route proposal snapshots and repeatable, Operations-managed bookings.
-- Fare and commission calculations remain server-side in the existing quote/accept flows.
alter table public.trips
  add column planned_route jsonb,
  add column planned_route_distance_km numeric(8,2),
  add column planned_route_duration_minutes integer,
  add column planned_route_provider text,
  add column planned_route_created_at timestamptz,
  add column schedule_series_id uuid,
  add column schedule_sequence integer,
  add column schedule_total integer;

create index trips_scheduled_assignment on public.trips(status,scheduled_at,driver_id)
  where status in ('scheduled','payment_pending');

create table public.scheduled_trip_series (
  id uuid primary key default gen_random_uuid(),
  passenger_id uuid not null references public.profiles(id) on delete cascade,
  cadence text not null check(cadence in ('daily','weekly','monthly')),
  occurrence_count integer not null check(occurrence_count between 2 and 31),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.trips add constraint trips_schedule_series_fk
  foreign key(schedule_series_id) references public.scheduled_trip_series(id) on delete set null;
create index scheduled_trip_series_passenger on public.scheduled_trip_series(passenger_id,created_at desc);
alter table public.scheduled_trip_series enable row level security;
revoke all on public.scheduled_trip_series from anon,authenticated;
grant select on public.scheduled_trip_series to authenticated;
create policy scheduled_series_read on public.scheduled_trip_series for select to authenticated using(
  passenger_id=(select auth.uid()) or (select private.is_admin())
);

create function private.capture_trip_route_v1(target_trip uuid, route_payload jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare points jsonb:=route_payload->'coordinates';point jsonb;first_point jsonb;last_point jsonb;point_count integer;distance_value numeric;duration_value integer;trip_value public.trips;
begin
  if route_payload is null or jsonb_typeof(route_payload)<>'object' then return;end if;
  select * into trip_value from public.trips where id=target_trip for update;
  if not found or trip_value.planned_route is not null then return;end if;
  if points is null or jsonb_typeof(points)<>'array' then return;end if;
  point_count:=jsonb_array_length(points);
  if point_count<2 or point_count>4000 then return;end if;
  first_point:=points->0;last_point:=points->(point_count-1);
  if abs((first_point->>0)::numeric-trip_value.origin_lng)>0.015 or abs((first_point->>1)::numeric-trip_value.origin_lat)>0.015
     or abs((last_point->>0)::numeric-trip_value.dest_lng)>0.015 or abs((last_point->>1)::numeric-trip_value.dest_lat)>0.015 then return;end if;
  for point in select value from jsonb_array_elements(points) loop
    if jsonb_typeof(point)<>'array' or jsonb_array_length(point)<>2
       or not ((point->>0)::numeric between -105.8 and -105.1)
       or not ((point->>1)::numeric between 27.9 and 28.5) then return;end if;
  end loop;
  distance_value:=round(greatest(0,coalesce((route_payload->>'distance_km')::numeric,0))::numeric,2);
  duration_value:=greatest(1,least(1440,coalesce((route_payload->>'duration_minutes')::integer,1)));
  update public.trips set planned_route=jsonb_build_object(
      'coordinates',points,
      'distance_km',distance_value,
      'duration_minutes',duration_value,
      'instructions',case when jsonb_typeof(route_payload->'instructions')='array' then route_payload->'instructions' else '[]'::jsonb end
    ),planned_route_distance_km=distance_value,planned_route_duration_minutes=duration_value,
    planned_route_provider='osrm',planned_route_created_at=now(),updated_at=now()
  where id=target_trip and planned_route is null;
end $$;
revoke all on function private.capture_trip_route_v1(uuid,jsonb) from public,anon,authenticated;

create function private.request_trip_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;series public.scheduled_trip_series;cadence_value text:=coalesce(payload->>'recurrence','once');
  count_value integer:=coalesce(nullif(payload->>'recurrence_count','')::integer,1);idx integer;child public.trips;payment_status_value text;
begin
  if cadence_value not in ('once','daily','weekly','monthly') then raise exception 'Frecuencia de programación inválida.';end if;
  if cadence_value='once' and count_value<>1 then raise exception 'La programación única sólo admite una fecha.';end if;
  if cadence_value<>'once' and (count_value<2 or count_value>case when cadence_value='daily' then 31 else 12 end) then
    raise exception 'Revisa el número de recorridos a programar.';end if;
  result:=private.request_trip_v7(payload);
  select * into t from public.trips where id=(result->>'id')::uuid for update;
  if not found then return result;end if;
  perform private.capture_trip_route_v1(t.id,payload->'planned_route');
  if cadence_value='once' then return result||jsonb_build_object('scheduled_count',1);end if;
  if t.scheduled_at is null then raise exception 'Elige fecha y hora para repetir un viaje.';end if;
  insert into public.scheduled_trip_series(passenger_id,cadence,occurrence_count) values(t.passenger_id,cadence_value,count_value) returning * into series;
  update public.trips set schedule_series_id=series.id,schedule_sequence=1,schedule_total=count_value,updated_at=now() where id=t.id;
  for idx in 2..count_value loop
    insert into public.trips(
      passenger_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,
      fare_cents,commission_cents,payment_method,cash_tender_cents,payment_status,women_only,accessible,scheduled_at,
      tip_cents,total_cents,preferred_driver_id,party_size,service_notes,planned_route,planned_route_distance_km,
      planned_route_duration_minutes,planned_route_provider,planned_route_created_at,schedule_series_id,schedule_sequence,schedule_total
    ) values(
      t.passenger_id,t.quote_id,gen_random_uuid(),case when t.payment_method='card' then 'payment_pending' else 'scheduled' end,
      t.origin,t.destination,t.origin_lat,t.origin_lng,t.dest_lat,t.dest_lng,t.category,t.fare_cents,t.commission_cents,
      t.payment_method,case when t.payment_method='cash' then t.fare_cents else null end,'pending',t.women_only,t.accessible,
      case cadence_value when 'daily' then t.scheduled_at+make_interval(days=>idx-1) when 'weekly' then t.scheduled_at+make_interval(weeks=>idx-1) else t.scheduled_at+make_interval(months=>idx-1) end,
      0,t.fare_cents,null,t.party_size,t.service_notes,t.planned_route,t.planned_route_distance_km,t.planned_route_duration_minutes,
      t.planned_route_provider,t.planned_route_created_at,series.id,idx,count_value
    ) returning * into child;
    insert into private.trip_secrets(trip_id,pin) values(child.id,lpad((((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,4))::bit(16)::int % 9000)+1000))::text,4,'0'));
    payment_status_value:=case when child.payment_method='card' then 'created' else 'pending' end;
    insert into public.payments(trip_id,payer_id,kind,provider,idempotency_key,amount_cents,status)
      values(child.id,child.passenger_id,'ride',case when child.payment_method='card' then 'mercado_pago' else 'cash' end,gen_random_uuid(),child.total_cents,payment_status_value);
    insert into public.trip_events(trip_id,actor_id,event,detail) values(child.id,t.passenger_id,'scheduled_series_created',jsonb_build_object('series_id',series.id,'sequence',idx,'cadence',cadence_value));
  end loop;
  insert into public.audit_log(actor_id,action,target_id,detail) values(t.passenger_id,'scheduled_trip_series_created',series.id,jsonb_build_object('cadence',cadence_value,'occurrence_count',count_value,'first_trip_id',t.id));
  return result||jsonb_build_object('scheduled_count',count_value,'schedule_series_id',series.id,'recurrence',cadence_value);
end $$;
revoke all on function private.request_trip_v8(jsonb) from public,anon;
grant execute on function private.request_trip_v8(jsonb) to authenticated;

create function private.release_scheduled_trips_v1() returns void
language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  update public.trips set status='accepted',updated_at=now()
  where status='scheduled' and driver_id is not null and scheduled_at<=now()+interval '15 minutes'
    and (payment_method='cash' or payment_status='paid')
    and not exists(select 1 from public.trips busy where busy.driver_id=public.trips.driver_id and busy.id<>public.trips.id and busy.status in ('accepted','arrived','in_progress'));
  update public.trips set driver_id=null,updated_at=now()
  where status='scheduled' and driver_id is not null and scheduled_at<=now()+interval '15 minutes'
    and exists(select 1 from public.trips busy where busy.driver_id=public.trips.driver_id and busy.id<>public.trips.id and busy.status in ('accepted','arrived','in_progress'));
  update public.trips set status='requested',updated_at=now()
  where status='scheduled' and driver_id is null and scheduled_at<=now()+interval '15 minutes'
    and (payment_method='cash' or payment_status='paid');
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
  end loop;
end $$;
revoke all on function private.release_scheduled_trips_v1() from public,anon,authenticated;

create function private.assign_scheduled_trip_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid:=(payload->>'trip_id')::uuid;candidate uuid:=nullif(payload->>'driver_id','')::uuid;t public.trips;d public.drivers;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede reservar un viaje.' using errcode='42501';end if;
  select * into t from public.trips where id=target for update;
  if not found or t.status<>'scheduled' then raise exception 'Sólo puedes asignar viajes programados pendientes.';end if;
  if candidate is null then
    update public.trips set driver_id=null,updated_at=now() where id=t.id;
    insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,'scheduled_driver_unassigned','{}');
    return jsonb_build_object('ok',true,'driver_id',null);
  end if;
  select * into d from public.drivers where id=candidate for update;
  if not found or not d.approved or not d.account_active or d.category<>t.category or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then raise exception 'El conductor no cumple los requisitos para este servicio.';end if;
  if (t.women_only and not d.female_verified) or (t.accessible and not d.accessible_verified) then raise exception 'El conductor no cumple la preferencia del viaje.';end if;
  if exists(select 1 from public.trips busy where busy.driver_id=candidate and busy.id<>t.id and busy.status in ('accepted','arrived','in_progress')) then raise exception 'El conductor tiene un viaje activo.';end if;
  if exists(select 1 from public.trips clash where clash.driver_id=candidate and clash.id<>t.id and clash.status='scheduled' and abs(extract(epoch from (clash.scheduled_at-t.scheduled_at)))<5400) then raise exception 'El conductor ya tiene un viaje programado muy cercano a este horario.';end if;
  update public.trips set driver_id=candidate,updated_at=now() where id=t.id;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,'scheduled_driver_assigned',jsonb_build_object('driver_id',candidate));
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'scheduled_trip_assigned',t.id,jsonb_build_object('driver_id',candidate,'scheduled_at',t.scheduled_at));
  return jsonb_build_object('ok',true,'driver_id',candidate);
end $$;
revoke all on function private.assign_scheduled_trip_v1(jsonb) from public,anon;
grant execute on function private.assign_scheduled_trip_v1(jsonb) to authenticated;

create function private.offers_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  perform private.release_scheduled_trips_v1();
  return private.offers_v5(payload);
end $$;
revoke all on function private.offers_v6(jsonb) from public,anon;
grant execute on function private.offers_v6(jsonb) to authenticated;

create function private.trip_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;t public.trips;
begin
  base:=private.trip_v7(payload);
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  return base||jsonb_build_object('route_plan',jsonb_build_object(
    'coordinates',coalesce(t.planned_route->'coordinates','[]'::jsonb),'distance_km',t.planned_route_distance_km,
    'duration_minutes',t.planned_route_duration_minutes,'provider',t.planned_route_provider,
    'created_at',t.planned_route_created_at,'instructions',coalesce(t.planned_route->'instructions','[]'::jsonb)
  ),'schedule',jsonb_build_object('series_id',t.schedule_series_id,'sequence',t.schedule_sequence,'total',t.schedule_total));
end $$;
revoke all on function private.trip_v8(jsonb) from public,anon;
grant execute on function private.trip_v8(jsonb) to authenticated;

create function private.dashboard_v10(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;schedule_data jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  perform private.release_scheduled_trips_v1();
  base:=private.dashboard_v9(payload);
  if p.role='admin' then
    schedule_data:=jsonb_build_object(
      'upcoming',(select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at),'[]') from (
        select t.id,t.origin,t.destination,t.category,t.scheduled_at,t.status,t.payment_method,t.payment_status,t.total_cents,t.driver_id,pr.full_name as passenger_name,dp.full_name as driver_name
        from public.trips t join public.profiles pr on pr.id=t.passenger_id left join public.profiles dp on dp.id=t.driver_id
        where t.status='scheduled' and t.scheduled_at>=now()-interval '1 day' order by t.scheduled_at limit 100
      )x),
      'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (
        select d.id,pr.full_name,d.category,d.approved,d.account_active,d.online from public.drivers d join public.profiles pr on pr.id=d.id
        where d.approved and d.account_active order by pr.full_name
      )x)
    );
  else
    schedule_data:=jsonb_build_object('upcoming',(select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at),'[]') from (
      select id,origin,destination,category,scheduled_at,status,payment_method,payment_status,total_cents,driver_id,schedule_series_id,schedule_sequence,schedule_total
      from public.trips where status in ('scheduled','payment_pending') and (passenger_id=uid or driver_id=uid) and scheduled_at>=now()-interval '1 day' order by scheduled_at limit 50
    )x));
  end if;
  return base||jsonb_build_object('scheduling',schedule_data);
end $$;
revoke all on function private.dashboard_v10(jsonb) from public,anon;
grant execute on function private.dashboard_v10(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v10(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v8(payload)
   when 'trip' then private.trip_v8(payload)
   when 'driver_profile' then private.driver_profile_v7(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v6(payload)
   when 'accept' then private.accept_offer_v2(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'transition' then private.transition_v7(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v1(payload)
   when 'redeem_reward' then private.redeem_reward_v3(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v1(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
   when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload)
   when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v2(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'assign_scheduled_trip' then private.assign_scheduled_trip_v1(payload)
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
