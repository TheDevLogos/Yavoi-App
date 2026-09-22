-- Complete referral acquisition rewards and make Yavoi-funded ride promotions
-- auditable without reducing the driver's contractual earnings.

alter table public.reward_entries drop constraint if exists reward_entries_entry_type_check;
alter table public.reward_entries add constraint reward_entries_entry_type_check
  check(entry_type in (
    'trip_complete','rating_given','rating_bonus','adjustment','redemption','redemption_refund',
    'referral_registered','referral_first_trip','referral_welcome'
  ));

insert into public.reward_catalog(
  id,audience,name,description,kind,icon,points_cost,value_percent,max_discount_cents,
  min_trips,min_income_cents,partner_name,fulfillment_note,automatic,milestone_every,
  active,sort_order,terms,delivery_mode,expires_days,claim_method,claim_instructions,
  claim_button_label,program_type,min_referrals_registered,min_referrals_first_trip
) values (
  'passenger_referral_welcome_20','passenger','20% en tu primer viaje',
  'Beneficio de bienvenida para pasajeros que se registran con una invitación verificada.',
  'fare_discount_percent','badge-percent',0,20,4000,
  0,0,'Yavoi!','Yavoi! absorbe este descuento; no reduce el ingreso contractual del conductor.',
  true,1,true,4,
  '20% de descuento, máximo $40 MXN. Sólo puede utilizarse en el primer viaje completado y vence 30 días después del registro.',
  'trip',30,'trip','Elige este beneficio al confirmar tu primer viaje. Si cancelas, vuelve a quedar disponible mientras no hayas completado otro viaje.',
  'Aplicar a mi primer viaje','referral',0,0
) on conflict(id) do update set
  name=excluded.name,description=excluded.description,kind=excluded.kind,icon=excluded.icon,
  points_cost=excluded.points_cost,value_percent=excluded.value_percent,max_discount_cents=excluded.max_discount_cents,
  partner_name=excluded.partner_name,fulfillment_note=excluded.fulfillment_note,automatic=excluded.automatic,
  milestone_every=excluded.milestone_every,active=excluded.active,sort_order=excluded.sort_order,
  terms=excluded.terms,delivery_mode=excluded.delivery_mode,expires_days=excluded.expires_days,
  claim_method=excluded.claim_method,claim_instructions=excluded.claim_instructions,
  claim_button_label=excluded.claim_button_label,program_type=excluded.program_type,
  min_referrals_registered=excluded.min_referrals_registered,
  min_referrals_first_trip=excluded.min_referrals_first_trip,updated_at=now();

create function private.onboard_referral_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result jsonb;welcome public.reward_catalog;
begin
  result:=private.onboard_referral_v1(payload);
  if payload->>'role'='passenger'
    and exists(select 1 from public.referrals where invitee_id=uid) then
    select * into welcome from public.reward_catalog where id='passenger_referral_welcome_20' and active;
    if found then
      insert into public.reward_redemptions(
        user_id,reward_id,code,status,points_spent,source_key,expires_at,reward_snapshot
      ) values (
        uid,welcome.id,'YV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
        'available',0,'referral:welcome_discount:'||uid::text,
        now()+make_interval(days=>welcome.expires_days),to_jsonb(welcome)
      ) on conflict(source_key) do nothing;
    end if;
  end if;
  return result;
end $$;
revoke all on function private.onboard_referral_v2(jsonb) from public,anon;
grant execute on function private.onboard_referral_v2(jsonb) to authenticated;

create function private.request_trip_v10(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();code_value text:=trim(coalesce(payload->>'reward_code',''));reward_id_value text;
begin
  if code_value<>'' then
    select reward_id into reward_id_value from public.reward_redemptions
    where user_id=uid and code=code_value;
    if reward_id_value='passenger_referral_welcome_20'
      and exists(select 1 from public.trips where passenger_id=uid and status='completed') then
      raise exception 'El descuento de bienvenida sólo puede utilizarse en tu primer viaje.';
    end if;
  end if;
  return private.request_trip_v9(payload);
end $$;
revoke all on function private.request_trip_v10(jsonb) from public,anon;
grant execute on function private.request_trip_v10(jsonb) to authenticated;

create function private.transition_v9(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;ref public.referrals;
begin
  result:=private.transition_v7(payload);
  if result ? 'error' then return result;end if;
  if payload->>'status'='completed' then
    select * into t from public.trips where id=(payload->>'trip_id')::uuid;
    if t.status='completed' then
      update public.referrals set first_trip_at=coalesce(t.completed_at,now()),first_trip_id=t.id
      where invitee_id=t.passenger_id and first_trip_at is null returning * into ref;
      if found then
        insert into public.reward_entries(user_id,trip_id,points,entry_type,description,source_key,detail)
        values(ref.inviter_id,t.id,70,'referral_first_trip','Invitación efectiva · primer viaje completado',
          'referral:first_trip:'||ref.invitee_id::text,
          jsonb_build_object('invitee_id',ref.invitee_id,'referral_id',ref.id))
        on conflict(source_key) where source_key is not null do nothing;
        insert into public.audit_log(actor_id,action,target_id,detail)
        values(auth.uid(),'referral_first_trip_completed',ref.id,
          jsonb_build_object('inviter_id',ref.inviter_id,'invitee_id',ref.invitee_id,'trip_id',t.id));
      end if;
      update public.reward_redemptions set status='expired',updated_at=now()
      where user_id=t.passenger_id and reward_id='passenger_referral_welcome_20' and status='available';
    end if;
  end if;
  return result;
end $$;
revoke all on function private.transition_v9(jsonb) from public,anon;
grant execute on function private.transition_v9(jsonb) to authenticated;

create table public.driver_promotion_reimbursements(
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete restrict,
  week_start date not null,
  due_at timestamptz not null,
  trip_count integer not null default 0 check(trip_count>=0),
  free_trip_count integer not null default 0 check(free_trip_count>=0 and free_trip_count<=trip_count),
  cash_discount_cents integer not null default 0 check(cash_discount_cents>=0),
  card_discount_cents integer not null default 0 check(card_discount_cents>=0),
  reimbursement_cents integer not null default 0 check(reimbursement_cents>=0),
  status text not null default 'pending' check(status in ('pending','paid','overdue')),
  transfer_reference text not null default '' check(char_length(transfer_reference)<=160),
  paid_at timestamptz,
  paid_by uuid references public.profiles(id),
  note text not null default '' check(char_length(note)<=1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(driver_id,week_start),
  check(reimbursement_cents=cash_discount_cents+card_discount_cents)
);
create index driver_promotion_reimbursements_status_due
  on public.driver_promotion_reimbursements(status,due_at);
create index driver_promotion_reimbursements_paid_by
  on public.driver_promotion_reimbursements(paid_by) where paid_by is not null;

alter table public.driver_promotion_reimbursements enable row level security;
revoke all on public.driver_promotion_reimbursements from anon,authenticated;
grant select on public.driver_promotion_reimbursements to authenticated;
create policy driver_promotion_reimbursements_read
  on public.driver_promotion_reimbursements for select to authenticated
  using(driver_id=(select auth.uid()) or (select private.is_admin()));

insert into public.driver_promotion_reimbursements(
  driver_id,week_start,due_at,trip_count,free_trip_count,
  cash_discount_cents,card_discount_cents,reimbursement_cents
)
select
  t.driver_id,
  date_trunc('week',timezone('America/Chihuahua',coalesce(t.completed_at,t.created_at)))::date as week_start,
  (date_trunc('week',timezone('America/Chihuahua',coalesce(t.completed_at,t.created_at)))::date+7)::timestamp at time zone 'America/Chihuahua',
  count(*)::integer,
  count(*) filter(where t.fare_cents>0 and t.reward_discount_cents>=t.fare_cents)::integer,
  coalesce(sum(t.reward_discount_cents) filter(where t.payment_method='cash'),0)::integer,
  coalesce(sum(t.reward_discount_cents) filter(where t.payment_method='card'),0)::integer,
  coalesce(sum(t.reward_discount_cents),0)::integer
from public.trips t
where t.status='completed' and t.driver_id is not null and t.reward_discount_cents>0
group by t.driver_id,date_trunc('week',timezone('America/Chihuahua',coalesce(t.completed_at,t.created_at)))::date
on conflict(driver_id,week_start) do update set
  due_at=excluded.due_at,trip_count=excluded.trip_count,free_trip_count=excluded.free_trip_count,
  cash_discount_cents=excluded.cash_discount_cents,card_discount_cents=excluded.card_discount_cents,
  reimbursement_cents=excluded.reimbursement_cents,updated_at=now();

create function private.record_promotion_reimbursement_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare start_day date;cash_value integer:=0;card_value integer:=0;free_value integer:=0;
begin
  if new.status='completed' and (tg_op='INSERT' or old.status is distinct from 'completed')
    and new.driver_id is not null and new.reward_discount_cents>0 then
    start_day:=date_trunc('week',timezone('America/Chihuahua',coalesce(new.completed_at,now())))::date;
    cash_value:=case when new.payment_method='cash' then new.reward_discount_cents else 0 end;
    card_value:=case when new.payment_method='card' then new.reward_discount_cents else 0 end;
    free_value:=case when new.fare_cents>0 and new.reward_discount_cents>=new.fare_cents then 1 else 0 end;
    insert into public.driver_promotion_reimbursements(
      driver_id,week_start,due_at,trip_count,free_trip_count,
      cash_discount_cents,card_discount_cents,reimbursement_cents
    ) values (
      new.driver_id,start_day,(start_day+7)::timestamp at time zone 'America/Chihuahua',
      1,free_value,cash_value,card_value,new.reward_discount_cents
    )
    on conflict(driver_id,week_start) do update set
      trip_count=public.driver_promotion_reimbursements.trip_count+1,
      free_trip_count=public.driver_promotion_reimbursements.free_trip_count+excluded.free_trip_count,
      cash_discount_cents=public.driver_promotion_reimbursements.cash_discount_cents+excluded.cash_discount_cents,
      card_discount_cents=public.driver_promotion_reimbursements.card_discount_cents+excluded.card_discount_cents,
      reimbursement_cents=public.driver_promotion_reimbursements.reimbursement_cents+excluded.reimbursement_cents,
      updated_at=now();
  end if;
  return new;
end $$;
revoke all on function private.record_promotion_reimbursement_v1() from public,anon,authenticated;
create trigger record_promotion_reimbursement
  after insert or update of status on public.trips
  for each row execute function private.record_promotion_reimbursement_v1();

create function private.review_driver_promotion_reimbursement_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();item public.driver_promotion_reimbursements;reference_value text;note_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede confirmar reembolsos.' using errcode='42501';
  end if;
  select * into item from public.driver_promotion_reimbursements
  where id=(payload->>'reimbursement_id')::uuid for update;
  if not found then raise exception 'Reembolso semanal no encontrado.';end if;
  if item.status='paid' then raise exception 'Este reembolso ya fue transferido.';end if;
  if item.due_at>now() then raise exception 'La semana todavía está abierta; espera al cierre para transferir el total acumulado.';end if;
  reference_value:=trim(coalesce(payload->>'reference',''));
  note_value:=trim(coalesce(payload->>'note',''));
  if length(reference_value)<3 then raise exception 'Registra la referencia de la transferencia.';end if;
  if length(note_value)<5 then raise exception 'Registra una nota de conciliación.';end if;
  update public.driver_promotion_reimbursements set status='paid',transfer_reference=left(reference_value,160),
    paid_at=now(),paid_by=uid,note=left(note_value,1000),updated_at=now()
  where id=item.id returning * into item;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'driver_promotion_reimbursement_paid',item.id,jsonb_build_object(
    'driver_id',item.driver_id,'week_start',item.week_start,
    'reimbursement_cents',item.reimbursement_cents,'reference',item.transfer_reference,'note',left(note_value,500)
  ));
  return to_jsonb(item);
end $$;
revoke all on function private.review_driver_promotion_reimbursement_v1(jsonb) from public,anon;
grant execute on function private.review_driver_promotion_reimbursement_v1(jsonb) to authenticated;

create function private.dashboard_v16(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  if p.role='admin' then
    update public.driver_promotion_reimbursements set status='overdue',updated_at=now()
    where status='pending' and due_at<now();
  elsif p.role='driver' then
    update public.driver_promotion_reimbursements set status='overdue',updated_at=now()
    where driver_id=uid and status='pending' and due_at<now();
  end if;
  base:=private.dashboard_v15(payload);
  return base||jsonb_build_object(
    'promotion_reimbursements',(select coalesce(jsonb_agg(to_jsonb(x) order by x.week_start desc),'[]'::jsonb) from (
      select r.*,pr.full_name as driver_name,
        (select coalesce(jsonb_agg(jsonb_build_object(
          'trip_id',t.id,'completed_at',t.completed_at,'payment_method',t.payment_method,
          'fare_cents',t.fare_cents,'discount_cents',t.reward_discount_cents,
          'free_trip',(t.fare_cents>0 and t.reward_discount_cents>=t.fare_cents),
          'category',t.category,'origin',t.origin,'destination',t.destination
        ) order by t.completed_at),'[]'::jsonb)
        from public.trips t
        where t.driver_id=r.driver_id and t.status='completed' and t.reward_discount_cents>0
          and timezone('America/Chihuahua',coalesce(t.completed_at,t.created_at))::date>=r.week_start
          and timezone('America/Chihuahua',coalesce(t.completed_at,t.created_at))::date<r.week_start+7) as trips
      from public.driver_promotion_reimbursements r
      join public.profiles pr on pr.id=r.driver_id
      where r.driver_id=uid or p.role='admin'
      order by r.week_start desc limit 500
    )x)
  );
end $$;
revoke all on function private.dashboard_v16(jsonb) from public,anon;
grant execute on function private.dashboard_v16(jsonb) to authenticated;

create function private.operations_report_v5(payload jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb;start_value timestamptz;end_value timestamptz;driver_value uuid:=nullif(payload->>'driver_id','')::uuid;
  promo_cost bigint:=0;promo_paid bigint:=0;promo_pending bigint:=0;free_trips bigint:=0;
  accrued bigint:=0;collected bigint:=0;commercial jsonb;
begin
  base:=private.operations_report_v4(payload);
  start_value:=(base#>>'{meta,from}')::timestamptz;
  end_value:=(base#>>'{meta,to}')::timestamptz;
  select coalesce(sum(t.reward_discount_cents),0),
    count(*) filter(where t.fare_cents>0 and t.reward_discount_cents>=t.fare_cents)
  into promo_cost,free_trips
  from public.trips t
  where t.status='completed' and t.reward_discount_cents>0
    and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value
    and (driver_value is null or t.driver_id=driver_value);
  select
    coalesce(sum(r.reimbursement_cents) filter(where r.status='paid' and r.paid_at>=start_value and r.paid_at<end_value),0),
    coalesce(sum(r.reimbursement_cents) filter(where r.status in ('pending','overdue') and r.week_start>=start_value::date and r.week_start<end_value::date),0)
  into promo_paid,promo_pending
  from public.driver_promotion_reimbursements r
  where driver_value is null or r.driver_id=driver_value;
  commercial:=coalesce(base->'commercial_summary','{}'::jsonb);
  accrued:=coalesce((commercial->>'platform_revenue_accrued_cents')::bigint,0);
  collected:=coalesce((commercial->>'platform_revenue_collected_cents')::bigint,0);
  commercial:=commercial||jsonb_build_object(
    'promotion_discounts_cents',promo_cost,
    'promotion_free_trips',free_trips,
    'promotion_reimbursements_paid_cents',promo_paid,
    'promotion_reimbursements_pending_cents',promo_pending,
    'platform_contribution_after_promotions_cents',accrued-promo_cost,
    'platform_cash_after_promotion_reimbursements_cents',collected-promo_paid
  );
  return jsonb_set(base,'{commercial_summary}',commercial,true);
end $$;
revoke all on function private.operations_report_v5(jsonb) from public,anon;
grant execute on function private.operations_report_v5(jsonb) to authenticated;

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='referrals') then
    alter publication supabase_realtime add table public.referrals;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='driver_promotion_reimbursements') then
    alter publication supabase_realtime add table public.driver_promotion_reimbursements;
  end if;
end $$;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload)
   when 'dashboard' then private.dashboard_v16(payload)
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
