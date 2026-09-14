-- Passenger shortcuts, Operations scheduling calendar and service-mix reporting.
create table public.saved_places (
  id uuid primary key default gen_random_uuid(),
  passenger_id uuid not null references public.profiles(id) on delete cascade,
  slot text not null check(slot in ('home','work','school')),
  address text not null check(char_length(address) between 3 and 200),
  lat double precision not null check(lat between 28.0 and 28.4),
  lng double precision not null check(lng between -105.7 and -105.2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(passenger_id,slot)
);
create index saved_places_passenger on public.saved_places(passenger_id,updated_at desc);
alter table public.saved_places enable row level security;
revoke all on public.saved_places from anon,authenticated;
grant select on public.saved_places to authenticated;
create policy saved_places_read on public.saved_places for select to authenticated using(
  passenger_id=(select auth.uid()) or (select private.is_admin())
);

alter table public.trips
  add column operations_confirmed_at timestamptz,
  add column operations_confirmed_by uuid references public.profiles(id),
  add column operations_confirmation_note text not null default '' check(char_length(operations_confirmation_note)<=500);
create index trips_schedule_calendar on public.trips(scheduled_at)
  where scheduled_at is not null and status not in ('completed','cancelled');
create index trips_operations_confirmed_by on public.trips(operations_confirmed_by)
  where operations_confirmed_by is not null;

create function private.save_saved_place_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;slot_value text:=payload->>'slot';address_value text:=trim(coalesce(payload->>'address',''));lat_value float8;lng_value float8;result public.saved_places;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>2000 then raise exception 'Solicitud inválida.';end if;
  if slot_value not in ('home','work','school') then raise exception 'Elige Casa, Trabajo o Escuela.';end if;
  lat_value:=(payload->>'lat')::float8;lng_value:=(payload->>'lng')::float8;
  if length(address_value)<3 or not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) then raise exception 'Selecciona primero una ubicación válida dentro de la cobertura.';end if;
  insert into public.saved_places(passenger_id,slot,address,lat,lng)
  values(uid,slot_value,left(address_value,200),lat_value,lng_value)
  on conflict(passenger_id,slot) do update set address=excluded.address,lat=excluded.lat,lng=excluded.lng,updated_at=now()
  returning * into result;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'saved_place_updated',result.id,jsonb_build_object('slot',slot_value));
  return to_jsonb(result);
end $$;
revoke all on function private.save_saved_place_v1(jsonb) from public,anon;
grant execute on function private.save_saved_place_v1(jsonb) to authenticated;

create function private.delete_saved_place_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();slot_value text:=payload->>'slot';removed uuid;
begin
  if uid is null or not exists(select 1 from public.profiles where id=uid and role='passenger' and not suspended) then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
  if slot_value not in ('home','work','school') then raise exception 'Ubicación guardada inválida.';end if;
  delete from public.saved_places where passenger_id=uid and slot=slot_value returning id into removed;
  if removed is not null then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'saved_place_deleted',removed,jsonb_build_object('slot',slot_value));end if;
  return jsonb_build_object('ok',true,'deleted',removed is not null);
end $$;
revoke all on function private.delete_saved_place_v1(jsonb) from public,anon;
grant execute on function private.delete_saved_place_v1(jsonb) to authenticated;

create function private.dashboard_v11(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();base jsonb;p public.profiles;
begin
  select * into p from public.profiles where id=uid;
  base:=private.dashboard_v10(payload);
  return base||jsonb_build_object('saved_places',case when p.role='passenger' then (
    select coalesce(jsonb_agg(to_jsonb(s) order by case s.slot when 'home' then 1 when 'work' then 2 else 3 end),'[]')
    from public.saved_places s where s.passenger_id=uid
  ) else '[]'::jsonb end);
end $$;
revoke all on function private.dashboard_v11(jsonb) from public,anon;
grant execute on function private.dashboard_v11(jsonb) to authenticated;

create function private.scheduled_operations_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();month_value text:=coalesce(nullif(payload->>'month',''),to_char(current_date,'YYYY-MM'));start_value timestamptz;end_value timestamptz;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede consultar la agenda.' using errcode='42501';end if;
  if month_value!~'^20[0-9]{2}-(0[1-9]|1[0-2])$' then raise exception 'Mes de agenda inválido.';end if;
  start_value:=(month_value||'-01')::date::timestamptz;end_value:=start_value+interval '1 month';
  return jsonb_build_object(
    'month',month_value,
    'generated_at',now(),
    'trips',(select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at),'[]') from (
      select t.id,t.status,t.origin,t.destination,t.origin_lat,t.origin_lng,t.dest_lat,t.dest_lng,t.category,
        t.scheduled_at,t.created_at,t.party_size,t.service_notes,t.women_only,t.accessible,t.payment_method,
        t.payment_status,t.fare_cents,t.tip_cents,t.total_cents,t.driver_id,t.schedule_series_id,t.schedule_sequence,
        t.schedule_total,t.operations_confirmed_at,t.operations_confirmation_note,
        passenger.id as passenger_id,passenger.full_name as passenger_name,passenger.phone as passenger_phone,
        driver.full_name as driver_name,driver.phone as driver_phone,d.vehicle,d.plate
      from public.trips t join public.profiles passenger on passenger.id=t.passenger_id
      left join public.profiles driver on driver.id=t.driver_id left join public.drivers d on d.id=t.driver_id
      where t.scheduled_at>=start_value and t.scheduled_at<end_value and t.status not in ('completed','cancelled')
    )x),
    'reminders',(select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at),'[]') from (
      select t.id,t.status,t.scheduled_at,t.origin,t.destination,t.category,t.party_size,t.service_notes,t.women_only,
        t.accessible,t.payment_method,t.payment_status,t.fare_cents,t.tip_cents,t.total_cents,t.driver_id,
        t.schedule_series_id,t.schedule_sequence,t.schedule_total,t.operations_confirmed_at,t.operations_confirmation_note,
        passenger.full_name as passenger_name,passenger.phone as passenger_phone,driver.full_name as driver_name,
        d.vehicle,d.plate,
        case when t.scheduled_at<=now()+interval '15 minutes' then 15 else 30 end as minutes_before
      from public.trips t join public.profiles passenger on passenger.id=t.passenger_id
      left join public.profiles driver on driver.id=t.driver_id left join public.drivers d on d.id=t.driver_id
      where t.scheduled_at>now() and t.scheduled_at<=now()+interval '30 minutes'
        and t.status in ('scheduled','payment_pending') and t.operations_confirmed_at is null
    )x),
    'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (
      select d.id,p.full_name,d.category,d.online from public.drivers d join public.profiles p on p.id=d.id
      where d.approved and d.account_active
    )x)
  );
end $$;
revoke all on function private.scheduled_operations_v1(jsonb) from public,anon;
grant execute on function private.scheduled_operations_v1(jsonb) to authenticated;

create function private.confirm_scheduled_trip_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid:=(payload->>'trip_id')::uuid;note_value text:=trim(coalesce(payload->>'note',''));t public.trips;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede confirmar viajes programados.' using errcode='42501';end if;
  select * into t from public.trips where id=target for update;
  if not found or t.scheduled_at is null or t.status in ('completed','cancelled') then raise exception 'El viaje programado ya no puede confirmarse.';end if;
  if length(note_value)>500 then raise exception 'La nota es demasiado extensa.';end if;
  update public.trips set operations_confirmed_at=now(),operations_confirmed_by=uid,operations_confirmation_note=left(note_value,500),updated_at=now() where id=target returning * into t;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,'scheduled_trip_confirmed',jsonb_build_object('note',left(note_value,500)));
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'scheduled_trip_confirmed',t.id,jsonb_build_object('scheduled_at',t.scheduled_at,'note',left(note_value,500)));
  return jsonb_build_object('ok',true,'confirmed_at',t.operations_confirmed_at);
end $$;
revoke all on function private.confirm_scheduled_trip_v1(jsonb) from public,anon;
grant execute on function private.confirm_scheduled_trip_v1(jsonb) to authenticated;

create function private.operations_report_v2(payload jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb;start_value timestamptz;end_value timestamptz;driver_value uuid:=nullif(payload->>'driver_id','')::uuid;
begin
  base:=private.operations_report_v1(payload);
  start_value:=(base#>>'{meta,from}')::timestamptz;end_value:=(base#>>'{meta,to}')::timestamptz;
  return base||jsonb_build_object('service_mix',(select coalesce(jsonb_agg(to_jsonb(x) order by x.completed desc,x.name),'[]') from (
    select c.id,c.name,count(t.id) as trips,count(t.id) filter(where t.status='completed') as completed,
      coalesce(sum(t.total_cents) filter(where t.status='completed'),0) as gross_cents,
      coalesce(round(avg(t.total_cents) filter(where t.status='completed'))::integer,0) as average_ticket_cents
    from public.categories c left join public.trips t on t.category=c.id
      and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value
      and (driver_value is null or t.driver_id=driver_value)
    group by c.id,c.name
  )x));
end $$;
revoke all on function private.operations_report_v2(jsonb) from public,anon;
grant execute on function private.operations_report_v2(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v11(payload)
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
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
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
   when 'operations_report' then private.operations_report_v2(payload)
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
   when 'scheduled_operations' then private.scheduled_operations_v1(payload)
   when 'confirm_scheduled_trip' then private.confirm_scheduled_trip_v1(payload)
   when 'assign_scheduled_trip' then private.assign_scheduled_trip_v1(payload)
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
