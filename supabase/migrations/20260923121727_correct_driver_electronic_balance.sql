-- The original electronic summary started from the contractual fare and then
-- added the promotion reimbursement again. Start from money actually collected
-- on completed card trips, subtract the contracted commission, and add the
-- still outstanding Yavoi!-funded reimbursement exactly once.
create or replace function private.dashboard_v17(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid();
  p public.profiles;
  base jsonb;
  cash_collected bigint:=0;
  electronic_ride_gross bigint:=0;
  card_commission bigint:=0;
  post_trip_card_tips bigint:=0;
  electronic_gross bigint:=0;
  electronic_net bigint:=0;
  promotion_pending bigint:=0;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then
    raise exception 'Inicia sesión para continuar.' using errcode='42501';
  end if;
  base:=private.dashboard_v16(payload);
  if p.role='driver' then
    select
      coalesce(sum(t.total_cents) filter(where t.payment_method='cash'),0),
      coalesce(sum(t.total_cents) filter(where t.payment_method='card'),0),
      coalesce(sum(t.commission_cents) filter(where t.payment_method='card'),0)
    into cash_collected,electronic_ride_gross,card_commission
    from public.trips t where t.driver_id=uid and t.status='completed';
    select coalesce(sum(pay.amount_cents),0) into post_trip_card_tips
    from public.payments pay
    join public.trips t on t.id=pay.trip_id
    where pay.driver_id=uid and t.driver_id=uid and t.status='completed'
      and pay.kind='tip' and pay.provider='mercado_pago' and pay.status='approved';
    select coalesce(sum(r.reimbursement_cents),0) into promotion_pending
    from public.driver_promotion_reimbursements r
    where r.driver_id=uid and r.status in ('pending','overdue');
    electronic_gross:=electronic_ride_gross+post_trip_card_tips;
    electronic_net:=electronic_gross-card_commission;
    base:=jsonb_set(base,'{driver_money}',jsonb_build_object(
      'cash_collected_cents',cash_collected,
      'electronic_gross_cents',electronic_gross,
      'electronic_net_cents',electronic_net,
      'promotion_reimbursements_pending_cents',promotion_pending,
      'electronic_balance_cents',electronic_net+promotion_pending,
      'withdrawals_enabled',false,
      'withdrawal_status','not_configured'
    ),true);
  end if;
  return base;
end $$;

revoke all on function private.dashboard_v17(jsonb) from public,anon;
grant execute on function private.dashboard_v17(jsonb) to authenticated;
