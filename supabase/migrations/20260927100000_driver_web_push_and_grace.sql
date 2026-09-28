-- A driver's last secure location heartbeat grants a short, explicit grace
-- window when the PWA is minimized or closed.  After one minute without a
-- heartbeat an idle driver is removed from dispatch; active services remain
-- unaffected so navigation and trip completion are never interrupted.
create or replace function private.expire_idle_drivers_v1() returns integer
language plpgsql security definer set search_path='' as $$
declare affected integer:=0;
begin
  with stale as (
    update public.drivers d set online=false,shift_connected_at=null,updated_at=now()
    where d.online
      and not exists(select 1 from public.trips t where t.driver_id=d.id and t.status in ('accepted','arrived','in_progress'))
      and not exists(select 1 from public.driver_presence p where p.driver_id=d.id and p.heartbeat_at>now()-interval '1 minute')
    returning d.id
  ), offers_closed as (
    update public.trip_offers o set status='expired',responded_at=now(),response_reason='Conductor sin actividad durante un minuto'
    where o.status='offered' and o.driver_id in (select id from stale)
    returning o.id
  ) select count(*) into affected from stale;
  return affected;
end $$;
revoke all on function private.expire_idle_drivers_v1() from public,anon,authenticated;

create or replace function private.bootstrap_v6(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform private.expire_idle_drivers_v1();
  return private.bootstrap_v4(payload);
end $$;
revoke all on function private.bootstrap_v6(jsonb) from public,anon;
grant execute on function private.bootstrap_v6(jsonb) to authenticated;

create or replace function private.driver_candidate_eligible_v5(target uuid,women_required boolean,accessible_required boolean,current_offer uuid default null) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where d.id=target and d.online and d.approved and d.account_active
      and private.driver_dossier_complete(d.id) and private.driver_shift_active_v1(d.id)
      and dp.heartbeat_at>now()-interval '1 minute'
      and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
      and (not women_required or d.female_verified) and (not accessible_required or d.accessible_verified)
      and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status in ('accepted','arrived'))
      and (select count(*) from public.trips queued where queued.driver_id=d.id and queued.status='accepted')=0
      and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now() and active_offer.id is distinct from current_offer)
      and (not exists(select 1 from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status='in_progress')
        or exists(select 1 from public.trips active_trip where active_trip.driver_id=d.id and active_trip.status='in_progress'
          and private.haversine_km(dp.lat,dp.lng,active_trip.dest_lat,active_trip.dest_lng)<=0.7))
  )
$$;
revoke all on function private.driver_candidate_eligible_v5(uuid,boolean,boolean,uuid) from public,anon,authenticated;

create or replace function private.auto_assign_trip_v4(target_trip uuid, preferred uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare t public.trips; chosen uuid; reopened uuid; age_seconds integer; radius_km numeric; eligible_type text; selected_type text;
begin
  perform private.expire_idle_drivers_v1();
  select * into t from public.trips where id=target_trip for update;
  if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id; end if;
  update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado'
    where trip_id=t.id and status='offered' and expires_at<=now();
  select driver_id into chosen from public.trip_offers where trip_id=t.id and status='offered' and expires_at>now();
  if chosen is not null then return chosen; end if;
  age_seconds:=greatest(0,extract(epoch from now()-t.created_at)::integer);
  radius_km:=case when age_seconds<7 then 1 when age_seconds<14 then 2 when age_seconds<21 then 3 else null end;
  eligible_type:=case when age_seconds<28 then 'yavoi' else null end;
  select d.id,d.driver_type into chosen,selected_type from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where private.driver_candidate_eligible_v5(d.id,t.women_only,t.accessible)
     and (eligible_type is null or d.driver_type=eligible_type)
     and (radius_km is null or private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)<=radius_km)
     and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
   order by case when d.id=preferred then 0 else 1 end,case when d.driver_type='yavoi' then 0 else 1 end,private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.heartbeat_at desc
   for update of d skip locked limit 1;
  if chosen is null then
    select d.id,d.driver_type into chosen,selected_type from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
     where private.driver_candidate_eligible_v5(d.id,t.women_only,t.accessible)
       and (eligible_type is null or d.driver_type=eligible_type)
       and (radius_km is null or private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)<=radius_km)
       and coalesce((select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id),'-infinity'::timestamptz)<=now()-interval '90 seconds'
     order by case when d.driver_type='yavoi' then 0 else 1 end,coalesce((select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id),'-infinity'::timestamptz),private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)
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
    insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,chosen,'offer_sent',jsonb_build_object('expires_in_seconds',8,'retry_after_seconds',90,'radius_km',radius_km,'search_age_seconds',age_seconds,'driver_type',selected_type,'push_queued',true));
  end if;
  return chosen;
end $$;
revoke all on function private.auto_assign_trip_v4(uuid,uuid) from public,anon,authenticated;

create or replace function private.dispatch_waiting_trips_v4() returns trigger language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 50 loop
    perform private.auto_assign_trip_v4(waiting.id,waiting.preferred_driver_id);
  end loop;
  return null;
end $$;
revoke all on function private.dispatch_waiting_trips_v4() from public,anon,authenticated;
drop trigger if exists dispatch_waiting_after_presence on public.driver_presence;
create trigger dispatch_waiting_after_presence after insert or update on public.driver_presence for each statement execute function private.dispatch_waiting_trips_v4();

create table if not exists public.driver_push_subscriptions(
  id uuid primary key default gen_random_uuid(), driver_id uuid not null references public.drivers(id) on delete cascade,
  endpoint text not null, p256dh text not null, auth text not null, user_agent text not null default '', created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(driver_id,endpoint)
);
alter table public.driver_push_subscriptions enable row level security;
revoke all on public.driver_push_subscriptions from anon,authenticated;

create table if not exists public.driver_push_jobs(
  id uuid primary key default gen_random_uuid(), offer_id uuid not null references public.trip_offers(id) on delete cascade,
  driver_id uuid not null references public.drivers(id) on delete cascade, trip_id uuid not null references public.trips(id) on delete cascade,
  created_at timestamptz not null default now(), delivered_at timestamptz, failed_at timestamptz, failure_reason text
);
alter table public.driver_push_jobs enable row level security;
revoke all on public.driver_push_jobs from anon,authenticated;

create or replace function private.push_subscription_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); endpoint_value text:=left(trim(payload->>'endpoint'),2048); key_value text:=left(trim(payload->>'p256dh'),512); auth_value text:=left(trim(payload->>'auth'),512);
begin
  if uid is null or not exists(select 1 from public.profiles where id=uid and role='driver' and not suspended) then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  if endpoint_value !~ '^https://' or length(key_value)<20 or length(auth_value)<10 then raise exception 'Suscripción de notificaciones inválida.'; end if;
  insert into public.driver_push_subscriptions(driver_id,endpoint,p256dh,auth,user_agent,updated_at)
  values(uid,endpoint_value,key_value,auth_value,left(coalesce(payload->>'user_agent',''),300),now())
  on conflict(driver_id,endpoint) do update set p256dh=excluded.p256dh,auth=excluded.auth,user_agent=excluded.user_agent,updated_at=now();
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.push_subscription_v1(jsonb) from public,anon;
grant execute on function private.push_subscription_v1(jsonb) to authenticated;

create or replace function private.queue_offer_push_v1() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='offered' and (tg_op='INSERT' or old.status is distinct from 'offered' or old.offered_at is distinct from new.offered_at) then
    insert into public.driver_push_jobs(offer_id,driver_id,trip_id) values(new.id,new.driver_id,new.trip_id);
  end if;
  return new;
end $$;
revoke all on function private.queue_offer_push_v1() from public,anon,authenticated;
drop trigger if exists queue_driver_offer_push on public.trip_offers;
create trigger queue_driver_offer_push after insert or update of status,offered_at on public.trip_offers for each row execute function private.queue_offer_push_v1();

create or replace function private.offers_v10(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); d public.drivers; waiting record;
begin
  perform private.expire_idle_drivers_v1();
  select * into d from public.drivers where id=uid for update;
  if uid is null or not found or not d.online or not d.approved or not d.account_active or not private.driver_shift_active_v1(uid)
    or not exists(select 1 from public.driver_presence p where p.driver_id=uid and p.heartbeat_at>now()-interval '1 minute') then return '[]'::jsonb; end if;
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 50 loop
    perform private.auto_assign_trip_v4(waiting.id,waiting.preferred_driver_id);
  end loop;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.expires_at),'[]'::jsonb) from (
    select o.id offer_id,o.offered_at,o.expires_at,t.id,t.origin,t.destination,t.origin_lat,t.origin_lng,t.dest_lat,t.dest_lng,t.planned_route,t.fare_cents,
      d.billing_mode,private.driver_commission_bps(uid,t.payment_method) commission_bps,round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer commission_cents,
      t.fare_cents-round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer+t.tip_cents net_cents,
      t.category,t.party_size,t.payment_method,t.distance_km,t.trip_eta_minutes,t.pickup_eta_minutes,t.service_notes,pr.full_name passenger_name,pr.avatar_path passenger_avatar_path,
      round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) pickup_from_driver_km
    from public.trip_offers o join public.trips t on t.id=o.trip_id join public.profiles pr on pr.id=t.passenger_id join public.driver_presence dp on dp.driver_id=o.driver_id
    where o.driver_id=uid and o.status='offered' and o.expires_at>now() and t.status='requested' and t.driver_id is null
  ) x);
end $$;
revoke all on function private.offers_v10(jsonb) from public,anon;
grant execute on function private.offers_v10(jsonb) to authenticated;

create or replace function private.trip_v14(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.trips;
begin
  perform private.expire_idle_drivers_v1();
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if found and t.status='requested' and (t.passenger_id=auth.uid() or exists(select 1 from public.drivers where id=auth.uid() and online)) then perform private.auto_assign_trip_v4(t.id,t.preferred_driver_id); end if;
  return private.trip_v12(payload);
end $$;
revoke all on function private.trip_v14(jsonb) from public,anon;
grant execute on function private.trip_v14(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v6(payload) when 'dashboard' then private.dashboard_v18(payload)
   when 'onboard' then private.onboard_referral_v2(payload) when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload) when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload) when 'trip' then private.trip_v14(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v10(payload) when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v4(payload) when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload) when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v5(payload) when 'offers' then private.offers_v10(payload) when 'accept' then private.accept_offer_v5(payload)
   when 'push_subscription' then private.push_subscription_v1(payload)
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
