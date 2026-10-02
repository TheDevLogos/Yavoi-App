create table public.trip_fare_adjustments (
 id uuid primary key default gen_random_uuid(), trip_id uuid not null references public.trips(id),
 proposed_by uuid not null references public.profiles(id), reason text not null check(reason in ('waiting','detour','route_change','extra_pickup')),
 amount_cents integer not null check(amount_cents between 1 and 100000), status text not null default 'pending' check(status in ('pending','accepted','declined')),
 decided_by uuid references public.profiles(id), decided_at timestamptz, created_at timestamptz not null default now()
);
create index trip_fare_adjustments_trip on public.trip_fare_adjustments(trip_id,created_at);
alter table public.trip_fare_adjustments enable row level security;
revoke all on public.trip_fare_adjustments from public,anon,authenticated;
create policy trip_fare_adjustments_rpc_only on public.trip_fare_adjustments for all to public using(false) with check(false);

create function private.trip_fare_adjustment_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.trips; adjustment public.trip_fare_adjustments; action_value text:=payload->>'action'; reason_value text:=payload->>'reason'; amount integer:=coalesce((payload->>'amount_cents')::integer,0); decision text:=payload->>'decision';
begin
 select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
 if not found or auth.uid() not in (t.passenger_id,t.driver_id) or t.status not in ('accepted','arrived','in_progress') then raise exception 'El ajuste sólo puede solicitarse por las personas de un viaje activo.'; end if;
 if action_value='propose' then
   if reason_value not in ('waiting','detour','route_change','extra_pickup') or amount<1 or amount>100000 then raise exception 'Selecciona motivo e importe válidos.'; end if;
   insert into public.trip_fare_adjustments(trip_id,proposed_by,reason,amount_cents) values(t.id,auth.uid(),reason_value,amount) returning * into adjustment;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'fare_adjustment_proposed',jsonb_build_object('adjustment_id',adjustment.id,'reason',reason_value,'amount_cents',amount));
 elsif action_value='decide' then
   select * into adjustment from public.trip_fare_adjustments where id=(payload->>'adjustment_id')::uuid and trip_id=t.id for update;
   if not found or adjustment.status<>'pending' or adjustment.proposed_by=auth.uid() or decision not in ('accepted','declined') then raise exception 'No puedes resolver este ajuste.'; end if;
   update public.trip_fare_adjustments set status=decision,decided_by=auth.uid(),decided_at=now() where id=adjustment.id returning * into adjustment;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'fare_adjustment_'||decision,jsonb_build_object('adjustment_id',adjustment.id,'reason',adjustment.reason,'amount_cents',adjustment.amount_cents));
 else raise exception 'Acción de ajuste inválida.'; end if;
 return to_jsonb(adjustment);
end $$;
revoke all on function private.trip_fare_adjustment_v1(jsonb) from public,anon;
grant execute on function private.trip_fare_adjustment_v1(jsonb) to authenticated;

create or replace function private.trip_v15(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare base jsonb:=private.trip_v14(payload); target uuid:=(payload->>'trip_id')::uuid;
begin
 return base || jsonb_build_object('fare_adjustments',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.trip_fare_adjustments a where a.trip_id=target),'[]'::jsonb),'accepted_adjustments_cents',coalesce((select sum(amount_cents) from public.trip_fare_adjustments where trip_id=target and status='accepted'),0));
end $$;
revoke all on function private.trip_v15(jsonb) from public,anon;
grant execute on function private.trip_v15(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_trip_fare_adjustments;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$ begin
 if command='trip' then return private.trip_v15(payload); end if;
 if command='fare_adjustment' then return private.trip_fare_adjustment_v1(payload); end if;
 return public.yavoi_before_trip_fare_adjustments(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
