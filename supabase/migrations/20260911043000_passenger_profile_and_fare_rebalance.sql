-- Passenger safety profile and a server-owned Delicias fare model.
alter table public.profiles
  add column passenger_policy_accepted_at timestamptz,
  add column passenger_policy_version text;

alter table public.quotes
  add column preferred_driver_id uuid references public.drivers(id),
  add column distance_charge_cents integer not null default 0 check(distance_charge_cents between 0 and 200000),
  add column time_charge_cents integer not null default 0 check(time_charge_cents between 0 and 200000),
  add column minimum_adjustment_cents integer not null default 0 check(minimum_adjustment_cents between 0 and 200000);

alter table public.trips
  add column distance_charge_cents integer not null default 0 check(distance_charge_cents between 0 and 200000),
  add column time_charge_cents integer not null default 0 check(time_charge_cents between 0 and 200000),
  add column minimum_adjustment_cents integer not null default 0 check(minimum_adjustment_cents between 0 and 200000);

update public.categories set base_cents=2300,km_cents=630,minute_cents=75,minimum_cents=4900,booking_fee_cents=0 where id='basic';
update public.categories set base_cents=3300,km_cents=840,minute_cents=100,minimum_cents=6900,booking_fee_cents=0 where id='large';
update public.categories set base_cents=7800,km_cents=980,minute_cents=120,minimum_cents=13000,booking_fee_cents=0 where id='commercial';
update public.categories set base_cents=3900,km_cents=910,minute_cents=110,minimum_cents=7900,booking_fee_cents=0 where id='plus';
update public.categories set base_cents=9600,km_cents=1190,minute_cents=150,minimum_cents=17400,booking_fee_cents=0 where id='pickup';

create function private.passenger_profile_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p
    where p.id=target and p.role='passenger'
      and length(trim(p.full_name))>=2
      and length(trim(p.phone))>=10
      and length(trim(p.emergency_name))>=2
      and length(trim(p.emergency_phone))>=10
      and p.avatar_path is not null
      and p.passenger_policy_accepted_at is not null
      and p.passenger_policy_version='2026-09-10'
      and exists(
        select 1 from storage.objects o
        where o.bucket_id='yavoi-avatars' and o.name=p.avatar_path
          and (storage.foldername(o.name))[1]=target::text
      )
  )
$$;
revoke all on function private.passenger_profile_complete(uuid) from public,anon,authenticated;

create function private.profile_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;accept_policy boolean;already_accepted boolean;
begin
 if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 select * into p from public.profiles where id=uid for update;
 if not found or p.suspended then raise exception 'Tu cuenta no está habilitada.' using errcode='42501';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 if length(trim(coalesce(payload->>'name','')))<2 or length(trim(coalesce(payload->>'phone','')))<10 then raise exception 'Completa nombre y teléfono.';end if;
 if char_length(coalesce(payload->>'emergency_name',''))>100 or char_length(coalesce(payload->>'emergency_phone',''))>25 then raise exception 'Revisa el contacto de emergencia.';end if;
 if payload->>'avatar_path' is not null and not exists(
   select 1 from storage.objects where bucket_id='yavoi-avatars' and name=payload->>'avatar_path'
     and (storage.foldername(name))[1]=uid::text
 ) then raise exception 'La fotografía no pertenece a tu cuenta.';end if;
 accept_policy:=coalesce((payload->>'accept_passenger_policy')::boolean,false);
 already_accepted:=p.passenger_policy_accepted_at is not null and p.passenger_policy_version='2026-09-10';
 if p.role='passenger' and accept_policy and coalesce(payload->>'passenger_policy_version','')<>'2026-09-10' then raise exception 'Actualiza y vuelve a leer las políticas de seguridad.';end if;
 update public.profiles set
   full_name=left(trim(payload->>'name'),100),
   phone=left(trim(payload->>'phone'),25),
   emergency_name=left(trim(coalesce(payload->>'emergency_name','')),100),
   emergency_phone=left(trim(coalesce(payload->>'emergency_phone','')),25),
   avatar_path=coalesce(nullif(payload->>'avatar_path',''),avatar_path),
   passenger_policy_accepted_at=case when role='passenger' and accept_policy then coalesce(passenger_policy_accepted_at,now()) else passenger_policy_accepted_at end,
   passenger_policy_version=case when role='passenger' and accept_policy then '2026-09-10' else passenger_policy_version end,
   updated_at=now()
 where id=uid returning * into p;
 if p.role='passenger' and accept_policy and not already_accepted then
   insert into public.audit_log(actor_id,action,target_id,detail)
   values(uid,'passenger_policy_accepted',uid,jsonb_build_object('version','2026-09-10'));
 end if;
 return jsonb_build_object('ok',true,'complete',case when p.role='passenger' then private.passenger_profile_complete(uid) else true end);
end $$;
revoke all on function private.profile_v2(jsonb) from public,anon;
grant execute on function private.profile_v2(jsonb) to authenticated;

create or replace function private.apply_long_pickup_pricing() returns trigger
language plpgsql security definer set search_path='' as $$
declare c public.categories;pickup_fee integer:=0;
begin
 select * into c from public.categories where id=new.category;
 if not found then raise exception 'Categoría no disponible.';end if;
 if new.preferred_driver_id is not null and new.pickup_distance_km>7 then
   pickup_fee:=ceil((new.pickup_distance_km-7)*c.km_cents*0.65)::integer;
 end if;
 new.pickup_surcharge_cents:=pickup_fee;
 new.fare_cents:=new.fare_cents+pickup_fee;
 new.commission_cents:=round(new.fare_cents*c.commission_bps/10000.0);
 return new;
end $$;
revoke all on function private.apply_long_pickup_pricing() from public,anon,authenticated;

create or replace function private.copy_quote_estimate() returns trigger
language plpgsql security definer set search_path='' as $$
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
 new.booking_fee_cents:=0;
 new.accessibility_surcharge_cents:=q.accessibility_surcharge_cents;
 new.pickup_surcharge_cents:=q.pickup_surcharge_cents;
 new.distance_charge_cents:=q.distance_charge_cents;
 new.time_charge_cents:=q.time_charge_cents;
 new.minimum_adjustment_cents:=q.minimum_adjustment_cents;
 new.preferred_driver_id:=q.preferred_driver_id;
 return new;
end $$;
revoke all on function private.copy_quote_estimate() from public,anon,authenticated;

create function private.quote_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid();p public.profiles;c public.categories;q public.quotes;
 lat1 float8;lng1 float8;lat2 float8;lng2 float8;direct_km numeric;road_km numeric;pickup_km numeric;
 zone_name text;route_factor_value numeric;speed_kmh numeric;pickup_minutes integer;trip_minutes integer;
 distance_fee integer;time_fee integer;fare integer;zone_fee integer;access_fee integer;minimum_fee integer;
 source_name text:='zone_reference';ts timestamptz;party integer;notes text;preferred uuid;
begin
 if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 select * into p from public.profiles where id=uid;
 if not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 if not p.onboarding_complete or not private.passenger_profile_complete(uid) then raise exception 'Completa tu perfil y acepta las políticas de seguridad antes de solicitar un viaje.';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 if (select count(*) from public.quotes where passenger_id=uid and created_at>now()-interval '1 minute')>=15 then raise exception 'Espera un minuto antes de volver a cotizar.';end if;
 lat1:=(payload->>'origin_lat')::float8;lng1:=(payload->>'origin_lng')::float8;lat2:=(payload->>'dest_lat')::float8;lng2:=(payload->>'dest_lng')::float8;
 if lat1 is null or lng1 is null or lat2 is null or lng2 is null or not(lat1 between 28.0 and 28.4 and lat2 between 28.0 and 28.4 and lng1 between -105.7 and -105.2 and lng2 between -105.7 and -105.2) then raise exception 'Selecciona puntos dentro de la cobertura de Delicias y Meoqui.';end if;
 if length(trim(coalesce(payload->>'origin','')))<3 or length(trim(coalesce(payload->>'destination','')))<3 then raise exception 'Indica las direcciones.';end if;
 select * into c from public.categories where id=payload->>'category' and active;
 if not found then raise exception 'Categoría no disponible.';end if;
 party:=coalesce((payload->>'party_size')::integer,1);notes:=trim(coalesce(payload->>'service_notes',''));
 if party not between 1 and 8 then raise exception 'Indica entre 1 y 8 personas.';end if;
 if party>c.seats then raise exception 'La categoría elegida no tiene espacio para todas las personas.';end if;
 if char_length(notes)>500 then raise exception 'Las indicaciones pueden tener hasta 500 caracteres.';end if;
 direct_km:=private.haversine_km(lat1,lng1,lat2,lng2);if direct_km<0.1 then raise exception 'El destino debe estar al menos a 100 metros.';end if;
 zone_name:=private.service_zone(lat2,lng2);
 route_factor_value:=case zone_name when 'central' then 1.30 when 'urban' then 1.22 else 1.15 end;
 speed_kmh:=case zone_name when 'central' then 22 when 'urban' then 30 else 48 end;
 road_km:=round(direct_km*route_factor_value,2);
 trip_minutes:=greatest(5,ceil(road_km/speed_kmh*60)::integer+3);
 preferred:=nullif(payload->>'preferred_driver_id','')::uuid;
 if preferred is not null then
   select round((private.haversine_km(dp.lat,dp.lng,lat1,lng1)*route_factor_value)::numeric,2),
     greatest(3,ceil(private.haversine_km(dp.lat,dp.lng,lat1,lng1)*route_factor_value/26*60)::integer+2)
   into pickup_km,pickup_minutes
   from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where d.id=preferred and d.online and d.approved and d.account_active and d.category=c.id
     and dp.heartbeat_at>now()-interval '90 seconds'
     and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
     and (not coalesce((payload->>'women_only')::boolean,false) or d.female_verified)
     and (not coalesce((payload->>'accessible')::boolean,false) or d.accessible_verified)
     and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status not in ('completed','cancelled'))
     and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now());
   if pickup_km is null then raise exception 'La unidad seleccionada dejó de estar disponible. Elige otra unidad o usa la asignación automática.';end if;
   source_name:='nearby_online_unit';
 else
   select round((private.haversine_km(dp.lat,dp.lng,lat1,lng1)*route_factor_value)::numeric,2),
     greatest(3,ceil(private.haversine_km(dp.lat,dp.lng,lat1,lng1)*route_factor_value/26*60)::integer+2)
   into pickup_km,pickup_minutes
   from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where d.online and d.approved and d.account_active and d.category=c.id
     and dp.heartbeat_at>now()-interval '90 seconds'
     and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
     and (not coalesce((payload->>'women_only')::boolean,false) or d.female_verified)
     and (not coalesce((payload->>'accessible')::boolean,false) or d.accessible_verified)
     and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status not in ('completed','cancelled'))
     and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now())
   order by private.haversine_km(dp.lat,dp.lng,lat1,lng1),dp.heartbeat_at desc limit 1;
   if pickup_km is null then
     pickup_km:=round(private.haversine_km(28.1902,-105.4701,lat1,lng1)*route_factor_value,2);
     pickup_minutes:=greatest(5,ceil(pickup_km/28*60)::integer+5);
   else source_name:='nearby_online_unit';end if;
 end if;
 zone_fee:=case zone_name when 'regional' then 1500 else 0 end;
 access_fee:=case when coalesce((payload->>'accessible')::boolean,false) then 1500 else 0 end;
 distance_fee:=ceil(road_km*c.km_cents)::integer;
 time_fee:=trip_minutes*c.minute_cents;
 fare:=c.base_cents+distance_fee+time_fee+zone_fee+access_fee;
 minimum_fee:=greatest(0,c.minimum_cents-fare);
 fare:=fare+minimum_fee;
 ts:=nullif(payload->>'scheduled_at','')::timestamptz;
 if ts is not null and (ts<now()+interval '15 minutes' or ts>now()+interval '30 days') then raise exception 'Programa entre 15 minutos y 30 días de anticipación.';end if;
 insert into public.quotes(
   passenger_id,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,
   distance_km,direct_distance_km,pickup_distance_km,pickup_eta_minutes,trip_eta_minutes,
   service_zone,route_factor,fare_cents,commission_cents,zone_surcharge_cents,booking_fee_cents,
   accessibility_surcharge_cents,women_only,accessible,scheduled_at,estimate_source,pricing_version,
   party_size,service_notes,preferred_driver_id,distance_charge_cents,time_charge_cents,minimum_adjustment_cents
 ) values(
   uid,left(trim(payload->>'origin'),200),left(trim(payload->>'destination'),200),lat1,lng1,lat2,lng2,c.id,
   road_km,direct_km,pickup_km,pickup_minutes,trip_minutes,zone_name,route_factor_value,fare,
   round(fare*c.commission_bps/10000.0),zone_fee,0,access_fee,
   coalesce((payload->>'women_only')::boolean,false),coalesce((payload->>'accessible')::boolean,false),ts,
   source_name,'delicias-balanced-2026-09',party,left(notes,500),preferred,distance_fee,time_fee,minimum_fee
 ) returning * into q;
 return to_jsonb(q);
end $$;
revoke all on function private.quote_v4(jsonb) from public,anon;
grant execute on function private.quote_v4(jsonb) to authenticated;

create function private.request_trip_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;q public.quotes;t public.trips;method text;tip integer;total integer;tender integer;pinvalue text;payment_id uuid;assigned uuid;preferred uuid;enabled boolean;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 if not private.passenger_profile_complete(uid) then raise exception 'Completa tu perfil y acepta las políticas de seguridad antes de solicitar un viaje.';end if;
 if not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Verifica tu correo para continuar.' using errcode='42501';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 perform 1 from public.profiles where id=uid for update;
 select * into t from public.trips where passenger_id=uid and request_key=(payload->>'request_key')::uuid;
 if found then return to_jsonb(t)||jsonb_build_object('payment_id',(select id from public.payments where trip_id=t.id and kind='ride' order by created_at limit 1));end if;
 select * into q from public.quotes where id=(payload->>'quote_id')::uuid and passenger_id=uid for update;
 if not found or q.expires_at<now() then raise exception 'La cotización venció. Calcula una nueva tarifa.';end if;
 preferred:=q.preferred_driver_id;
 if preferred is not null and not exists(
   select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where d.id=preferred and d.online and d.approved and d.account_active and d.category=q.category
     and dp.heartbeat_at>now()-interval '90 seconds'
     and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
     and (not q.women_only or d.female_verified) and (not q.accessible or d.accessible_verified)
     and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status not in ('completed','cancelled'))
     and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now())
 ) then raise exception 'La unidad seleccionada dejó de estar disponible. Calcula una nueva tarifa.';end if;
 method:=payload->>'payment_method';if method not in ('cash','card') or method is null then raise exception 'Selecciona un método de pago.';end if;
 tip:=coalesce((payload->>'tip_cents')::integer,0);if tip<0 or tip>100000 then raise exception 'La propina debe estar entre $0 y $1,000.';end if;
 total:=q.fare_cents+tip;if total>300000 then raise exception 'El total supera el límite permitido.';end if;
 if exists(select 1 from public.trips where passenger_id=uid and status not in ('completed','cancelled','scheduled')) then raise exception 'Ya tienes un viaje activo.';end if;
 if (select count(*) from public.trips where passenger_id=uid and created_at>now()-interval '1 hour')>=10 then raise exception 'Límite de solicitudes alcanzado. Intenta más tarde.';end if;
 if method='card' then
   select mercado_pago_enabled into enabled from private.app_settings where id;
   if not enabled then raise exception 'El pago con tarjeta está listo para configurarse, pero aún no está activado por Operaciones.';end if;
   tender:=null;
 else
   tender:=coalesce((payload->>'cash_tender_cents')::integer,total);
   if tender<total or tender>300000 then raise exception 'Indica un monto de efectivo válido, hasta $3,000.';end if;
 end if;
 insert into public.trips(
   passenger_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,
   category,fare_cents,commission_cents,payment_method,cash_tender_cents,payment_status,women_only,
   accessible,scheduled_at,tip_cents,total_cents,preferred_driver_id,party_size,service_notes
 ) values(
   uid,q.id,(payload->>'request_key')::uuid,
   case when method='card' then 'payment_pending' when q.scheduled_at is null then 'requested' else 'scheduled' end,
   q.origin,q.destination,q.origin_lat,q.origin_lng,q.dest_lat,q.dest_lng,q.category,q.fare_cents,q.commission_cents,
   method,tender,'pending',q.women_only,q.accessible,q.scheduled_at,tip,total,preferred,q.party_size,q.service_notes
 ) returning * into t;
 pinvalue:=lpad((((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,4))::bit(16)::int % 9000)+1000))::text,4,'0');
 insert into private.trip_secrets(trip_id,pin) values(t.id,pinvalue);
 insert into public.payments(trip_id,payer_id,kind,provider,idempotency_key,amount_cents,status)
 values(t.id,uid,'ride',case when method='card' then 'mercado_pago' else 'cash' end,(payload->>'request_key')::uuid,total,case when method='card' then 'created' else 'pending' end) returning id into payment_id;
 insert into public.trip_events(trip_id,actor_id,event,detail)
 values(t.id,uid,t.status,jsonb_build_object('payment_method',method,'tip_cents',tip,'preferred_driver_id',preferred,'pricing_version',q.pricing_version));
 delete from public.ride_drafts where passenger_id=uid;
 if t.status='requested' then assigned:=private.auto_assign_trip(t.id,preferred);end if;
 select * into t from public.trips where id=t.id;
 return to_jsonb(t)||jsonb_build_object('payment_id',payment_id,'assigned_driver_id',assigned);
end $$;
revoke all on function private.request_trip_v5(jsonb) from public,anon;
grant execute on function private.request_trip_v5(jsonb) to authenticated;

create function private.category_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target text;c public.categories;base_value integer;km_value integer;minute_value integer;minimum_value integer;commission_value integer;
begin
 if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501';end if;
 target:=payload->>'id';base_value:=(payload->>'base_cents')::integer;km_value:=(payload->>'km_cents')::integer;
 minute_value:=(payload->>'minute_cents')::integer;minimum_value:=(payload->>'minimum_cents')::integer;commission_value:=(payload->>'commission_bps')::integer;
 if base_value not between 0 and 100000 or km_value not between 0 and 10000 or minute_value not between 0 and 10000 or minimum_value not between 0 and 100000 or commission_value not between 0 and 5000 then raise exception 'Revisa los valores de la tarifa.';end if;
 update public.categories set base_cents=base_value,km_cents=km_value,minute_cents=minute_value,
   minimum_cents=minimum_value,booking_fee_cents=0,commission_bps=commission_value,
   active=coalesce((payload->>'active')::boolean,false)
 where id=target returning * into c;
 if not found then raise exception 'Categoría no encontrada.';end if;
 insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'category_pricing',null,to_jsonb(c));
 return jsonb_build_object('ok',true,'category',to_jsonb(c));
end $$;
revoke all on function private.category_v3(jsonb) from public,anon;
grant execute on function private.category_v3(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v4(payload)
   when 'profile' then private.profile_v2(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v5(payload)
   when 'trip' then private.trip_v4(payload)
   when 'driver_profile' then private.driver_profile_v4(payload)
   when 'review_driver' then private.review_driver_v2(payload)
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
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
