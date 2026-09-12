-- Record the exact Yavoi! commitment-letter revision submitted by each driver.
create function private.driver_profile_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result jsonb;
begin
  result:=private.driver_profile_v5(payload);
  update public.drivers set
    policy_version=case
      when nullif(payload->>'policy_commitment_path','') is not null then 'YV-POL-CON-2026.09.12'
      else policy_version end,
    traffic_law_version=case
      when nullif(payload->>'traffic_law_commitment_path','') is not null then 'YV-VIAL-POE-2026.08.08-63'
      else traffic_law_version end,
    updated_at=now()
  where id=uid;
  if nullif(payload->>'policy_commitment_path','') is not null
     or nullif(payload->>'traffic_law_commitment_path','') is not null then
    insert into public.audit_log(actor_id,action,target_id,detail) values(
      uid,'driver_letters_submitted',uid,
      jsonb_build_object(
        'policy_version',(select policy_version from public.drivers where id=uid),
        'traffic_law_version',(select traffic_law_version from public.drivers where id=uid)
      )
    );
  end if;
  return result||jsonb_build_object(
    'policy_version',(select policy_version from public.drivers where id=uid),
    'traffic_law_version',(select traffic_law_version from public.drivers where id=uid)
  );
end $$;
revoke all on function private.driver_profile_v6(jsonb) from public,anon;
grant execute on function private.driver_profile_v6(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v9(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v7(payload)
   when 'trip' then private.trip_v6(payload)
   when 'driver_profile' then private.driver_profile_v6(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v5(payload)
   when 'accept' then private.accept_offer_v2(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'transition' then private.transition_v6(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v1(payload)
   when 'redeem_reward' then private.redeem_reward_v3(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v1(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v1(payload)
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
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
