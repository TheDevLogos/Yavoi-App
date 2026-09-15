-- Apply the driver's commercial agreement when a reserved trip becomes active
-- and expose accrued versus collected platform revenue to Operations.
create or replace function private.release_scheduled_trips_v1() returns void
language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  update public.trips t set driver_id=null,updated_at=now()
  where t.status='scheduled' and t.driver_id is not null and t.scheduled_at<=now()+interval '15 minutes'
    and (
      not exists(
        select 1 from public.drivers d join public.profiles p on p.id=d.id
        where d.id=t.driver_id and p.role='driver' and not p.suspended and d.approved and d.account_active
          and d.license_expires>=current_date and d.insurance_expires>=current_date
          and private.driver_can_cover_category_v1(d.category,t.category)
          and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
      )
      or exists(select 1 from public.trips busy where busy.driver_id=t.driver_id and busy.id<>t.id and busy.status in ('accepted','arrived','in_progress'))
    );

  for waiting in
    select t.id,d.id as driver_id,d.billing_mode,
      private.driver_commission_bps(d.id,t.payment_method) as commission_bps
    from public.trips t join public.drivers d on d.id=t.driver_id
    where t.status='scheduled' and t.scheduled_at<=now()+interval '15 minutes'
      and (t.payment_method='cash' or t.payment_status='paid')
    for update of t
  loop
    update public.trips set status='accepted',billing_mode=waiting.billing_mode,
      commission_bps_applied=waiting.commission_bps,
      commission_cents=round(fare_cents*waiting.commission_bps/10000.0)::integer,
      updated_at=now()
    where id=waiting.id;
    insert into public.trip_events(trip_id,actor_id,event,detail)
    values(waiting.id,waiting.driver_id,'accepted',jsonb_build_object(
      'scheduled_activation',true,'billing_mode',waiting.billing_mode,'commission_bps',waiting.commission_bps
    ));
  end loop;

  update public.trips set status='requested',updated_at=now()
  where status='scheduled' and driver_id is null and scheduled_at<=now()+interval '15 minutes'
    and (payment_method='cash' or payment_status='paid');
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
  end loop;
end $$;
revoke all on function private.release_scheduled_trips_v1() from public,anon,authenticated;

create function private.operations_report_v3(payload jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  base jsonb;
  start_value timestamptz;
  end_value timestamptz;
  driver_value uuid:=nullif(payload->>'driver_id','')::uuid;
  trip_commission bigint:=0;
  electronic_commission bigint:=0;
  cash_commission bigint:=0;
  weekly_collected bigint:=0;
  transfers_collected bigint:=0;
  transfers_pending bigint:=0;
begin
  base:=private.operations_report_v2(payload);
  start_value:=(base#>>'{meta,from}')::timestamptz;
  end_value:=(base#>>'{meta,to}')::timestamptz;

  select coalesce(sum(t.commission_cents),0),
    coalesce(sum(t.commission_cents) filter(where t.payment_method='card'),0),
    coalesce(sum(t.commission_cents) filter(where t.payment_method='cash'),0)
  into trip_commission,electronic_commission,cash_commission
  from public.trips t
  where t.status='completed' and coalesce(t.completed_at,t.created_at)>=start_value
    and coalesce(t.completed_at,t.created_at)<end_value
    and (driver_value is null or t.driver_id=driver_value);

  select coalesce(sum(pay.amount_cents),0) into weekly_collected
  from public.payments pay
  where pay.kind='weekly_fee' and pay.status='approved'
    and coalesce(pay.provider_approved_at,pay.updated_at,pay.created_at)>=start_value
    and coalesce(pay.provider_approved_at,pay.updated_at,pay.created_at)<end_value
    and (driver_value is null or pay.driver_id=driver_value);

  select
    coalesce(sum(s.commission_due_cents) filter(where s.status='paid' and coalesce(s.verified_at,s.updated_at)>=start_value and coalesce(s.verified_at,s.updated_at)<end_value),0),
    coalesce(sum(s.commission_due_cents) filter(where s.status in ('pending','submitted','overdue') and s.week_start>=start_value::date and s.week_start<end_value::date),0)
  into transfers_collected,transfers_pending
  from public.driver_commission_settlements s
  where driver_value is null or s.driver_id=driver_value;

  return base||jsonb_build_object(
    'commercial_summary',jsonb_build_object(
      'trip_commission_accrued_cents',trip_commission,
      'electronic_commission_retained_cents',electronic_commission,
      'cash_commission_accrued_cents',cash_commission,
      'weekly_fees_collected_cents',weekly_collected,
      'cash_transfers_collected_cents',transfers_collected,
      'cash_transfers_pending_cents',transfers_pending,
      'platform_revenue_accrued_cents',trip_commission+weekly_collected,
      'platform_revenue_collected_cents',electronic_commission+weekly_collected+transfers_collected
    ),
    'billing_drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (
      select d.id,p.full_name,d.billing_mode,d.weekly_fee_cents,d.cash_commission_bps,d.card_commission_bps,
        ride.completed,ride.gross_cents,ride.driver_earnings_cents,ride.trip_commission_cents,
        ride.cash_commission_cents,ride.electronic_commission_cents,
        fee.weekly_fees_collected_cents,settled.cash_transfers_collected_cents,
        settled.cash_transfers_pending_cents,
        ride.trip_commission_cents+fee.weekly_fees_collected_cents as platform_revenue_accrued_cents,
        ride.electronic_commission_cents+fee.weekly_fees_collected_cents+settled.cash_transfers_collected_cents as platform_revenue_collected_cents
      from public.drivers d join public.profiles p on p.id=d.id
      left join lateral (
        select count(*) filter(where t.status='completed') as completed,
          coalesce(sum(t.total_cents) filter(where t.status='completed'),0) as gross_cents,
          coalesce(sum(t.fare_cents-t.commission_cents+t.tip_cents) filter(where t.status='completed'),0) as driver_earnings_cents,
          coalesce(sum(t.commission_cents) filter(where t.status='completed'),0) as trip_commission_cents,
          coalesce(sum(t.commission_cents) filter(where t.status='completed' and t.payment_method='cash'),0) as cash_commission_cents,
          coalesce(sum(t.commission_cents) filter(where t.status='completed' and t.payment_method='card'),0) as electronic_commission_cents
        from public.trips t where t.driver_id=d.id and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value
      ) ride on true
      left join lateral (
        select coalesce(sum(pay.amount_cents),0) as weekly_fees_collected_cents
        from public.payments pay where pay.driver_id=d.id and pay.kind='weekly_fee' and pay.status='approved'
          and coalesce(pay.provider_approved_at,pay.updated_at,pay.created_at)>=start_value
          and coalesce(pay.provider_approved_at,pay.updated_at,pay.created_at)<end_value
      ) fee on true
      left join lateral (
        select
          coalesce(sum(s.commission_due_cents) filter(where s.status='paid' and coalesce(s.verified_at,s.updated_at)>=start_value and coalesce(s.verified_at,s.updated_at)<end_value),0) as cash_transfers_collected_cents,
          coalesce(sum(s.commission_due_cents) filter(where s.status in ('pending','submitted','overdue') and s.week_start>=start_value::date and s.week_start<end_value::date),0) as cash_transfers_pending_cents
        from public.driver_commission_settlements s where s.driver_id=d.id
      ) settled on true
      where driver_value is null or d.id=driver_value
    )x)
  );
end $$;
revoke all on function private.operations_report_v3(jsonb) from public,anon;
grant execute on function private.operations_report_v3(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v11(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v8(payload)
   when 'trip' then private.trip_v9(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v7(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v6(payload)
   when 'accept' then private.accept_offer_v2(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
   when 'transition' then private.transition_v7(payload)
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
   when 'operations_report' then private.operations_report_v3(payload)
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
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
