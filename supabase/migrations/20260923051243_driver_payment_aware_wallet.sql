-- Make the driver wallet payment-aware: cash is collected directly, while
-- electronic earnings and Yavoi-funded promotions remain visible as a platform-held balance.
create function private.dashboard_v17(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid();
  p public.profiles;
  base jsonb;
  cash_collected bigint:=0;
  electronic_gross bigint:=0;
  electronic_net bigint:=0;
  promotion_pending bigint:=0;
  electronic_balance bigint:=0;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then
    raise exception 'Inicia sesión para continuar.' using errcode='42501';
  end if;
  base:=private.dashboard_v16(payload);
  if p.role='driver' then
    select
      coalesce(sum(t.total_cents) filter(where t.status='completed' and t.payment_method='cash'),0),
      coalesce(sum(t.total_cents) filter(where t.status='completed' and t.payment_method='card'),0),
      coalesce(sum(t.fare_cents-t.commission_cents+t.tip_cents) filter(where t.status='completed' and t.payment_method='card'),0)
    into cash_collected,electronic_gross,electronic_net
    from public.trips t where t.driver_id=uid;
    select coalesce(sum(r.reimbursement_cents),0) into promotion_pending
    from public.driver_promotion_reimbursements r
    where r.driver_id=uid and r.status in ('pending','overdue');
    electronic_balance:=electronic_net+promotion_pending;
    base:=jsonb_set(base,'{driver_money}',jsonb_build_object(
      'cash_collected_cents',cash_collected,
      'electronic_gross_cents',electronic_gross,
      'electronic_net_cents',electronic_net,
      'promotion_reimbursements_pending_cents',promotion_pending,
      'electronic_balance_cents',electronic_balance,
      'withdrawals_enabled',false,
      'withdrawal_status','not_configured'
    ),true);
  end if;
  return base;
end $$;
revoke all on function private.dashboard_v17(jsonb) from public,anon;
grant execute on function private.dashboard_v17(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload)
   when 'dashboard' then private.dashboard_v17(payload)
   when 'onboard' then private.onboard_referral_v2(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload)
   when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload)
   when 'trip' then private.trip_v10(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v9(payload)
   when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v3(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload)
   when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v7(payload)
   when 'accept' then private.accept_offer_v3(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
   when 'transition' then private.transition_v9(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v5(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v2(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v3(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v5(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
   when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload)
   when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'review_driver_promotion_reimbursement' then private.review_driver_promotion_reimbursement_v1(payload)
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
   when 'set_driver_shift' then private.set_driver_shift_v1(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
