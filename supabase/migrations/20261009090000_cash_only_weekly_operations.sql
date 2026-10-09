-- Production model: passengers pay drivers directly in cash. Yavoi! keeps
-- auditable tariff, commission and tax calculations, while Operations closes
-- the weekly commercial record outside the passenger and driver apps.
update private.app_settings set mercado_pago_enabled = false, updated_at = now() where id = true;
update public.finance_settings set payouts_enabled = false, payout_provider = 'manual', updated_at = now() where id = true;

-- Existing records remain protected for audit and fiscal traceability. New
-- client calls cannot create, update or inspect payout destinations.
create or replace function private.finance_digital_payments_disabled()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  raise exception 'Yavoi! no administra pagos digitales, cuentas, transferencias ni retiros desde la aplicación.' using errcode = '0A000';
end $$;

create or replace function private.finance_profile_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  return private.finance_digital_payments_disabled();
end $$;

create or replace function private.finance_withdraw_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  return private.finance_digital_payments_disabled();
end $$;

create or replace function private.finance_review_withdrawal_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  return private.finance_digital_payments_disabled();
end $$;

create or replace function private.request_cash_trip_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if coalesce(payload->>'payment_method','cash') <> 'cash' then
    raise exception 'Los nuevos viajes sólo admiten efectivo al finalizar.' using errcode = '22023';
  end if;
  return private.request_trip_v10(payload || jsonb_build_object('payment_method','cash'));
end $$;

create or replace function private.cash_post_trip_tip_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if coalesce(payload->>'payment_method','cash') <> 'cash' then
    raise exception 'Las propinas se registran únicamente como efectivo entregado al conductor.' using errcode = '22023';
  end if;
  return private.post_trip_tip_v1(payload || jsonb_build_object('payment_method','cash'));
end $$;

-- Operations can validate fiscal data and record internal adjustments, but it
-- never receives a bank destination through this RPC response.
create or replace function private.finance_operations_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare month_value date:=coalesce(nullif(payload->>'month','')::date,date_trunc('month',timezone('America/Chihuahua',now()))::date);
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Acceso de Operaciones requerido.' using errcode='42501'; end if;
 return jsonb_build_object(
  'settings',(select to_jsonb(s) - 'payout_provider' from public.finance_settings s where id),
  'drivers',(select coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'name',p.full_name,
    'fiscal',jsonb_build_object('entity',coalesce(f.entity,'individual'),'rfc',coalesce(f.rfc,''),'rfc_provided',coalesce(f.rfc_provided,false),'verified_at',f.verified_at),
    'wallet',jsonb_build_object('week_cash_cents',coalesce((private.finance_wallet_data(d.id)->>'week_cash_cents')::bigint,0),'week_net_cents',coalesce((private.finance_wallet_data(d.id)->>'week_net_cents')::bigint,0),'debt_cents',greatest(0,-coalesce((private.finance_wallet_data(d.id)->>'balance_cents')::bigint,0))
  ))),'[]'::jsonb) from public.drivers d join public.profiles p on p.id=d.id left join public.driver_fiscal_profiles f on f.driver_id=d.id),
  'month',month_value,
  'tax_summary',(select jsonb_build_object('isr_cents',coalesce(-sum(amount_cents) filter(where kind='isr' or (kind='refund' and detail->>'reversed_kind'='isr')),0),'vat_cents',coalesce(-sum(amount_cents) filter(where kind='vat' or (kind='refund' and detail->>'reversed_kind'='vat')),0)) from public.driver_wallet_entries where timezone('America/Chihuahua',coalesce(nullif(detail->>'collected_at','')::timestamptz,created_at))::date>=month_value and timezone('America/Chihuahua',coalesce(nullif(detail->>'collected_at','')::timestamptz,created_at))::date<month_value+interval '1 month'),
  'state_summary',(select coalesce(sum((financial_breakdown->>'state_contribution_cents')::bigint),0) from public.trips where status='completed' and financial_breakdown<>'{}' and timezone('America/Chihuahua',completed_at)::date>=month_value and timezone('America/Chihuahua',completed_at)::date<month_value+interval '1 month')
 );
end $$;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v6(payload) when 'dashboard' then private.finance_dashboard_v1(payload)
   when 'onboard' then private.onboard_referral_v2(payload) when 'profile' then private.profile_v5(payload)
   when 'quote' then private.finance_quote_v1(payload) when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_cash_trip_v1(payload) when 'trip' then private.trip_v14(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v10(payload) when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v4(payload) when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload) when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v5(payload) when 'offers' then private.finance_offers_v1(payload) when 'accept' then private.accept_offer_v5(payload)
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
   when 'post_trip_tip' then private.cash_post_trip_tip_v1(payload) when 'scheduled_operations' then private.scheduled_operations_v1(payload)
   when 'confirm_scheduled_trip' then private.confirm_scheduled_trip_v1(payload) when 'assign_scheduled_trip' then private.assign_scheduled_trip_v1(payload)
   when 'category' then private.category_v3(payload) when 'upsert_service_shift' then private.upsert_service_shift_v1(payload) when 'set_driver_shift' then private.set_driver_shift_v1(payload)
   when 'finance_wallet' then private.finance_wallet_v1(payload) when 'finance_verify_profile' then private.finance_verify_profile_v1(payload)
   when 'finance_funding' then private.finance_funding_v1(payload) when 'finance_settings' then private.finance_settings_v1(payload) when 'finance_operations' then private.finance_operations_v1(payload)
   when 'finance_profile' then private.finance_digital_payments_disabled() when 'finance_withdraw' then private.finance_digital_payments_disabled()
   when 'finance_review_withdrawal' then private.finance_digital_payments_disabled() when 'payment_checkout' then private.finance_digital_payments_disabled()
   when 'refund_checkout' then private.finance_digital_payments_disabled() when 'submit_weekly_fee' then private.finance_digital_payments_disabled()
   when 'review_weekly_fee' then private.finance_digital_payments_disabled() when 'submit_driver_settlement' then private.finance_digital_payments_disabled()
   when 'review_driver_settlement' then private.finance_digital_payments_disabled() when 'review_driver_promotion_reimbursement' then private.finance_digital_payments_disabled()
   else private.dispatch(command,payload) end
$$;

revoke all on function public.finance_manual_settlement(jsonb) from public, anon, authenticated;
revoke all on function public.finance_manual_settlements() from public, anon, authenticated;
revoke all on function private.finance_digital_payments_disabled() from public, anon;
grant execute on function private.finance_digital_payments_disabled() to authenticated;
revoke all on function public.yavoi(text,jsonb) from public, anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
