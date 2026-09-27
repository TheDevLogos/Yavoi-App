-- Drivers submit only identity and vehicle evidence. Operations records the
-- regulatory fields from those documents before an account is authorized.
alter table public.drivers
  add column if not exists driver_type text not null default 'yavoi';

alter table public.drivers drop constraint if exists drivers_driver_type_check;
alter table public.drivers
  add constraint drivers_driver_type_check check (driver_type in ('yavoi','support'));
create index if not exists drivers_driver_type_online_idx
  on public.drivers(driver_type, online, approved, account_active);

create or replace function private.driver_dossier_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d
    join public.profiles p on p.id=d.id
    where d.id=target
      and p.avatar_path is not null
      and d.government_id_path is not null
      and d.license_path is not null
      and d.vehicle_registration_path is not null
      and d.insurance_path is not null
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars' and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.government_id_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.license_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.vehicle_registration_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.insurance_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.driver_dossier_complete(uuid) from public,anon,authenticated;

-- Los datos regulatorios se capturan por Operaciones durante la revisión. No
-- se exigen al conductor documentos adicionales que ya no forman parte del
-- registro inicial.
create or replace function private.driver_legal_missing_v1(target uuid) returns text[]
language sql stable security definer set search_path='' as $$
  select coalesce(array_agg(label order by sort_order) filter(where not ok),array[]::text[])
  from public.drivers d
  join public.profiles p on p.id=d.id
  cross join lateral (values
      (1,'Fotografía del conductor',p.avatar_path is not null),
      (2,'Identificación oficial INE',d.government_id_path is not null),
      (3,'Licencia vigente',d.license_path is not null and d.license_expires>=current_date),
      (4,'Tarjeta de circulación vigente',d.vehicle_registration_path is not null),
      (5,'Póliza particular vigente',d.insurance_path is not null and d.insurance_expires>=current_date),
      (6,'Datos oficiales de la unidad',length(trim(d.vehicle_make))>=2 and length(trim(d.vehicle_model))>=1 and d.vehicle_year between 1990 and extract(year from current_date)::integer+1 and length(trim(d.vehicle_color))>=3 and length(trim(d.plate))>=5),
      (7,'Tarjetón de transporte',length(trim(d.transport_card_number))>=3 and d.transport_card_expires>=current_date),
      (8,'Afiliación Yavoi!',d.affiliation_number is not null and d.affiliation_expires>=current_date)
    ) as requirement(sort_order,label,ok)
  where d.id=target
$$;
revoke all on function private.driver_legal_missing_v1(uuid) from public,anon,authenticated;

create or replace function private.driver_profile_v10(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid(); profile_value public.profiles; path_key text; path_value text; complete_value boolean;
begin
  select * into profile_value from public.profiles where id=uid for update;
  if uid is null or not found or profile_value.role<>'driver' or profile_value.suspended then
    raise exception 'Acceso de conductor requerido.' using errcode='42501';
  end if;
  if not private.profile_edit_open(uid) then
    raise exception 'Tu expediente está protegido. Operaciones debe autorizar temporalmente cualquier modificación.' using errcode='42501';
  end if;
  if jsonb_typeof(payload)<>'object' or octet_length(payload::text)>12000 then raise exception 'Solicitud inválida.'; end if;
  foreach path_key in array array['government_id_path','license_path','vehicle_registration_path','insurance_path'] loop
    path_value:=nullif(payload->>path_key,'');
    if path_value is not null and not exists(
      select 1 from storage.objects where bucket_id='yavoi-documents' and name=path_value and (storage.foldername(name))[1]=uid::text
    ) then raise exception 'Documento inválido o ajeno a tu cuenta.'; end if;
  end loop;
  update public.drivers set
    government_id_path=coalesce(nullif(payload->>'government_id_path',''),government_id_path),
    license_path=coalesce(nullif(payload->>'license_path',''),license_path),
    vehicle_registration_path=coalesce(nullif(payload->>'vehicle_registration_path',''),vehicle_registration_path),
    insurance_path=coalesce(nullif(payload->>'insurance_path',''),insurance_path),
    approved=false, online=false, dossier_submitted_at=now(), updated_at=now()
  where id=uid;
  complete_value:=private.driver_dossier_complete(uid);
  if complete_value then update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid; end if;
  delete from public.driver_profile_drafts where driver_id=uid;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'driver_dossier_submitted',uid,jsonb_build_object('complete',complete_value,'requirements','five_documents'));
  return jsonb_build_object('ok',true,'complete',complete_value,'profile_locked',complete_value);
end $$;
revoke all on function private.driver_profile_v10(jsonb) from public,anon;
grant execute on function private.driver_profile_v10(jsonb) to authenticated;

create or replace function private.review_driver_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid(); target uuid:=(payload->>'driver_id')::uuid; approved_value boolean:=coalesce((payload->>'approved')::boolean,false);
  type_value text:=coalesce(nullif(payload->>'driver_type',''),'yavoi'); result jsonb;
  license_until date:=nullif(payload->>'license_expires','')::date; insurance_until date:=nullif(payload->>'insurance_expires','')::date;
  card_until date:=nullif(payload->>'transport_card_expires','')::date;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  if type_value not in ('yavoi','support') then raise exception 'Tipo de conductor inválido.'; end if;
  if length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Registra el resultado de tu revisión.'; end if;
  if approved_value then
    if not private.driver_dossier_complete(target) then raise exception 'Faltan fotografía, identificación, licencia, tarjeta de circulación o póliza.'; end if;
    if length(trim(coalesce(payload->>'vehicle_make','')))<2 or length(trim(coalesce(payload->>'vehicle_model','')))<1
      or coalesce(nullif(payload->>'vehicle_year','')::integer not between 1990 and extract(year from current_date)::integer+1,true)
      or length(trim(coalesce(payload->>'vehicle_color','')))<3 or length(trim(coalesce(payload->>'plate','')))<5
      or not exists(select 1 from public.categories where id=payload->>'category')
      or length(trim(coalesce(payload->>'license_number','')))<3 or coalesce(license_until<current_date,true) or coalesce(insurance_until<current_date,true)
      or length(trim(coalesce(payload->>'transport_card_number','')))<3 or coalesce(card_until<current_date,true) then
      raise exception 'Registra en Operaciones los datos oficiales y vigencias de la unidad antes de autorizar.';
    end if;
  end if;
  result:=private.review_driver_v2(payload);
  update public.drivers set
    driver_type=type_value,
    vehicle_make=case when approved_value then left(trim(payload->>'vehicle_make'),50) else vehicle_make end,
    vehicle_model=case when approved_value then left(trim(payload->>'vehicle_model'),50) else vehicle_model end,
    vehicle_year=case when approved_value then (payload->>'vehicle_year')::integer else vehicle_year end,
    vehicle_color=case when approved_value then left(trim(payload->>'vehicle_color'),40) else vehicle_color end,
    vehicle=case when approved_value then left(trim(payload->>'vehicle_make')||' '||trim(payload->>'vehicle_model')||' '||(payload->>'vehicle_year'),100) else vehicle end,
    plate=case when approved_value then upper(left(trim(payload->>'plate'),20)) else plate end,
    category=case when approved_value then payload->>'category' else category end,
    license_number=case when approved_value then left(trim(payload->>'license_number'),50) else license_number end,
    license_expires=case when approved_value then license_until else license_expires end,
    insurance_expires=case when approved_value then insurance_until else insurance_expires end,
    transport_card_number=case when approved_value then left(upper(trim(payload->>'transport_card_number')),50) else transport_card_number end,
    transport_card_expires=case when approved_value then card_until else transport_card_expires end,
    affiliation_number=case when approved_value then coalesce(affiliation_number,'YV-'||upper(substr(md5(id::text),1,12))) else affiliation_number end,
    affiliation_issued_at=case when approved_value then coalesce(affiliation_issued_at,now()) else affiliation_issued_at end,
    affiliation_expires=case when approved_value then license_until else affiliation_expires end,
    updated_at=now()
  where id=target;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'driver_type_reviewed',target,jsonb_build_object('driver_type',type_value,'approved',approved_value,'official_registration',approved_value));
  return result||jsonb_build_object('driver_type',type_value);
end $$;
revoke all on function private.review_driver_v4(jsonb) from public,anon;
grant execute on function private.review_driver_v4(jsonb) to authenticated;

-- A driver in the final 700 m of a service can reserve one next trip. A
-- driver heading to pickup cannot be interrupted and no driver gets two queues.
create or replace function private.driver_candidate_eligible_v3(target uuid,women_required boolean,accessible_required boolean) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where d.id=target and d.online and d.approved and d.account_active
      and private.driver_dossier_complete(d.id) and private.driver_shift_active_v1(d.id)
      and dp.heartbeat_at>now()-interval '90 seconds'
      and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
      and (not women_required or d.female_verified) and (not accessible_required or d.accessible_verified)
      and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status in ('accepted','arrived'))
      and (select count(*) from public.trips queued where queued.driver_id=d.id and queued.status='accepted')=0
      and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now())
      and (
        not exists(select 1 from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status='in_progress')
        or exists(select 1 from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status='in_progress'
          and private.haversine_km(dp.lat,dp.lng,active_trip.dest_lat,active_trip.dest_lng)<=0.7)
      )
  )
$$;
revoke all on function private.driver_candidate_eligible_v3(uuid,boolean,boolean) from public,anon,authenticated;

-- Al aceptar se debe ignorar únicamente la oferta que el mismo conductor está
-- respondiendo. Otras ofertas abiertas continúan bloqueándolo.
create or replace function private.driver_candidate_eligible_v4(target uuid,women_required boolean,accessible_required boolean,current_offer uuid default null) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where d.id=target and d.online and d.approved and d.account_active
      and private.driver_dossier_complete(d.id) and private.driver_shift_active_v1(d.id)
      and dp.heartbeat_at>now()-interval '90 seconds'
      and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
      and (not women_required or d.female_verified) and (not accessible_required or d.accessible_verified)
      and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status in ('accepted','arrived'))
      and (select count(*) from public.trips queued where queued.driver_id=d.id and queued.status='accepted')=0
      and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now() and active_offer.id is distinct from current_offer)
      and (
        not exists(select 1 from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status='in_progress')
        or exists(select 1 from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status='in_progress'
          and private.haversine_km(dp.lat,dp.lng,active_trip.dest_lat,active_trip.dest_lng)<=0.7)
      )
  )
$$;
revoke all on function private.driver_candidate_eligible_v4(uuid,boolean,boolean,uuid) from public,anon,authenticated;

create or replace function private.auto_assign_trip_v3(target_trip uuid, preferred uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare
  t public.trips; chosen uuid; reopened uuid; age_seconds integer; radius_km numeric; eligible_type text; selected_type text;
begin
  select * into t from public.trips where id=target_trip for update;
  if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id; end if;
  update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado'
    where trip_id=t.id and status='offered' and expires_at<=now();
  select driver_id into chosen from public.trip_offers where trip_id=t.id and status='offered' and expires_at>now();
  if chosen is not null then return chosen; end if;
  age_seconds:=greatest(0,extract(epoch from now()-t.created_at)::integer);
  radius_km:=case when age_seconds<7 then 1 when age_seconds<14 then 2 when age_seconds<21 then 3 else null end;
  eligible_type:=case when age_seconds<28 then 'yavoi' else null end;
  select d.id,d.driver_type into chosen,selected_type
  from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
  where private.driver_candidate_eligible_v3(d.id,t.women_only,t.accessible)
    and (eligible_type is null or d.driver_type=eligible_type)
    and (radius_km is null or private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)<=radius_km)
    and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
  order by case when d.id=preferred then 0 else 1 end,
    case when d.driver_type='yavoi' then 0 else 1 end,
    private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.heartbeat_at desc
  for update of d skip locked limit 1;
  if chosen is null then
    select d.id,d.driver_type into chosen,selected_type
    from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where private.driver_candidate_eligible_v3(d.id,t.women_only,t.accessible)
      and (eligible_type is null or d.driver_type=eligible_type)
      and (radius_km is null or private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)<=radius_km)
      and coalesce((select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id),'-infinity'::timestamptz)<=now()-interval '90 seconds'
    order by case when d.driver_type='yavoi' then 0 else 1 end,
      coalesce((select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id),'-infinity'::timestamptz),
      private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)
    for update of d skip locked limit 1;
  end if;
  if chosen is not null then
    update public.trip_offers set status='offered',offered_at=now(),expires_at=now()+interval '8 seconds',responded_at=null,response_reason=''
      where trip_id=t.id and driver_id=chosen and status in ('expired','rejected','cancelled') returning id into reopened;
    if reopened is null then
      insert into public.trip_offers(trip_id,driver_id,expires_at) values(t.id,chosen,now()+interval '8 seconds')
      on conflict(trip_id,driver_id) do update set status='offered',offered_at=now(),expires_at=now()+interval '8 seconds',responded_at=null,response_reason=''
      returning id into reopened;
    end if;
    insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,chosen,'offer_sent',jsonb_build_object(
      'expires_in_seconds',8,'retry_after_seconds',90,'radius_km',radius_km,'search_age_seconds',age_seconds,
      'driver_type',selected_type,'queue_eligible',exists(select 1 from public.trips where driver_id=chosen and status='in_progress')));
  end if;
  return chosen;
end $$;
revoke all on function private.auto_assign_trip_v3(uuid,uuid) from public,anon,authenticated;

create or replace function private.dispatch_waiting_trips_v3() returns trigger
language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 50 loop
    perform private.auto_assign_trip_v3(waiting.id,waiting.preferred_driver_id);
  end loop;
  return null;
end $$;
revoke all on function private.dispatch_waiting_trips_v3() from public,anon,authenticated;
drop trigger if exists dispatch_waiting_after_presence on public.driver_presence;
create trigger dispatch_waiting_after_presence after insert or update on public.driver_presence
for each statement execute function private.dispatch_waiting_trips_v3();

create or replace function private.offers_v9(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); d public.drivers; waiting record;
begin
  select * into d from public.drivers where id=uid for update;
  if uid is null or not found or not d.online or not d.approved or not d.account_active or not private.driver_shift_active_v1(uid) then return '[]'::jsonb; end if;
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 50 loop
    perform private.auto_assign_trip_v3(waiting.id,waiting.preferred_driver_id);
  end loop;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.expires_at),'[]') from (
    select o.id offer_id,o.expires_at,t.id,t.origin,t.destination,t.origin_lat,t.origin_lng,t.dest_lat,t.dest_lng,t.fare_cents,
      d.billing_mode,private.driver_commission_bps(uid,t.payment_method) commission_bps,
      round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer commission_cents,
      t.fare_cents-round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer+t.tip_cents net_cents,
      t.category,t.party_size,t.payment_method,t.distance_km,t.trip_eta_minutes,t.pickup_eta_minutes,t.service_notes,
      pr.full_name passenger_name,pr.avatar_path passenger_avatar_path,
      round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) pickup_from_driver_km
    from public.trip_offers o join public.trips t on t.id=o.trip_id join public.profiles pr on pr.id=t.passenger_id join public.driver_presence dp on dp.driver_id=o.driver_id
    where o.driver_id=uid and o.status='offered' and o.expires_at>now() and t.status='requested' and t.driver_id is null
  ) x);
end $$;
revoke all on function private.offers_v9(jsonb) from public,anon;
grant execute on function private.offers_v9(jsonb) to authenticated;

create or replace function private.accept_offer_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); o public.trip_offers; t public.trips; d public.drivers; bps integer; commission_value integer; active_trip uuid;
begin
  select * into o from public.trip_offers where id=(payload->>'offer_id')::uuid and driver_id=uid for update;
  if uid is null or not found or o.status<>'offered' or o.expires_at<=now() then raise exception 'La solicitud ya no está disponible.' using errcode='42501'; end if;
  select * into d from public.drivers where id=uid for update;
  select * into t from public.trips where id=o.trip_id for update;
  if not private.driver_candidate_eligible_v4(uid,t.women_only,t.accessible,o.id) or t.status<>'requested' or t.driver_id is not null then raise exception 'La solicitud ya no está disponible.'; end if;
  select id into active_trip from public.trips where driver_id=uid and status='in_progress' order by updated_at desc limit 1;
  bps:=private.driver_commission_bps(uid,t.payment_method); commission_value:=round(t.fare_cents*bps/10000.0)::integer;
  update public.trip_offers set status='accepted',responded_at=now() where id=o.id;
  update public.trips set driver_id=uid,status='accepted',billing_mode=d.billing_mode,commission_bps_applied=bps,commission_cents=commission_value,updated_at=now() where id=t.id returning * into t;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,case when active_trip is null then 'accepted' else 'accepted_as_next_trip' end,jsonb_build_object('offer_id',o.id,'after_trip_id',active_trip,'driver_type',d.driver_type));
  return to_jsonb(t)||jsonb_build_object('queued_after_trip_id',active_trip);
end $$;
revoke all on function private.accept_offer_v5(jsonb) from public,anon;
grant execute on function private.accept_offer_v5(jsonb) to authenticated;

create or replace function private.trip_v13(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.trips;
begin
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if found and t.status='requested' and (t.passenger_id=auth.uid() or exists(select 1 from public.drivers where id=auth.uid() and online)) then
    perform private.auto_assign_trip_v3(t.id,t.preferred_driver_id);
  end if;
  return private.trip_v12(payload);
end $$;
revoke all on function private.trip_v13(jsonb) from public,anon;
grant execute on function private.trip_v13(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload) when 'dashboard' then private.dashboard_v18(payload)
   when 'onboard' then private.onboard_referral_v2(payload) when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload) when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload) when 'trip' then private.trip_v13(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v10(payload) when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v4(payload) when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload) when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v5(payload) when 'offers' then private.offers_v9(payload) when 'accept' then private.accept_offer_v5(payload)
   when 'reject_offer' then private.reject_offer_v1(payload) when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload) when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload) when 'ride_preferences' then private.ride_preferences_v1(payload)
   when 'transition' then private.transition_v10(payload) when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload) when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload) when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v5(payload) when 'review_reward_redemption' then private.review_reward_redemption_v2(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload) when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v3(payload) when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload) when 'upsert_feature_card' then private.upsert_feature_card_v1(payload)
   when 'set_feature_card_active' then private.set_feature_card_active_v1(payload) when 'operations_report' then private.operations_report_v5(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload) when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload) when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload) when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'review_driver_promotion_reimbursement' then private.review_driver_promotion_reimbursement_v1(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload) when 'refund_checkout' then private.refund_checkout_v2(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload) when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload) when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'scheduled_operations' then private.scheduled_operations_v1(payload) when 'confirm_scheduled_trip' then private.confirm_scheduled_trip_v1(payload)
   when 'assign_scheduled_trip' then private.assign_scheduled_trip_v1(payload) when 'category' then private.category_v3(payload)
   when 'upsert_service_shift' then private.upsert_service_shift_v1(payload) when 'set_driver_shift' then private.set_driver_shift_v1(payload)
   else private.dispatch(command,payload) end
$$;
