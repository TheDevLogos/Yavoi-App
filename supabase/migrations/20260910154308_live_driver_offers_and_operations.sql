-- Targeted driver offers, browser-safe recovery and a live operations view.
alter table public.quotes add column party_size integer not null default 1 check(party_size between 1 and 8),
 add column service_notes text not null default '' check(char_length(service_notes)<=500);
alter table public.trips add column party_size integer not null default 1 check(party_size between 1 and 8),
 add column service_notes text not null default '' check(char_length(service_notes)<=500);
alter table public.driver_presence add column heartbeat_at timestamptz not null default now(),
 add column session_id uuid;

create table public.trip_offers (
 id uuid primary key default gen_random_uuid(),
 trip_id uuid not null references public.trips(id) on delete cascade,
 driver_id uuid not null references public.drivers(id) on delete cascade,
 status text not null default 'offered' check(status in ('offered','accepted','rejected','expired','cancelled')),
 offered_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '60 seconds',
 responded_at timestamptz,
 response_reason text not null default '' check(char_length(response_reason)<=200),
 unique(trip_id,driver_id)
);
create unique index one_open_offer_per_trip on public.trip_offers(trip_id) where status='offered';
create index trip_offers_driver_open on public.trip_offers(driver_id,expires_at) where status='offered';
create index trip_offers_trip_date on public.trip_offers(trip_id,offered_at desc);

create table public.ride_drafts (
 passenger_id uuid primary key references public.profiles(id) on delete cascade,
 payload jsonb not null default '{}',
 updated_at timestamptz not null default now(),
 check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=6000)
);

alter table public.trip_offers enable row level security;
alter table public.ride_drafts enable row level security;
revoke all on public.trip_offers,public.ride_drafts from anon,authenticated;
grant select on public.trip_offers,public.ride_drafts to authenticated;
create policy trip_offers_read on public.trip_offers for select to authenticated using(
 driver_id=(select auth.uid()) or (select private.is_admin())
);
create policy ride_drafts_read on public.ride_drafts for select to authenticated using(
 passenger_id=(select auth.uid())
);
create policy yavoi_offer_avatar_read on storage.objects for select to authenticated using(
 bucket_id='yavoi-avatars' and exists(
  select 1 from public.trip_offers o join public.trips t on t.id=o.trip_id
  where o.driver_id=(select auth.uid()) and o.status='offered' and o.expires_at>now()
    and (storage.foldername(name))[1]=t.passenger_id::text
 )
);

create or replace function private.auto_assign_trip(target_trip uuid,preferred uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare t public.trips;chosen uuid;
begin
 select * into t from public.trips where id=target_trip for update;
 if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id;end if;
 update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado'
  where trip_id=t.id and status='offered' and expires_at<=now();
 select driver_id into chosen from public.trip_offers where trip_id=t.id and status='offered' and expires_at>now();
 if chosen is not null then return chosen;end if;
 select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
 where d.online and d.approved and d.account_active and d.category=t.category
   and dp.heartbeat_at>now()-interval '90 seconds'
   and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
   and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
   and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status not in ('completed','cancelled'))
   and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
   and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now())
 order by case when d.id=preferred then 0 else 1 end,
   private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.heartbeat_at desc
 for update of d skip locked limit 1;
 if chosen is not null then
   insert into public.trip_offers(trip_id,driver_id) values(t.id,chosen);
   insert into public.trip_events(trip_id,actor_id,event,detail)
   values(t.id,chosen,'offer_sent',jsonb_build_object('preferred',chosen=preferred,'expires_in_seconds',60));
 end if;
 return chosen;
end $$;
revoke all on function private.auto_assign_trip(uuid,uuid) from public,anon,authenticated;

create function private.expire_trip_offers() returns void language plpgsql security definer set search_path='' as $$
declare item record;
begin
 for item in select distinct trip_id from public.trip_offers where status='offered' and expires_at<=now() limit 50 loop
   update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado'
    where trip_id=item.trip_id and status='offered' and expires_at<=now();
   perform private.auto_assign_trip(item.trip_id,(select preferred_driver_id from public.trips where id=item.trip_id));
 end loop;
end $$;
revoke all on function private.expire_trip_offers() from public,anon,authenticated;

create function private.quote_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;q public.quotes;party integer;notes text;capacity integer;
begin
 party:=coalesce((payload->>'party_size')::integer,1);
 notes:=trim(coalesce(payload->>'service_notes',''));
 if party not between 1 and 8 then raise exception 'Indica entre 1 y 8 personas.';end if;
 if char_length(notes)>500 then raise exception 'Las indicaciones pueden tener hasta 500 caracteres.';end if;
 select seats into capacity from public.categories where id=payload->>'category' and active;
 if capacity is null or party>capacity then raise exception 'La categoría elegida no tiene espacio para todas las personas.';end if;
 result:=private.quote_v2(payload);
 update public.quotes set party_size=party,service_notes=left(notes,500) where id=(result->>'id')::uuid returning * into q;
 return to_jsonb(q);
end $$;
revoke all on function private.quote_v3(jsonb) from public,anon;
grant execute on function private.quote_v3(jsonb) to authenticated;

create function private.request_trip_v4(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;q public.quotes;
begin
 result:=private.request_trip_v3(payload);
 select * into t from public.trips where id=(result->>'id')::uuid for update;
 select * into q from public.quotes where id=t.quote_id;
 update public.trips set party_size=q.party_size,service_notes=q.service_notes,updated_at=now() where id=t.id returning * into t;
 delete from public.ride_drafts where passenger_id=t.passenger_id;
 return to_jsonb(t)||jsonb_build_object('payment_id',result->'payment_id','offered_driver_id',result->'assigned_driver_id');
end $$;
revoke all on function private.request_trip_v4(jsonb) from public,anon;
grant execute on function private.request_trip_v4(jsonb) to authenticated;

create function private.presence_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result jsonb;session_value uuid;
begin
 result:=private.presence_v2(payload);
 session_value:=nullif(payload->>'session_id','')::uuid;
 update public.driver_presence set heartbeat_at=now(),session_id=coalesce(session_value,session_id),
   heading=nullif(payload->>'heading','')::float8,speed=nullif(payload->>'speed','')::float8,updated_at=now()
  where driver_id=uid;
 perform private.expire_trip_offers();
 return result||jsonb_build_object('heartbeat_at',now());
end $$;
revoke all on function private.presence_v3(jsonb) from public,anon;
grant execute on function private.presence_v3(jsonb) to authenticated;

create or replace function private.sync_driver_presence() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.driver_presence(driver_id,lat,lng,accuracy,heading,speed,heartbeat_at,updated_at)
 values(new.driver_id,new.lat,new.lng,new.accuracy,new.heading,new.speed,now(),new.updated_at)
 on conflict(driver_id) do update set lat=excluded.lat,lng=excluded.lng,accuracy=excluded.accuracy,
  heading=excluded.heading,speed=excluded.speed,heartbeat_at=now(),updated_at=excluded.updated_at;
 return new;
end $$;
revoke all on function private.sync_driver_presence() from public,anon,authenticated;

create or replace function private.available_units_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;lat_value float8;lng_value float8;category_value text;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 lat_value:=(payload->>'lat')::float8;lng_value:=(payload->>'lng')::float8;category_value:=payload->>'category';
 if not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) then raise exception 'Ubicación fuera de cobertura.';end if;
 return (select coalesce(jsonb_agg(to_jsonb(x) order by x.pickup_km),'[]') from (
   select d.id as unit_id,d.category,round(dp.lat::numeric,4)::float8 as lat,round(dp.lng::numeric,4)::float8 as lng,
     round((private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22)::numeric,2) as pickup_km,
     greatest(3,ceil(private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22/26*60)::integer+2) as pickup_minutes,
     d.female_verified,d.accessible_verified
   from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where d.online and d.approved and d.account_active and d.category=category_value
     and dp.heartbeat_at>now()-interval '90 seconds'
     and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
     and (not coalesce((payload->>'women_only')::boolean,false) or d.female_verified)
     and (not coalesce((payload->>'accessible')::boolean,false) or d.accessible_verified)
     and not exists(select 1 from public.trips t where t.driver_id=d.id and t.status not in ('completed','cancelled'))
     and not exists(select 1 from public.trip_offers o where o.driver_id=d.id and o.status='offered' and o.expires_at>now())
   order by pickup_km limit 20
 )x);
end $$;

create function private.offers_v4(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
   select o.id as offer_id,o.expires_at,t.id,t.origin,t.destination,t.fare_cents,t.fare_cents-t.commission_cents as net_cents,
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
revoke all on function private.offers_v4(jsonb) from public,anon;
grant execute on function private.offers_v4(jsonb) to authenticated;

create function private.accept_offer_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();o public.trip_offers;t public.trips;d public.drivers;
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
 update public.trip_offers set status='accepted',responded_at=now() where id=o.id;
 update public.trips set driver_id=uid,status='accepted',updated_at=now() where id=t.id returning * into t;
 insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,'accepted',jsonb_build_object('offer_id',o.id));
 return to_jsonb(t);
end $$;
revoke all on function private.accept_offer_v1(jsonb) from public,anon;
grant execute on function private.accept_offer_v1(jsonb) to authenticated;

create function private.reject_offer_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();o public.trip_offers;next_driver uuid;reason text;
begin
 select * into o from public.trip_offers where id=(payload->>'offer_id')::uuid and driver_id=uid for update;
 if uid is null or not found or o.status<>'offered' then raise exception 'La solicitud ya no está disponible.' using errcode='42501';end if;
 reason:=left(trim(coalesce(payload->>'reason','No disponible')),200);
 update public.trip_offers set status='rejected',responded_at=now(),response_reason=reason where id=o.id;
 insert into public.trip_events(trip_id,actor_id,event,detail) values(o.trip_id,uid,'offer_rejected',jsonb_build_object('reason',reason));
 next_driver:=private.auto_assign_trip(o.trip_id,(select preferred_driver_id from public.trips where id=o.trip_id));
 return jsonb_build_object('ok',true,'next_driver_notified',next_driver is not null);
end $$;
revoke all on function private.reject_offer_v1(jsonb) from public,anon;
grant execute on function private.reject_offer_v1(jsonb) to authenticated;

create function private.availability_v4(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result jsonb;item record;going_online boolean;
begin
 going_online:=coalesce((payload->>'online')::boolean,false);
 result:=private.availability_v3(payload);
 if not going_online then
  for item in update public.trip_offers set status='rejected',responded_at=now(),response_reason='Conductor desconectado'
   where driver_id=uid and status='offered' returning trip_id loop
    perform private.auto_assign_trip(item.trip_id,(select preferred_driver_id from public.trips where id=item.trip_id));
  end loop;
  delete from public.driver_presence where driver_id=uid;
 end if;
 return result;
end $$;
revoke all on function private.availability_v4(jsonb) from public,anon;
grant execute on function private.availability_v4(jsonb) to authenticated;

create function private.save_ride_draft_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;clean jsonb;party integer;lat1 float8;lng1 float8;lat2 float8;lng2 float8;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 party:=coalesce((payload->>'party_size')::integer,1);
 if party not between 1 and 8 or char_length(coalesce(payload->>'service_notes',''))>500 then raise exception 'Borrador inválido.';end if;
 lat1:=nullif(payload->>'origin_lat','')::float8;lng1:=nullif(payload->>'origin_lng','')::float8;
 lat2:=nullif(payload->>'dest_lat','')::float8;lng2:=nullif(payload->>'dest_lng','')::float8;
 if (lat1 is not null and not(lat1 between 28.0 and 28.4 and lng1 between -105.7 and -105.2)) or
    (lat2 is not null and not(lat2 between 28.0 and 28.4 and lng2 between -105.7 and -105.2)) then raise exception 'Borrador fuera de cobertura.';end if;
 clean:=jsonb_strip_nulls(jsonb_build_object(
  'origin',left(coalesce(payload->>'origin',''),200),'origin_lat',lat1,'origin_lng',lng1,
  'destination',left(coalesce(payload->>'destination',''),200),'dest_lat',lat2,'dest_lng',lng2,
  'category',left(coalesce(payload->>'category','basic'),30),'party_size',party,
  'service_notes',left(coalesce(payload->>'service_notes',''),500),
  'women_only',coalesce((payload->>'women_only')::boolean,false),'accessible',coalesce((payload->>'accessible')::boolean,false),
  'scheduled_at',nullif(payload->>'scheduled_at','')
 ));
 insert into public.ride_drafts(passenger_id,payload) values(uid,clean)
 on conflict(passenger_id) do update set payload=excluded.payload,updated_at=now();
 return jsonb_build_object('ok',true,'updated_at',now());
end $$;
revoke all on function private.save_ride_draft_v1(jsonb) from public,anon;
grant execute on function private.save_ride_draft_v1(jsonb) to authenticated;

create function private.clear_ride_draft_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 delete from public.ride_drafts where passenger_id=auth.uid();
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.clear_ride_draft_v1(jsonb) from public,anon;
grant execute on function private.clear_ride_draft_v1(jsonb) to authenticated;

create function private.dashboard_v4(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;waiting record;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 perform private.expire_trip_offers();
 for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
  perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
 end loop;
 base:=private.dashboard_v3(payload);
 return base||jsonb_build_object(
  'ride_draft',case when p.role='passenger' then (select draft.payload from public.ride_drafts draft where draft.passenger_id=uid) else null end,
  'operations_units',case when p.role='admin' then (select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (
    select d.id as driver_id,pr.full_name,pr.avatar_path,d.online,d.approved,d.account_active,d.category,d.vehicle,d.vehicle_make,
      d.vehicle_model,d.vehicle_year,d.vehicle_color,d.plate,dp.lat,dp.lng,dp.accuracy,dp.heading,dp.speed,
      dp.heartbeat_at,dp.updated_at,(dp.heartbeat_at>now()-interval '90 seconds') as presence_fresh,
      t.id as trip_id,t.status as trip_status,t.origin,t.destination,t.payment_method,t.payment_status,t.fare_cents,t.tip_cents,t.total_cents,
      passenger.full_name as passenger_name,
      case when t.id is null then '[]'::jsonb else (select coalesce(jsonb_agg(to_jsonb(h) order by h.captured_at),'[]') from (
        select lat,lng,heading,speed,captured_at from public.location_history where trip_id=t.id order by captured_at desc limit 100
      )h) end as route_history
    from public.drivers d join public.profiles pr on pr.id=d.id left join public.driver_presence dp on dp.driver_id=d.id
    left join lateral (select active_trip.* from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status not in ('completed','cancelled') order by active_trip.updated_at desc limit 1)t on true
    left join public.profiles passenger on passenger.id=t.passenger_id
  )x) else '[]'::jsonb end
 );
end $$;
revoke all on function private.dashboard_v4(jsonb) from public,anon;
grant execute on function private.dashboard_v4(jsonb) to authenticated;

create function private.trip_v4(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;t public.trips;base jsonb;operations jsonb;
begin
 select * into p from public.profiles where id=uid;
 select * into t from public.trips where id=(payload->>'trip_id')::uuid;
 base:=private.trip_v3(payload);
 if p.role='admin' then
  operations:=jsonb_build_object(
   'passenger_phone',(select phone from public.profiles where id=t.passenger_id),
   'driver_phone',(select phone from public.profiles where id=t.driver_id),
   'ledger',(select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at),'[]') from public.ledger l where l.trip_id=t.id),
   'payment_events',(select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at),'[]') from public.payment_events ev join public.payments pay on pay.id=ev.payment_id where pay.trip_id=t.id),
   'paid_cents',(select coalesce(sum(amount_cents),0) from public.payments where trip_id=t.id and kind='ride' and status='approved'),
   'driver_net_cents',(select coalesce(sum(amount_cents),0) from public.ledger where trip_id=t.id and user_id=t.driver_id)
  );
 end if;
 return base||jsonb_build_object(
  'matching',jsonb_build_object('attempts',(select count(*) from public.trip_offers where trip_id=t.id),'offer_expires_at',(select expires_at from public.trip_offers where trip_id=t.id and status='offered')),
  'operations',operations
 );
end $$;
revoke all on function private.trip_v4(jsonb) from public,anon;
grant execute on function private.trip_v4(jsonb) to authenticated;

create function private.sync_trip_offer_status() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status<>old.status and new.status<>'requested' then
  update public.trip_offers set status='cancelled',responded_at=coalesce(responded_at,now()),response_reason=case when new.status='accepted' then 'Otra oferta aceptada' else 'Viaje no disponible' end
   where trip_id=new.id and status='offered';
 end if;
 return new;
end $$;
revoke all on function private.sync_trip_offer_status() from public,anon,authenticated;
create trigger sync_trip_offer_status after update of status on public.trips for each row execute function private.sync_trip_offer_status();

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v4(payload)
   when 'quote' then private.quote_v3(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v4(payload)
   when 'trip' then private.trip_v4(payload)
   when 'driver_profile' then private.driver_profile_v3(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v4(payload)
   when 'accept' then private.accept_offer_v1(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'transition' then private.transition_v3(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v1(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'category' then private.category_v2(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

alter publication supabase_realtime add table public.trip_offers;
