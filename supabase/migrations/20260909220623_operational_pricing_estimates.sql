-- Server-owned price estimates. Distances are clearly marked as estimates until
-- a road-routing provider is connected.
alter table public.categories add column minute_cents integer not null default 180;
alter table public.categories add column minimum_cents integer not null default 5500;
alter table public.categories add column booking_fee_cents integer not null default 900;
alter table public.categories add constraint category_minute_cents check (minute_cents between 0 and 10000);
alter table public.categories add constraint category_minimum_cents check (minimum_cents between 0 and 100000);
alter table public.categories add constraint category_booking_fee check (booking_fee_cents between 0 and 50000);

update public.categories set minute_cents=160,minimum_cents=5900,booking_fee_cents=900 where id='basic';
update public.categories set minute_cents=210,minimum_cents=7900,booking_fee_cents=1100 where id='large';
update public.categories set minute_cents=230,minimum_cents=8900,booking_fee_cents=1200 where id='commercial';
update public.categories set minute_cents=240,minimum_cents=8500,booking_fee_cents=1200 where id='plus';
update public.categories set minute_cents=270,minimum_cents=10900,booking_fee_cents=1400 where id='pickup';

alter table public.quotes add column direct_distance_km numeric not null default 0;
alter table public.quotes add column pickup_distance_km numeric not null default 0;
alter table public.quotes add column pickup_eta_minutes integer not null default 5;
alter table public.quotes add column trip_eta_minutes integer not null default 5;
alter table public.quotes add column service_zone text not null default 'urban' check(service_zone in ('central','urban','regional'));
alter table public.quotes add column route_factor numeric not null default 1.22;
alter table public.quotes add column zone_surcharge_cents integer not null default 0;
alter table public.quotes add column booking_fee_cents integer not null default 0;
alter table public.quotes add column accessibility_surcharge_cents integer not null default 0;
alter table public.quotes add column estimate_source text not null default 'zone_reference' check(estimate_source in ('nearby_online_unit','zone_reference'));
alter table public.quotes add column pricing_version text not null default 'delicias-pilot-2026-09';

alter table public.trips add column distance_km numeric;
alter table public.trips add column pickup_distance_km numeric;
alter table public.trips add column pickup_eta_minutes integer;
alter table public.trips add column trip_eta_minutes integer;
alter table public.trips add column service_zone text check(service_zone in ('central','urban','regional'));
alter table public.trips add column estimate_source text check(estimate_source in ('nearby_online_unit','zone_reference'));
alter table public.trips add column pricing_version text;
alter table public.trips add column zone_surcharge_cents integer not null default 0;
alter table public.trips add column booking_fee_cents integer not null default 0;
alter table public.trips add column accessibility_surcharge_cents integer not null default 0;

create table public.driver_presence (
 driver_id uuid primary key references public.drivers(id) on delete cascade,
 lat double precision not null check(lat between -90 and 90),
 lng double precision not null check(lng between -180 and 180),
 accuracy double precision not null check(accuracy between 0 and 10000),
 updated_at timestamptz not null default now()
);
alter table public.driver_presence enable row level security;
revoke all on public.driver_presence from anon,authenticated;
grant select on public.driver_presence to authenticated;
create policy driver_presence_own on public.driver_presence for select to authenticated
 using(driver_id=(select auth.uid()) or (select private.is_admin()));
create index driver_presence_fresh on public.driver_presence(updated_at desc);

create function private.haversine_km(lat1 double precision,lng1 double precision,lat2 double precision,lng2 double precision)
returns numeric language sql immutable set search_path='' as $$
 select round((6371*2*asin(sqrt(least(1,power(sin(radians(lat2-lat1)/2),2)+cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2)))))::numeric,3)
$$;
revoke all on function private.haversine_km(double precision,double precision,double precision,double precision) from public,anon,authenticated;

create function private.service_zone(lat double precision,lng double precision)
returns text language sql immutable set search_path='' as $$
 select case when private.haversine_km(28.1902,-105.4701,lat,lng)<=4 then 'central'
             when private.haversine_km(28.1902,-105.4701,lat,lng)<=8 then 'urban'
             else 'regional' end
$$;
revoke all on function private.service_zone(double precision,double precision) from public,anon,authenticated;

create function private.copy_quote_estimate() returns trigger language plpgsql security definer set search_path='' as $$
declare q public.quotes;
begin
 select * into q from public.quotes where id=new.quote_id;
 if not found or q.passenger_id<>new.passenger_id then raise exception 'Cotización inválida.';end if;
 new.distance_km:=q.distance_km;
 new.pickup_distance_km:=q.pickup_distance_km;
 new.pickup_eta_minutes:=q.pickup_eta_minutes;
 new.trip_eta_minutes:=q.trip_eta_minutes;
 new.service_zone:=q.service_zone;
 new.estimate_source:=q.estimate_source;
 new.pricing_version:=q.pricing_version;
 new.zone_surcharge_cents:=q.zone_surcharge_cents;
 new.booking_fee_cents:=q.booking_fee_cents;
 new.accessibility_surcharge_cents:=q.accessibility_surcharge_cents;
 return new;
end $$;
revoke all on function private.copy_quote_estimate() from public,anon,authenticated;
create trigger copy_trip_quote_estimate before insert on public.trips for each row execute function private.copy_quote_estimate();

create function private.quote_v2(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;c public.categories;q public.quotes;
 lat1 float8;lng1 float8;lat2 float8;lng2 float8;direct_km numeric;road_km numeric;pickup_km numeric;
 zone_name text;route_factor_value numeric;speed_kmh numeric;pickup_minutes integer;trip_minutes integer;
 fare integer;zone_fee integer;access_fee integer;source_name text:='zone_reference';ts timestamptz;
begin
 if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 select * into p from public.profiles where id=uid;
 if not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 if not p.onboarding_complete then raise exception 'Completa tu perfil para continuar.';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 if (select count(*) from public.quotes where passenger_id=uid and created_at>now()-interval '1 minute')>=15 then raise exception 'Espera un minuto antes de volver a cotizar.';end if;
 lat1:=(payload->>'origin_lat')::float8;lng1:=(payload->>'origin_lng')::float8;lat2:=(payload->>'dest_lat')::float8;lng2:=(payload->>'dest_lng')::float8;
 if lat1 is null or lng1 is null or lat2 is null or lng2 is null or not(lat1 between 28.0 and 28.4 and lat2 between 28.0 and 28.4 and lng1 between -105.7 and -105.2 and lng2 between -105.7 and -105.2) then raise exception 'Selecciona puntos dentro de la cobertura de Delicias y Meoqui.';end if;
 if length(trim(coalesce(payload->>'origin','')))<3 or length(trim(coalesce(payload->>'destination','')))<3 then raise exception 'Indica las direcciones.';end if;
 select * into c from public.categories where id=payload->>'category' and active;
 if not found then raise exception 'Categoría no disponible.';end if;
 direct_km:=private.haversine_km(lat1,lng1,lat2,lng2);if direct_km<0.1 then raise exception 'El destino debe estar al menos a 100 metros.';end if;
 zone_name:=private.service_zone(lat2,lng2);
 route_factor_value:=case zone_name when 'central' then 1.30 when 'urban' then 1.22 else 1.15 end;
 speed_kmh:=case zone_name when 'central' then 22 when 'urban' then 30 else 48 end;
 road_km:=round(direct_km*route_factor_value,2);
 trip_minutes:=greatest(5,ceil(road_km/speed_kmh*60)::integer+3);
 select round(min(private.haversine_km(dp.lat,dp.lng,lat1,lng1))*route_factor_value,2)
 into pickup_km from public.driver_presence dp join public.drivers d on d.id=dp.driver_id
 where d.online and d.approved and d.category=c.id and dp.updated_at>now()-interval '10 minutes'
 and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
 and (not coalesce((payload->>'women_only')::boolean,false) or d.female_verified)
 and (not coalesce((payload->>'accessible')::boolean,false) or d.accessible_verified);
 if pickup_km is null then
   pickup_km:=round(private.haversine_km(28.1902,-105.4701,lat1,lng1)*route_factor_value,2);
   pickup_minutes:=greatest(5,ceil(pickup_km/28*60)::integer+5);
 else
   source_name:='nearby_online_unit';pickup_minutes:=greatest(3,ceil(pickup_km/26*60)::integer+2);
 end if;
 zone_fee:=case zone_name when 'regional' then 2500 when 'urban' then 500 else 0 end;
 access_fee:=case when coalesce((payload->>'accessible')::boolean,false) then 1500 else 0 end;
 fare:=greatest(c.minimum_cents,c.base_cents+ceil(road_km*c.km_cents)::integer+trip_minutes*c.minute_cents+c.booking_fee_cents+zone_fee+access_fee);
 ts:=nullif(payload->>'scheduled_at','')::timestamptz;
 if ts is not null and (ts<now()+interval '15 minutes' or ts>now()+interval '30 days') then raise exception 'Programa entre 15 minutos y 30 días de anticipación.';end if;
 insert into public.quotes(passenger_id,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,distance_km,direct_distance_km,pickup_distance_km,pickup_eta_minutes,trip_eta_minutes,service_zone,route_factor,fare_cents,commission_cents,zone_surcharge_cents,booking_fee_cents,accessibility_surcharge_cents,women_only,accessible,scheduled_at,estimate_source,pricing_version)
 values(uid,left(trim(payload->>'origin'),200),left(trim(payload->>'destination'),200),lat1,lng1,lat2,lng2,c.id,road_km,direct_km,pickup_km,pickup_minutes,trip_minutes,zone_name,route_factor_value,fare,round(fare*c.commission_bps/10000.0),zone_fee,c.booking_fee_cents,access_fee,coalesce((payload->>'women_only')::boolean,false),coalesce((payload->>'accessible')::boolean,false),ts,source_name,'delicias-pilot-2026-09') returning * into q;
 return to_jsonb(q);
end $$;
revoke all on function private.quote_v2(jsonb) from public,anon;
grant execute on function private.quote_v2(jsonb) to authenticated;

create function private.presence_v2(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();d public.drivers;lat_value float8;lng_value float8;accuracy_value float8;
begin
 select * into d from public.drivers where id=uid;
 if uid is null or not found or not d.approved or not d.online or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then raise exception 'Conductor no disponible o expediente vencido.' using errcode='42501';end if;
 lat_value:=(payload->>'lat')::float8;lng_value:=(payload->>'lng')::float8;accuracy_value:=(payload->>'accuracy')::float8;
 if not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) or not(accuracy_value between 0 and 5000) then raise exception 'Ubicación fuera de cobertura o sin precisión suficiente.';end if;
 if exists(select 1 from public.driver_presence where driver_id=uid and updated_at>now()-interval '4 seconds') then return jsonb_build_object('ok',true,'throttled',true);end if;
 insert into public.driver_presence(driver_id,lat,lng,accuracy) values(uid,lat_value,lng_value,accuracy_value)
 on conflict(driver_id) do update set lat=excluded.lat,lng=excluded.lng,accuracy=excluded.accuracy,updated_at=now();
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.presence_v2(jsonb) from public,anon;
grant execute on function private.presence_v2(jsonb) to authenticated;

create function private.offers_v2(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();d public.drivers;dp public.driver_presence;
begin
 select * into d from public.drivers where id=uid;
 if uid is null or not found or not d.approved or not d.online or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then return '[]'::jsonb;end if;
 if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then return '[]'::jsonb;end if;
 select * into dp from public.driver_presence where driver_id=uid and updated_at>now()-interval '10 minutes';
 return (select coalesce(jsonb_agg(to_jsonb(x) order by x.pickup_from_driver_km nulls last,x.created_at),'[]') from (
   select t.id,t.origin,t.destination,t.fare_cents,t.fare_cents-t.commission_cents as net_cents,t.cash_tender_cents,t.category,
          t.women_only,t.accessible,t.scheduled_at,t.distance_km,t.trip_eta_minutes,t.pickup_eta_minutes,t.service_zone,t.created_at,
          case when dp.driver_id is null then null else round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) end as pickup_from_driver_km
   from public.trips t where t.driver_id is null and (t.status='requested' or (t.status='scheduled' and t.scheduled_at<=now()+interval '15 minutes'))
   and t.category=d.category and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
   order by pickup_from_driver_km nulls last,t.created_at limit 20
 )x);
end $$;
revoke all on function private.offers_v2(jsonb) from public,anon;
grant execute on function private.offers_v2(jsonb) to authenticated;

create function private.category_v2(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target text;
begin
 if uid is null or not private.is_admin() then raise exception 'Sólo Operaciones puede realizar esta acción.' using errcode='42501';end if;
 target:=payload->>'id';
 update public.categories set base_cents=(payload->>'base_cents')::integer,km_cents=(payload->>'km_cents')::integer,
 minute_cents=(payload->>'minute_cents')::integer,minimum_cents=(payload->>'minimum_cents')::integer,
 booking_fee_cents=(payload->>'booking_fee_cents')::integer,commission_bps=(payload->>'commission_bps')::integer,
 active=(payload->>'active')::boolean where id=target;
 if not found then raise exception 'Categoría no encontrada.';end if;
 insert into public.audit_log(actor_id,action,detail) values(uid,'category_pricing',payload);
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.category_v2(jsonb) from public,anon;
grant execute on function private.category_v2(jsonb) to authenticated;

create function private.sync_driver_presence() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.driver_presence(driver_id,lat,lng,accuracy,updated_at) values(new.driver_id,new.lat,new.lng,new.accuracy,new.updated_at)
 on conflict(driver_id) do update set lat=excluded.lat,lng=excluded.lng,accuracy=excluded.accuracy,updated_at=excluded.updated_at;
 return new;
end $$;
revoke all on function private.sync_driver_presence() from public,anon,authenticated;
create trigger sync_trip_location_to_presence after insert or update on public.locations for each row execute function private.sync_driver_presence();

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command when 'quote' then private.quote_v2(payload)
                     when 'presence' then private.presence_v2(payload)
                     when 'offers' then private.offers_v2(payload)
                     when 'category' then private.category_v2(payload)
                     else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

alter publication supabase_realtime add table public.driver_presence;
