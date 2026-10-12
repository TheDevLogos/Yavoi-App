-- Reaching the drop-off is a visible milestone, not a completed payment.
-- It must be recorded independently so the passenger and driver see the same
-- status until cash receipt is confirmed and the canonical completion runs.
create function private.destination_reached_v1(payload jsonb)
returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  trip_value public.trips;
  event_value public.trip_events;
begin
  select * into trip_value from public.trips
  where id=(payload->>'trip_id')::uuid for update;
  if not found or auth.uid() is null or trip_value.driver_id is distinct from auth.uid() then
    raise exception 'No tienes acceso a este viaje.' using errcode='42501';
  end if;
  select * into event_value from public.trip_events
  where trip_id=trip_value.id and event='destination_reached'
  order by id desc limit 1;
  if found then return jsonb_build_object('trip_id',trip_value.id,'event_id',event_value.id,'already_recorded',true); end if;
  if trip_value.status<>'in_progress' then
    raise exception 'El viaje debe estar en curso para registrar la llegada al destino.';
  end if;
  insert into public.trip_events(trip_id,actor_id,event,detail)
  values(trip_value.id,auth.uid(),'destination_reached',jsonb_build_object('source','driver_navigation'))
  returning * into event_value;
  return jsonb_build_object('trip_id',trip_value.id,'event_id',event_value.id,'already_recorded',false);
end $$;
revoke all on function private.destination_reached_v1(jsonb) from public,anon;
grant execute on function private.destination_reached_v1(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_destination_arrival;
create function public.yavoi(command text,payload jsonb default '{}')
returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
  if command='destination_reached' then
    return private.destination_reached_v1(payload);
  end if;
  return public.yavoi_before_destination_arrival(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
