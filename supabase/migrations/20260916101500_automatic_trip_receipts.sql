-- Durable, idempotent delivery queue for the statutory trip receipt.

alter table private.trip_receipt_outbox
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists lease_token uuid,
  add column if not exists leased_at timestamptz,
  add column if not exists provider_message_id text not null default '';

create index if not exists trip_receipt_delivery_queue
  on private.trip_receipt_outbox(next_attempt_at,created_at)
  where status in ('pending','failed','processing');

create function private.trip_receipt_payload_v1(target uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  with receipt as (
    select t.id,t.origin,t.destination,t.total_cents,t.distance_km,t.created_at,t.completed_at,
      r.started_at,r.completion_snapshot,r.assignment_snapshot,u.email,
      coalesce(r.started_at,nullif(r.completion_snapshot->>'started_at','')::timestamptz,
        (select min(e.created_at) from public.trip_events e where e.trip_id=t.id and e.event='in_progress'),t.created_at) as actual_start,
      coalesce(nullif(r.completion_snapshot->>'actual_distance_km','')::numeric,0) as gps_km,
      coalesce(nullif(r.completion_snapshot->>'duration_minutes','')::integer,
        greatest(0,round(extract(epoch from (t.completed_at-coalesce(r.started_at,t.created_at)))/60.0)::integer)) as actual_minutes,
      coalesce(r.assignment_snapshot#>>'{driver,name}',dp.full_name) as driver_name,
      coalesce(r.assignment_snapshot#>>'{driver,photo_path}',dp.avatar_path) as driver_photo_path
    from public.trips t
    join public.trip_regulatory_records r on r.trip_id=t.id
    join auth.users u on u.id=t.passenger_id
    left join public.profiles dp on dp.id=t.driver_id
    where t.id=target and t.status='completed' and t.completed_at is not null
  )
  select jsonb_strip_nulls(jsonb_build_object(
    'trip_id',id,
    'recipient_email',email,
    'receipt_number','YV-'||upper(left(replace(id::text,'-',''),12)),
    'trip',jsonb_build_object(
      'date',actual_start,
      'total_cents',total_cents,
      'duration_minutes',actual_minutes,
      'distance_km',case when gps_km>0 then gps_km else distance_km end,
      'distance_source',case when gps_km>0 then 'gps' else 'estimated_route' end,
      'origin',origin,
      'destination',destination,
      'started_at',actual_start,
      'completed_at',completed_at
    ),
    'driver',jsonb_build_object('name',driver_name,'photo_path',driver_photo_path)
  )) from receipt
$$;
revoke all on function private.trip_receipt_payload_v1(uuid) from public,anon,authenticated;

-- The first compliance migration protected historical trips but intentionally
-- did not emit email work while no provider existed. Queue those receipts now.
insert into private.trip_receipt_outbox(trip_id,recipient_email,payload)
select r.trip_id,u.email,private.trip_receipt_payload_v1(r.trip_id)
from public.trip_regulatory_records r
join public.trips t on t.id=r.trip_id and t.status='completed'
join auth.users u on u.id=r.passenger_id
where r.receipt_status in ('pending','failed') and u.email is not null
on conflict(trip_id) do update set
  recipient_email=excluded.recipient_email,
  payload=excluded.payload,
  status=case when private.trip_receipt_outbox.status='sent' then 'sent' else 'pending' end,
  next_attempt_at=case when private.trip_receipt_outbox.status='sent' then private.trip_receipt_outbox.next_attempt_at else now() end,
  updated_at=now();

create function public.yavoi_receipt_claim(payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid:=nullif(payload->>'trip_id','')::uuid;caller uuid:=nullif(payload->>'caller_id','')::uuid;
  batch_size integer:=least(10,greatest(1,coalesce((payload->>'batch_size')::integer,5)));
  item record;lease uuid;items jsonb:='[]'::jsonb;normalized jsonb;enabled boolean;
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Servicio de entrega no autorizado.' using errcode='42501';end if;
  select receipt_email_enabled into enabled from private.transport_compliance_settings where id;
  if not coalesce(enabled,false) then return '[]'::jsonb;end if;
  if caller is not null and target is null and not exists(select 1 from public.profiles where id=caller and role='admin') then
    raise exception 'El envío por lote requiere Operaciones.' using errcode='42501';
  end if;
  if caller is not null and target is not null and not exists(
    select 1 from public.trips t join public.profiles p on p.id=caller
    where t.id=target and (p.role='admin' or caller in (t.passenger_id,t.driver_id))
  ) then raise exception 'Recibo no disponible.' using errcode='42501';end if;
  for item in
    select o.trip_id from private.trip_receipt_outbox o
    where (target is null or o.trip_id=target) and o.attempts<10
      and (o.status in ('pending','failed') or (o.status='processing' and o.leased_at<now()-interval '10 minutes'))
      and o.next_attempt_at<=now()
    order by o.created_at for update skip locked limit batch_size
  loop
    normalized:=private.trip_receipt_payload_v1(item.trip_id);
    if normalized is null or normalized->>'recipient_email' is null or normalized#>>'{driver,name}' is null or normalized#>>'{driver,photo_path}' is null then
      update private.trip_receipt_outbox set status='failed',attempts=attempts+1,last_error='El recibo no tiene correo, conductor o fotografía.',next_attempt_at=now()+interval '1 day',updated_at=now() where trip_id=item.trip_id;
      update public.trip_regulatory_records set receipt_status='failed',updated_at=now() where trip_id=item.trip_id;
      continue;
    end if;
    lease:=gen_random_uuid();
    update private.trip_receipt_outbox set payload=normalized,status='processing',attempts=attempts+1,lease_token=lease,leased_at=now(),last_error='',updated_at=now() where trip_id=item.trip_id;
    items:=items||jsonb_build_array(normalized||jsonb_build_object('lease_token',lease));
  end loop;
  return items;
end $$;
revoke all on function public.yavoi_receipt_claim(jsonb) from public,anon,authenticated;
grant execute on function public.yavoi_receipt_claim(jsonb) to service_role;

create function public.yavoi_receipt_complete(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid:=(payload->>'trip_id')::uuid;lease uuid:=(payload->>'lease_token')::uuid;
  delivered boolean:=coalesce((payload->>'success')::boolean,false);error_value text:=left(coalesce(payload->>'error',''),1000);
  provider_id text:=left(coalesce(payload->>'provider_message_id',''),200);caller uuid:=nullif(payload->>'caller_id','')::uuid;
  actor uuid;affected integer;
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Servicio de entrega no autorizado.' using errcode='42501';end if;
  if delivered then
    update private.trip_receipt_outbox set status='sent',delivered_at=now(),provider_message_id=provider_id,last_error='',lease_token=null,leased_at=null,updated_at=now()
      where trip_id=target and lease_token=lease and status='processing';
    get diagnostics affected=row_count;
    if affected<>1 then raise exception 'La entrega ya fue procesada o la reserva expiró.';end if;
    update public.trip_regulatory_records set receipt_status='sent',receipt_sent_at=now(),updated_at=now() where trip_id=target;
    select coalesce(caller,(select claimed_by from private.admin_enrollment where claimed_by is not null order by claimed_at limit 1)) into actor;
    if actor is not null then insert into public.audit_log(actor_id,action,target_id,detail) values(actor,'trip_receipt_sent',target,jsonb_build_object('provider','gmail','message_id',provider_id,'automatic',caller is null));end if;
    insert into public.trip_events(trip_id,actor_id,event,detail) values(target,caller,'receipt_email_sent',jsonb_build_object('provider','gmail','message_id',provider_id));
  else
    update private.trip_receipt_outbox set status='failed',last_error=coalesce(nullif(error_value,''),'Fallo temporal del proveedor'),
      next_attempt_at=now()+least(interval '24 hours',interval '5 minutes'*greatest(1,attempts*attempts)),lease_token=null,leased_at=null,updated_at=now()
      where trip_id=target and lease_token=lease and status='processing';
    get diagnostics affected=row_count;
    if affected<>1 then raise exception 'La entrega ya fue procesada o la reserva expiró.';end if;
    update public.trip_regulatory_records set receipt_status='failed',updated_at=now() where trip_id=target;
  end if;
  return jsonb_build_object('ok',true,'status',case when delivered then 'sent' else 'failed' end);
end $$;
revoke all on function public.yavoi_receipt_complete(jsonb) from public,anon,authenticated;
grant execute on function public.yavoi_receipt_complete(jsonb) to service_role;
