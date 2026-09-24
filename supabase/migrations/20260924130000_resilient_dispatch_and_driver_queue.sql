-- Keep searching after every declined/expired offer, retry a sole eligible unit
-- only after a short pause, and allow one next trip while the driver is en route.

create or replace function private.driver_candidate_eligible_v2(target uuid,women_required boolean,accessible_required boolean) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where d.id=target and d.online and d.approved and d.account_active
      and private.driver_shift_active_v1(d.id) and dp.heartbeat_at>now()-interval '90 seconds'
      and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
      and (not women_required or d.female_verified) and (not accessible_required or d.accessible_verified)
      -- A driver may receive exactly one following request only while completing
      -- the current service. They are never offered work while going to pickup.
      and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status in ('accepted','arrived'))
      and (select count(*) from public.trips busy where busy.driver_id=d.id and busy.status='in_progress') <= 1
      and (select count(*) from public.trips queued where queued.driver_id=d.id and queued.status='accepted') = 0
      and not exists(select 1 from public.trip_offers active_offer where active_offer.driver_id=d.id and active_offer.status='offered' and active_offer.expires_at>now())
  )
$$;
revoke all on function private.driver_candidate_eligible_v2(uuid,boolean,boolean) from public,anon,authenticated;

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
  -- First pass reaches every compatible, online unit in order of proximity.
  select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
  where private.driver_candidate_eligible_v2(d.id,t.women_only,t.accessible)
    and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
  order by case when d.id=preferred then 0 else 1 end,
    private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.heartbeat_at desc
  for update of d skip locked limit 1;
  -- Once all units had a chance, retry the least recently notified unit after
  -- 90 seconds. This prevents a request from silently stopping with one driver.
  if chosen is null then
    select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
    where private.driver_candidate_eligible_v2(d.id,t.women_only,t.accessible)
      and (select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id) <= now()-interval '90 seconds'
    order by (select max(prior.offered_at) from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id),
      private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)
    for update of d skip locked limit 1;
  end if;
  if chosen is not null then
    insert into public.trip_offers(trip_id,driver_id) values(t.id,chosen);
    insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,chosen,'offer_sent',
      jsonb_build_object('preferred',chosen=preferred,'expires_in_seconds',60,'progressive_search',true));
  end if;
  return chosen;
end $$;
revoke all on function private.auto_assign_trip_v2(uuid,uuid) from public,anon,authenticated;

create or replace function private.offers_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); d public.drivers; waiting record;
begin
  select * into d from public.drivers where id=uid for update;
  if uid is null or not found or not d.online or not d.approved or not d.account_active or not private.driver_shift_active_v1(uid) then return '[]'::jsonb; end if;
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip_v2(waiting.id,waiting.preferred_driver_id);
  end loop;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.expires_at),'[]') from (
    select o.id offer_id,o.expires_at,t.id,t.origin,t.destination,t.fare_cents,
      t.fare_cents-round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer+t.tip_cents net_cents,
      t.category,t.party_size,t.payment_method,t.distance_km,t.trip_eta_minutes,t.pickup_eta_minutes,t.service_notes,
      pr.full_name passenger_name,pr.avatar_path passenger_avatar_path,
      round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) pickup_from_driver_km
    from public.trip_offers o join public.trips t on t.id=o.trip_id join public.profiles pr on pr.id=t.passenger_id
      join public.driver_presence dp on dp.driver_id=o.driver_id
    where o.driver_id=uid and o.status='offered' and o.expires_at>now() and t.status='requested' and t.driver_id is null
  ) x);
end $$;
revoke all on function private.offers_v8(jsonb) from public,anon;
grant execute on function private.offers_v8(jsonb) to authenticated;

create or replace function private.accept_offer_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); o public.trip_offers; t public.trips; d public.drivers; bps integer; commission_value integer; active_trip uuid;
begin
  select * into o from public.trip_offers where id=(payload->>'offer_id')::uuid and driver_id=uid for update;
  if uid is null or not found or o.status<>'offered' or o.expires_at<=now() then raise exception 'La solicitud ya no está disponible.' using errcode='42501'; end if;
  select * into d from public.drivers where id=uid for update;
  select * into t from public.trips where id=o.trip_id for update;
  if not private.driver_candidate_eligible_v2(uid,t.women_only,t.accessible) or t.status<>'requested' or t.driver_id is not null then raise exception 'La solicitud ya no está disponible.'; end if;
  select id into active_trip from public.trips where driver_id=uid and status='in_progress' order by updated_at desc limit 1;
  bps:=private.driver_commission_bps(uid,t.payment_method); commission_value:=round(t.fare_cents*bps/10000.0)::integer;
  update public.trip_offers set status='accepted',responded_at=now() where id=o.id;
  update public.trips set driver_id=uid,status='accepted',billing_mode=d.billing_mode,commission_bps_applied=bps,commission_cents=commission_value,updated_at=now() where id=t.id returning * into t;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,case when active_trip is null then 'accepted' else 'accepted_as_next_trip' end,jsonb_build_object('offer_id',o.id,'after_trip_id',active_trip));
  return to_jsonb(t)||jsonb_build_object('queued_after_trip_id',active_trip);
end $$;
revoke all on function private.accept_offer_v4(jsonb) from public,anon;
grant execute on function private.accept_offer_v4(jsonb) to authenticated;

create or replace function private.location_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; t public.trips; distance_km numeric; speed_value float8:=nullif(payload->>'speed','')::float8;
begin
  result:=private.location_v3(payload);
  select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
  if t.status='accepted' then
    distance_km:=private.haversine_km(t.origin_lat,t.origin_lng,(payload->>'lat')::float8,(payload->>'lng')::float8);
    if distance_km<=0.065 and (speed_value is null or speed_value<=5) then
      update public.trips set status='arrived',updated_at=now() where id=t.id;
      insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'arrived_automatically',jsonb_build_object('distance_m',round(distance_km*1000),'speed_mps',speed_value));
      result:=result||jsonb_build_object('arrived_automatically',true);
    end if;
  end if;
  return result;
end $$;
revoke all on function private.location_v4(jsonb) from public,anon;
grant execute on function private.location_v4(jsonb) to authenticated;

create or replace function private.trip_v11(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.trips;
begin
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if found and t.status='requested' and t.passenger_id=auth.uid() then perform private.auto_assign_trip_v2(t.id,t.preferred_driver_id); end if;
  return private.trip_v10(payload);
end $$;
revoke all on function private.trip_v11(jsonb) from public,anon;
grant execute on function private.trip_v11(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload) when 'dashboard' then private.dashboard_v18(payload)
   when 'onboard' then private.onboard_referral_v2(payload) when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload) when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload) when 'trip' then private.trip_v11(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v9(payload) when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v3(payload) when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload) when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v4(payload) when 'offers' then private.offers_v8(payload) when 'accept' then private.accept_offer_v4(payload)
   when 'reject_offer' then private.reject_offer_v1(payload) when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload) when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload) when 'transition' then private.transition_v9(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload) when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'complaint' then private.complaint_v2(payload) when 'rating' then private.rating_v3(payload) when 'rating_and_report' then private.rating_and_report_v2(payload)
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
