-- Apply the ordinary passenger cancellation window when a scheduled ride enters
-- its 15-minute activation period, while keeping advance cancellations free.
create or replace function private.cancellation_terms_v1(target_trip uuid,target_actor uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t public.trips;p public.profiles;settings private.app_settings;accepted_at timestamptz;
  fee_value integer:=0;refund_value integer:=0;grace_until timestamptz;activation_at timestamptz;explanation text;
begin
  select * into p from public.profiles where id=target_actor;
  select * into t from public.trips where id=target_trip;
  select * into settings from private.app_settings where id;
  if p.id is null or t.id is null or p.suspended or (t.passenger_id is distinct from target_actor and t.driver_id is distinct from target_actor and p.role<>'admin') then
    raise exception 'No tienes acceso a este viaje.' using errcode='42501';
  end if;
  if t.status in ('completed','cancelled') then raise exception 'El viaje ya finalizó.';end if;
  if t.status='in_progress' and p.role<>'admin' then raise exception 'Durante el recorrido usa Reportar viaje o Emergencias 911.';end if;
  if p.role='passenger' and t.driver_id is not null then
    select max(created_at) into accepted_at from public.trip_events where trip_id=t.id and event='accepted';
    if t.status='scheduled' and t.scheduled_at is not null then
      activation_at:=t.scheduled_at-interval '15 minutes';
      grace_until:=activation_at+make_interval(secs=>settings.cancellation_grace_seconds);
      if now()<activation_at then
        explanation:='El viaje sigue en su periodo gratuito previo a la activación y no genera cargo.';
      elsif now()>grace_until then
        fee_value:=settings.cancellation_fee_cents;
        explanation:='La salida programada ya entró en operación y terminó la gracia de 2 minutos. La cuota compensa la unidad reservada.';
      else
        explanation:='La salida programada está dentro de la gracia gratuita de 2 minutos desde su activación.';
      end if;
    else
      grace_until:=accepted_at+make_interval(secs=>settings.cancellation_grace_seconds);
      if t.status='arrived' then
        fee_value:=settings.arrived_cancellation_fee_cents;
        explanation:='La unidad ya llegó al punto de partida. La cuota protege el tiempo y traslado del conductor.';
      elsif t.status='accepted' and (grace_until is null or now()>grace_until) then
        fee_value:=settings.cancellation_fee_cents;
        explanation:='Terminó la gracia de 2 minutos después de la asignación. La cuota compensa parte del traslado del conductor.';
      else
        explanation:='Esta cancelación está dentro del periodo gratuito y no genera cargo.';
      end if;
    end if;
  elsif p.role='passenger' then
    explanation:='Aún no hay un conductor asignado; puedes cancelar sin cargo.';
  elsif p.role='driver' then
    explanation:='La cancelación del conductor no genera cuota al pasajero y queda registrada para seguimiento de confiabilidad.';
  else
    explanation:='Operaciones puede cancelar por seguridad o soporte sin generar una cuota automática al pasajero.';
  end if;
  fee_value:=least(greatest(fee_value,0),greatest(coalesce(t.total_cents,t.fare_cents,0),0));
  if t.payment_method='card' and t.payment_status='paid' then refund_value:=greatest(coalesce(t.total_cents,t.fare_cents,0)-fee_value,0);end if;
  return jsonb_build_object(
    'trip_id',t.id,'fee_cents',fee_value,'refund_cents',refund_value,'payment_method',t.payment_method,
    'activation_at',activation_at,'grace_until',grace_until,
    'grace_remaining_seconds',case when grace_until is null then 0 else greatest(0,extract(epoch from grace_until-now())::integer) end,
    'explanation',explanation,'policy_version','2026-09-11-cancelaciones','actor_role',p.role
  );
end $$;
revoke all on function private.cancellation_terms_v1(uuid,uuid) from public,anon,authenticated;
