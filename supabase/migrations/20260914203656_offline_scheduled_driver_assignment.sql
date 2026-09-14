-- Scheduling uses operational eligibility, not current browser presence. A
-- reserved driver may be offline today and still receive a future assignment.
drop index public.one_active_trip_per_driver;
create unique index one_active_trip_per_driver on public.trips(driver_id)
where driver_id is not null and status in ('accepted','arrived','in_progress');

create function private.driver_can_cover_category_v1(driver_category text,trip_category text) returns boolean
language sql immutable security invoker set search_path='' as $$
  select case trip_category
    when 'basic' then driver_category in ('basic','large','plus')
    when 'commercial' then driver_category in ('commercial','pickup')
    else driver_category=trip_category
  end
$$;
revoke all on function private.driver_can_cover_category_v1(text,text) from public,anon,authenticated;

create or replace function private.assign_scheduled_trip_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid:=(payload->>'trip_id')::uuid;candidate uuid:=nullif(payload->>'driver_id','')::uuid;t public.trips;d public.drivers;p public.profiles;
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
  select * into p from public.profiles where id=candidate;
  if d.id is null or p.id is null or p.role<>'driver' or p.suspended or not d.approved
    or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then
    raise exception 'El conductor no tiene un expediente vigente para reservar este servicio.';
  end if;
  if not private.driver_can_cover_category_v1(d.category,t.category) then raise exception 'La categoría de la unidad no es compatible con este servicio.';end if;
  if (t.women_only and not d.female_verified) or (t.accessible and not d.accessible_verified) then raise exception 'El conductor no cumple la preferencia del viaje.';end if;
  if not d.account_active and t.scheduled_at<=now()+interval '15 minutes' then raise exception 'Reactiva la cuenta del conductor antes de asignar una salida próxima.';end if;
  if exists(select 1 from public.trips clash where clash.driver_id=candidate and clash.id<>t.id and clash.status in ('scheduled','payment_pending') and abs(extract(epoch from (clash.scheduled_at-t.scheduled_at)))<5400) then raise exception 'El conductor ya tiene un viaje programado muy cercano a este horario.';end if;
  update public.trips set driver_id=candidate,updated_at=now() where id=t.id;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,'scheduled_driver_assigned',jsonb_build_object('driver_id',candidate,'driver_online',d.online,'account_active',d.account_active,'driver_category',d.category));
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'scheduled_trip_assigned',t.id,jsonb_build_object('driver_id',candidate,'scheduled_at',t.scheduled_at,'driver_online',d.online,'account_active',d.account_active,'driver_category',d.category));
  return jsonb_build_object('ok',true,'driver_id',candidate,'driver_online',d.online,'account_active',d.account_active);
end $$;
revoke all on function private.assign_scheduled_trip_v1(jsonb) from public,anon;
grant execute on function private.assign_scheduled_trip_v1(jsonb) to authenticated;

create or replace function private.release_scheduled_trips_v1() returns void
language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  update public.trips t set driver_id=null,updated_at=now()
  where t.status='scheduled' and t.driver_id is not null and t.scheduled_at<=now()+interval '15 minutes'
    and (
      not exists(
        select 1 from public.drivers d join public.profiles p on p.id=d.id
        where d.id=t.driver_id and p.role='driver' and not p.suspended and d.approved and d.account_active
          and d.license_expires>=current_date and d.insurance_expires>=current_date
          and private.driver_can_cover_category_v1(d.category,t.category)
          and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
      )
      or exists(select 1 from public.trips busy where busy.driver_id=t.driver_id and busy.id<>t.id and busy.status in ('accepted','arrived','in_progress'))
    );
  update public.trips t set status='accepted',updated_at=now()
  where t.status='scheduled' and t.driver_id is not null and t.scheduled_at<=now()+interval '15 minutes'
    and (t.payment_method='cash' or t.payment_status='paid');
  update public.trips set status='requested',updated_at=now()
  where status='scheduled' and driver_id is null and scheduled_at<=now()+interval '15 minutes'
    and (payment_method='cash' or payment_status='paid');
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
  end loop;
end $$;
revoke all on function private.release_scheduled_trips_v1() from public,anon,authenticated;

create or replace function private.scheduled_operations_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();month_value text:=coalesce(nullif(payload->>'month',''),to_char(current_date,'YYYY-MM'));start_value timestamptz;end_value timestamptz;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede consultar la agenda.' using errcode='42501';end if;
  if month_value!~'^20[0-9]{2}-(0[1-9]|1[0-2])$' then raise exception 'Mes de agenda inválido.';end if;
  start_value:=(month_value||'-01')::date::timestamptz;end_value:=start_value+interval '1 month';
  return jsonb_build_object(
    'month',month_value,'generated_at',now(),
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
        d.vehicle,d.plate,case when t.scheduled_at<=now()+interval '15 minutes' then 15 else 30 end as minutes_before
      from public.trips t join public.profiles passenger on passenger.id=t.passenger_id
      left join public.profiles driver on driver.id=t.driver_id left join public.drivers d on d.id=t.driver_id
      where t.scheduled_at>now() and t.scheduled_at<=now()+interval '30 minutes'
        and t.status in ('scheduled','payment_pending') and t.operations_confirmed_at is null
    )x),
    'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.connected desc,x.account_active desc,x.full_name),'[]') from (
      select d.id,p.full_name,d.category,d.online,d.account_active,d.vehicle,d.plate,
        d.license_expires>=current_date and d.insurance_expires>=current_date as documents_valid,
        (d.online and exists(select 1 from public.driver_presence presence where presence.driver_id=d.id and presence.heartbeat_at>now()-interval '90 seconds')) as connected
      from public.drivers d join public.profiles p on p.id=d.id
      where p.role='driver' and d.approved and not p.suspended
    )x)
  );
end $$;
revoke all on function private.scheduled_operations_v1(jsonb) from public,anon;
grant execute on function private.scheduled_operations_v1(jsonb) to authenticated;
