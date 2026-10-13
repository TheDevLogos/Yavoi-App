-- Native navigation can retry an action when Android resumes the activity or
-- a network response arrives late.  Treat an already-applied state as success
-- so the driver never needs to tap arrival or completion twice.
create or replace function private.navigation_action_v1(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid := auth.uid();
  target uuid := (payload->>'trip_id')::uuid;
  action_value text := lower(trim(coalesce(payload->>'action','')));
  trip_value public.trips;
  event_value public.trip_events;
begin
  select * into trip_value from public.trips where id=target for update;
  if uid is null or not found or trip_value.driver_id is distinct from uid then
    raise exception 'No tienes acceso a este viaje.' using errcode='42501';
  end if;

  if action_value='arrive' then
    if trip_value.status='accepted' then
      return private.transition_v11(jsonb_build_object('trip_id',target,'status','arrived','message','Llegada avisada al pasajero.'));
    end if;
    if trip_value.status in ('arrived','in_progress','completed') then
      return to_jsonb(trip_value)||jsonb_build_object('already_applied',true);
    end if;
    raise exception 'La llegada ya no está disponible para este viaje.';
  end if;

  if action_value='start' then
    if trip_value.status='arrived' then
      return private.transition_v11(jsonb_build_object('trip_id',target,'status','in_progress','message','Viaje iniciado.'));
    end if;
    if trip_value.status in ('in_progress','completed') then
      return to_jsonb(trip_value)||jsonb_build_object('already_applied',true);
    end if;
    raise exception 'Confirma primero que llegaste al punto de recolección.';
  end if;

  if action_value='destination_reached' then
    if trip_value.status='in_progress' then
      return private.destination_reached_v1(jsonb_build_object('trip_id',target));
    end if;
    if trip_value.status='completed' or exists(select 1 from public.trip_events where trip_id=target and event='destination_reached') then
      select * into event_value from public.trip_events where trip_id=target and event='destination_reached' order by id desc limit 1;
      return jsonb_build_object('trip_id',target,'event_id',event_value.id,'already_recorded',true);
    end if;
    raise exception 'El viaje debe estar en curso para confirmar la llegada al destino.';
  end if;

  if action_value='complete' then
    if trip_value.status='in_progress' then
      return private.transition_v11(jsonb_build_object('trip_id',target,'status','completed','cash_received',true,'message','Viaje finalizado.'));
    end if;
    if trip_value.status='completed' then
      return to_jsonb(trip_value)||jsonb_build_object('already_applied',true);
    end if;
    raise exception 'Inicia el viaje antes de finalizarlo.';
  end if;

  raise exception 'Acción de navegación no válida.';
end $$;

revoke all on function private.navigation_action_v1(jsonb) from public, anon;
grant execute on function private.navigation_action_v1(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_navigation_actions;
create function public.yavoi(command text, payload jsonb default '{}')
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
begin
  if command='navigation_action' then
    return private.navigation_action_v1(payload);
  end if;
  return public.yavoi_before_navigation_actions(command,payload);
end $$;

revoke all on function public.yavoi(text,jsonb) from public, anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
