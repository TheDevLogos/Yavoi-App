-- An offer is intentionally brief.  The ninety second period belongs to the
-- matching cooldown, never to a driver-facing decision timer.

create table if not exists public.ride_preferences(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  pickup_pin_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.ride_preferences enable row level security;

create or replace function private.ride_preferences_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); result public.ride_preferences;
begin
  if uid is null or not exists(select 1 from public.profiles where id=uid and role='passenger') then
    raise exception 'Sólo el perfil de pasajero puede cambiar estas preferencias.' using errcode='42501';
  end if;
  if payload ? 'pickup_pin_enabled' then
    insert into public.ride_preferences(user_id,pickup_pin_enabled,updated_at)
    values(uid,coalesce((payload->>'pickup_pin_enabled')::boolean,false),now())
    on conflict(user_id) do update set pickup_pin_enabled=excluded.pickup_pin_enabled,updated_at=now()
    returning * into result;
  else
    select * into result from public.ride_preferences where user_id=uid;
    if not found then
      insert into public.ride_preferences(user_id) values(uid) returning * into result;
    end if;
  end if;
  return jsonb_build_object('pickup_pin_enabled',result.pickup_pin_enabled);
end $$;
revoke all on function private.ride_preferences_v1(jsonb) from public,anon;
grant execute on function private.ride_preferences_v1(jsonb) to authenticated;

create or replace function private.auto_assign_trip_v2(target_trip uuid, preferred uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare t public.trips; chosen uuid;
begin
  select * into t from public.trips where id=target_trip for update;
  if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id; end if;
  update public.trip_offers set status='expired',responded_at=now(),response_reason='Tiempo de respuesta agotado'
    where trip_id=t.id and status='offered' and expires_at<=now();
  select driver_id into chosen from public.trip_offers where trip_id=t.id and status='offered' and expires_at>now();
  if chosen is not null then return chosen; end if;
  select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
  where private.driver_candidate_eligible_v2(d.id,t.women_only,t.accessible)
    and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
  order by case when d.id=preferred then 0 else 1 end,
    private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.heartbeat_at desc
  for update of d skip locked limit 1;
  if chosen is null then
    select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where private.driver_candidate_eligible_v2(d.id,t.women_only,t.accessible)
      and (select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id) <= now()-interval '90 seconds'
    order by (select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id),
      private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)
    for update of d skip locked limit 1;
  end if;
  if chosen is not null then
    insert into public.trip_offers(trip_id,driver_id,expires_at) values(t.id,chosen,now()+interval '8 seconds');
    insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,chosen,'offer_sent',
      jsonb_build_object('preferred',chosen=preferred,'expires_in_seconds',8,'retry_after_seconds',90,'progressive_search',true));
  end if;
  return chosen;
end $$;
revoke all on function private.auto_assign_trip_v2(uuid,uuid) from public,anon,authenticated;

create or replace function private.trip_v12(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; target public.trips; pin_enabled boolean:=false;
begin
  base:=private.trip_v11(payload) - 'pin';
  select * into target from public.trips where id=(payload->>'trip_id')::uuid;
  if found then
    select pickup_pin_enabled into pin_enabled from public.ride_preferences where user_id=target.passenger_id;
  end if;
  return base || jsonb_build_object('pin_required',coalesce(pin_enabled,false));
end $$;
revoke all on function private.trip_v12(jsonb) from public,anon;
grant execute on function private.trip_v12(jsonb) to authenticated;

create or replace function private.transition_v10(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); t public.trips; pin_enabled boolean:=false;
begin
  if payload->>'status'<>'in_progress' then return private.transition_v9(payload); end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
  if uid is null or not found or t.driver_id is distinct from uid or t.status<>'arrived'
    or not exists(select 1 from public.drivers where id=uid and approved and account_active) then
    raise exception 'No es posible iniciar este viaje.' using errcode='42501';
  end if;
  select pickup_pin_enabled into pin_enabled from public.ride_preferences where user_id=t.passenger_id;
  if coalesce(pin_enabled,false) and (select pin from private.trip_secrets where trip_id=t.id) is distinct from payload->>'pin' then
    raise exception 'El código de inicio no coincide.' using errcode='42501';
  end if;
  update public.trips set status='in_progress',updated_at=now() where id=t.id returning * into t;
  insert into public.trip_events(trip_id,actor_id,event,detail)
  values(t.id,uid,'in_progress',jsonb_build_object('pickup_pin_required',coalesce(pin_enabled,false)));
  return to_jsonb(t);
end $$;
revoke all on function private.transition_v10(jsonb) from public,anon;
grant execute on function private.transition_v10(jsonb) to authenticated;

create or replace function private.location_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; t public.trips; distance_km numeric; speed_value float8:=nullif(payload->>'speed','')::float8;
begin
  result:=private.location_v4(payload);
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if t.status='in_progress' then
    distance_km:=private.haversine_km(t.dest_lat,t.dest_lng,(payload->>'lat')::float8,(payload->>'lng')::float8);
    if distance_km<=0.065 and (speed_value is null or speed_value<=5) then
      result:=result||jsonb_build_object('destination_reached',true,'destination_distance_m',round(distance_km*1000));
    end if;
  end if;
  return result;
end $$;
revoke all on function private.location_v5(jsonb) from public,anon;
grant execute on function private.location_v5(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload) when 'dashboard' then private.dashboard_v18(payload)
   when 'onboard' then private.onboard_referral_v2(payload) when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload) when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload) when 'trip' then private.trip_v12(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v9(payload) when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v3(payload) when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload) when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v5(payload) when 'offers' then private.offers_v8(payload) when 'accept' then private.accept_offer_v4(payload)
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
