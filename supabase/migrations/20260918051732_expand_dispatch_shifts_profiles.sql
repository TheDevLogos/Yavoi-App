-- Expand dispatch beyond the requested category, add driver work shifts and simplify onboarding.

update storage.buckets set file_size_limit=4194304
where id in ('yavoi-avatars','yavoi-vehicle-photos');

create table public.service_shifts (
  code text primary key check(code ~ '^[a-z][a-z0-9_]{1,29}$'),
  name text not null check(char_length(name) between 2 and 40),
  start_time time not null,
  end_time time not null,
  active boolean not null default true,
  sort_order integer not null default 0,
  updated_at timestamptz not null default now(),
  check(start_time<>end_time)
);
alter table public.service_shifts enable row level security;
revoke all on public.service_shifts from anon,authenticated;

insert into public.service_shifts(code,name,start_time,end_time,sort_order) values
  ('morning','Matutino','05:00','10:00',10),
  ('midday','Mediodía','10:00','13:00',20),
  ('evening','Vespertino','17:00','22:00',30),
  ('night','Noche','22:00','05:00',40);

alter table public.drivers
  add column service_shift_code text references public.service_shifts(code),
  add column shift_connected_at timestamptz;

create or replace function private.shift_active_v1(shift_code_value text,at_value timestamptz default now()) returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((
    select s.active and case
      when s.start_time<s.end_time then (at_value at time zone 'America/Chihuahua')::time>=s.start_time
        and (at_value at time zone 'America/Chihuahua')::time<s.end_time
      else (at_value at time zone 'America/Chihuahua')::time>=s.start_time
        or (at_value at time zone 'America/Chihuahua')::time<s.end_time
    end
    from public.service_shifts s where s.code=shift_code_value
  ),false)
$$;
revoke all on function private.shift_active_v1(text,timestamptz) from public,anon,authenticated;

create or replace function private.driver_shift_active_v1(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.drivers d where d.id=target and private.shift_active_v1(d.service_shift_code,now()))
$$;
revoke all on function private.driver_shift_active_v1(uuid) from public,anon,authenticated;

create or replace function private.driver_candidate_eligible_v1(target uuid,women_required boolean,accessible_required boolean) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where d.id=target and d.online and d.approved and d.account_active
      and private.driver_shift_active_v1(d.id)
      and dp.heartbeat_at>now()-interval '90 seconds'
      and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
      and (not women_required or d.female_verified) and (not accessible_required or d.accessible_verified)
      and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status not in ('completed','cancelled'))
      and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now())
  )
$$;
revoke all on function private.driver_candidate_eligible_v1(uuid,boolean,boolean) from public,anon,authenticated;

create or replace function private.passenger_profile_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p
    where p.id=target and p.role='passenger'
      and length(trim(p.full_name))>=2 and length(trim(p.phone))>=10
      and p.avatar_path is not null
      and p.passenger_policy_accepted_at is not null and p.passenger_policy_version='2026-09-11-cancelaciones'
      and p.privacy_policy_accepted_at is not null and p.privacy_policy_version='2026-09-11'
      and p.terms_accepted_at is not null and p.terms_version='2026-09-11'
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars'
        and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.passenger_profile_complete(uuid) from public,anon,authenticated;

create function private.available_units_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;lat_value float8;lng_value float8;category_value text;
  women_required boolean:=coalesce((payload->>'women_only')::boolean,false);
  accessible_required boolean:=coalesce((payload->>'accessible')::boolean,false);
  exact_near boolean;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
  lat_value:=(payload->>'lat')::float8;lng_value:=(payload->>'lng')::float8;category_value:=payload->>'category';
  if not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) then raise exception 'Ubicación fuera de cobertura.';end if;
  select exists(
    select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where d.category=category_value and private.driver_candidate_eligible_v1(d.id,women_required,accessible_required)
      and private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22<=3
  ) into exact_near;
  return (with eligible as (
    select d.id as unit_id,d.category,round(dp.lat::numeric,4)::float8 as lat,round(dp.lng::numeric,4)::float8 as lng,
      round((private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22)::numeric,2) as pickup_km,
      greatest(3,ceil(private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22/26*60)::integer+2) as pickup_minutes,
      d.female_verified,d.accessible_verified,d.category=category_value as category_match
    from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where private.driver_candidate_eligible_v1(d.id,women_required,accessible_required)
  ), radius as (
    select least(3,greatest(1,ceil(min(pickup_km))::integer)) as km from eligible where category_match and pickup_km<=3
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.pickup_km),'[]') from (
    select e.unit_id,e.category,e.lat,e.lng,e.pickup_km,e.pickup_minutes,
      case when exact_near then (select km from radius) else null end as search_radius_km,
      not exact_near as fallback_all
    from eligible e
    where (exact_near and e.category_match and e.pickup_km<=(select km from radius)) or not exact_near
    order by e.pickup_km limit 50
  )x);
end $$;
revoke all on function private.available_units_v4(jsonb) from public,anon;
grant execute on function private.available_units_v4(jsonb) to authenticated;

create function private.quote_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare clean jsonb:=payload-'preferred_driver_id';result jsonb;q public.quotes;c public.categories;preferred uuid;pickup_km numeric;pickup_minutes integer;chosen uuid;pickup_fee integer:=0;new_fare integer;
begin
  select * into c from public.categories where id=payload->>'category' and active;
  if not found then raise exception 'Categoría no disponible.';end if;
  clean:=jsonb_set(clean,'{party_size}',to_jsonb(c.seats),true);
  result:=private.quote_v4(clean);
  select * into q from public.quotes where id=(result->>'id')::uuid for update;
  preferred:=nullif(payload->>'preferred_driver_id','')::uuid;
  if preferred is not null then
    if not private.driver_candidate_eligible_v1(preferred,q.women_only,q.accessible) then
      raise exception 'La unidad seleccionada dejó de estar disponible. Elige otra unidad o usa la asignación automática.';
    end if;
    chosen:=preferred;
  else
    select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where private.driver_candidate_eligible_v1(d.id,q.women_only,q.accessible)
    order by case when d.category=q.category and private.haversine_km(dp.lat,dp.lng,q.origin_lat,q.origin_lng)*q.route_factor<=3 then 0 else 1 end,
      private.haversine_km(dp.lat,dp.lng,q.origin_lat,q.origin_lng),dp.heartbeat_at desc limit 1;
  end if;
  if chosen is not null then
    select round((private.haversine_km(dp.lat,dp.lng,q.origin_lat,q.origin_lng)*q.route_factor)::numeric,2),
      greatest(3,ceil(private.haversine_km(dp.lat,dp.lng,q.origin_lat,q.origin_lng)*q.route_factor/26*60)::integer+2)
      into pickup_km,pickup_minutes from public.driver_presence dp where dp.driver_id=chosen;
    pickup_fee:=case when preferred is not null and pickup_km>7 then ceil((pickup_km-7)*c.km_cents*0.65)::integer else 0 end;
    new_fare:=q.fare_cents-q.pickup_surcharge_cents+pickup_fee;
    update public.quotes set preferred_driver_id=preferred,pickup_distance_km=pickup_km,pickup_eta_minutes=pickup_minutes,
      pickup_surcharge_cents=pickup_fee,fare_cents=new_fare,commission_cents=round(new_fare*c.commission_bps/10000.0),
      estimate_source='nearby_online_unit'
      where id=q.id returning * into q;
  end if;
  return to_jsonb(q);
end $$;
revoke all on function private.quote_v5(jsonb) from public,anon;
grant execute on function private.quote_v5(jsonb) to authenticated;

create or replace function private.auto_assign_trip(target_trip uuid,preferred uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare t public.trips;chosen uuid;
begin
 select * into t from public.trips where id=target_trip for update;
 if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id;end if;
 update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado'
  where trip_id=t.id and status='offered' and expires_at<=now();
 select driver_id into chosen from public.trip_offers where trip_id=t.id and status='offered' and expires_at>now();
 if chosen is not null then return chosen;end if;
 select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
 where private.driver_candidate_eligible_v1(d.id,t.women_only,t.accessible)
   and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
 order by case when d.id=preferred then 0 when d.category=t.category and private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22<=3 then 1 else 2 end,
   private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.heartbeat_at desc
 for update of d skip locked limit 1;
 if chosen is not null then
   insert into public.trip_offers(trip_id,driver_id) values(t.id,chosen);
   insert into public.trip_events(trip_id,actor_id,event,detail)
   values(t.id,chosen,'offer_sent',jsonb_build_object('preferred',chosen=preferred,'category_match',(select category=t.category from public.drivers where id=chosen),'expanded_search',true,'expires_in_seconds',60));
 end if;
 return chosen;
end $$;
revoke all on function private.auto_assign_trip(uuid,uuid) from public,anon,authenticated;

create function private.availability_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();going_online boolean:=coalesce((payload->>'online')::boolean,false);shift_value text:=nullif(payload->>'shift_code','');result jsonb;
begin
  result:=private.availability_v5(payload);
  if going_online then
    if shift_value is null then raise exception 'Elige el turno en el que vas a conectarte.';end if;
    if not private.shift_active_v1(shift_value,now()) then raise exception 'Ese turno no está activo en este momento. Elige el turno vigente.';end if;
    update public.drivers set service_shift_code=shift_value,shift_connected_at=now(),updated_at=now() where id=uid;
  end if;
  if not going_online then update public.drivers set shift_connected_at=null,updated_at=now() where id=uid;end if;
  return result||jsonb_build_object('shift_code',(select service_shift_code from public.drivers where id=uid));
end $$;
revoke all on function private.availability_v6(jsonb) from public,anon;
grant execute on function private.availability_v6(jsonb) to authenticated;

create function private.presence_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();d public.drivers;item record;
begin
  select * into d from public.drivers where id=uid for update;
  if d.online and not private.driver_shift_active_v1(uid) then
    update public.drivers set online=false,shift_connected_at=null,updated_at=now() where id=uid;
    delete from public.driver_presence where driver_id=uid;
    for item in update public.trip_offers set status='rejected',responded_at=now(),response_reason='Turno finalizado'
      where driver_id=uid and status='offered' returning trip_id loop
      perform private.auto_assign_trip(item.trip_id,(select preferred_driver_id from public.trips where id=item.trip_id));
    end loop;
    return jsonb_build_object('ok',false,'shift_ended',true,'message','Tu turno terminó y la unidad quedó fuera de línea.');
  end if;
  return private.presence_v3(payload);
end $$;
revoke all on function private.presence_v4(jsonb) from public,anon;
grant execute on function private.presence_v4(jsonb) to authenticated;

create function private.upsert_service_shift_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target text:=left(trim(coalesce(payload->>'code','')),30);item public.service_shifts;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  if target not in ('morning','midday','evening','night') then raise exception 'Turno inválido.';end if;
  update public.service_shifts set name=left(trim(payload->>'name'),40),start_time=(payload->>'start_time')::time,
    end_time=(payload->>'end_time')::time,active=coalesce((payload->>'active')::boolean,false),updated_at=now()
    where code=target returning * into item;
  if not found then raise exception 'Turno no encontrado.';end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'service_shift_updated',auth.uid(),to_jsonb(item));
  return to_jsonb(item);
end $$;
revoke all on function private.upsert_service_shift_v1(jsonb) from public,anon;
grant execute on function private.upsert_service_shift_v1(jsonb) to authenticated;

create function private.dashboard_v13(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;
begin
  base:=private.dashboard_v12(payload);
  return jsonb_set(base,'{service_shifts}',(
    select coalesce(jsonb_agg(to_jsonb(s) order by s.sort_order),'[]') from public.service_shifts s
  ),true);
end $$;
revoke all on function private.dashboard_v13(jsonb) from public,anon;
grant execute on function private.dashboard_v13(jsonb) to authenticated;

create function private.offers_v7(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();d public.drivers;item record;
begin
  select * into d from public.drivers where id=uid for update;
  if d.online and not private.driver_shift_active_v1(uid) then
    update public.drivers set online=false,shift_connected_at=null,updated_at=now() where id=uid;
    delete from public.driver_presence where driver_id=uid;
    for item in update public.trip_offers set status='rejected',responded_at=now(),response_reason='Turno finalizado'
      where driver_id=uid and status='offered' returning trip_id loop
      perform private.auto_assign_trip(item.trip_id,(select preferred_driver_id from public.trips where id=item.trip_id));
    end loop;
    return '[]'::jsonb;
  end if;
  return private.offers_v6(payload);
end $$;
revoke all on function private.offers_v7(jsonb) from public,anon;
grant execute on function private.offers_v7(jsonb) to authenticated;

create function private.accept_offer_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if not private.driver_shift_active_v1(auth.uid()) then
    raise exception 'Tu turno terminó. Vuelve a conectarte en un turno vigente.' using errcode='42501';
  end if;
  return private.accept_offer_v2(payload);
end $$;
revoke all on function private.accept_offer_v3(jsonb) from public,anon;
grant execute on function private.accept_offer_v3(jsonb) to authenticated;


create or replace function private.request_trip_v5(payload jsonb) returns jsonb
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
   where d.id=preferred and d.online and d.approved and d.account_active
     and private.driver_shift_active_v1(d.id)
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

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload)
   when 'dashboard' then private.dashboard_v13(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload)
   when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v9(payload)
   when 'trip' then private.trip_v10(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v8(payload)
   when 'review_driver' then private.review_driver_v3(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v6(payload)
   when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v7(payload)
   when 'accept' then private.accept_offer_v3(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
   when 'transition' then private.transition_v7(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v4(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v2(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v2(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v4(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload)
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
   when 'upsert_service_shift' then private.upsert_service_shift_v1(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
