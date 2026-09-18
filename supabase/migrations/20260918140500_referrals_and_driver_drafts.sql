-- Verified passenger referrals and resilient driver dossier drafts.

alter table public.reward_catalog
  add column program_type text not null default 'standard'
    check(program_type in ('standard','referral')),
  add column min_referrals_registered integer not null default 0
    check(min_referrals_registered>=0),
  add column min_referrals_first_trip integer not null default 0
    check(min_referrals_first_trip>=0);

create table public.referral_codes(
  code text primary key check(code ~ '^YV[A-F0-9]{8}$'),
  owner_id uuid not null unique references public.profiles(id) on delete cascade,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.referrals(
  id uuid primary key default gen_random_uuid(),
  code text not null references public.referral_codes(code),
  inviter_id uuid not null references public.profiles(id) on delete cascade,
  invitee_id uuid not null unique references public.profiles(id) on delete cascade,
  registered_at timestamptz not null default now(),
  first_trip_at timestamptz,
  first_trip_id uuid unique references public.trips(id),
  created_at timestamptz not null default now(),
  check(inviter_id<>invitee_id)
);
create index referrals_inviter_created on public.referrals(inviter_id,created_at desc);
create index referrals_code on public.referrals(code);
create index referrals_first_trip_pending on public.referrals(invitee_id) where first_trip_at is null;

create table public.driver_profile_drafts(
  driver_id uuid primary key references public.drivers(id) on delete cascade,
  draft jsonb not null default '{}' check(jsonb_typeof(draft)='object' and octet_length(draft::text)<=24000),
  updated_at timestamptz not null default now()
);

alter table public.referral_codes enable row level security;
alter table public.referrals enable row level security;
alter table public.driver_profile_drafts enable row level security;
revoke all on public.referral_codes,public.referrals,public.driver_profile_drafts from anon,authenticated;
grant select on public.referral_codes,public.referrals,public.driver_profile_drafts to authenticated;
create policy referral_codes_own_or_admin on public.referral_codes for select to authenticated
  using(owner_id=(select auth.uid()) or (select private.is_admin()));
create policy referrals_own_or_admin on public.referrals for select to authenticated
  using(inviter_id=(select auth.uid()) or invitee_id=(select auth.uid()) or (select private.is_admin()));
create policy driver_profile_drafts_own_or_admin on public.driver_profile_drafts for select to authenticated
  using(driver_id=(select auth.uid()) or (select private.is_admin()));

create function private.ensure_referral_code_v1(target uuid) returns text
language plpgsql volatile security definer set search_path='' as $$
declare result text;attempt integer:=0;
begin
  select code into result from public.referral_codes where owner_id=target;
  if found then return result;end if;
  if not exists(select 1 from public.profiles where id=target and role='passenger' and onboarding_complete) then return null;end if;
  loop
    attempt:=attempt+1;
    result:='YV'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    begin
      insert into public.referral_codes(code,owner_id) values(result,target);
      return result;
    exception when unique_violation then
      if attempt>=10 then raise exception 'No fue posible generar el código de referencia.';end if;
    end;
  end loop;
end $$;
revoke all on function private.ensure_referral_code_v1(uuid) from public,anon,authenticated;

create function private.onboard_referral_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result jsonb;code_value text:=upper(trim(coalesce(payload->>'referral_code','')));owner uuid;
begin
  result:=private.dispatch('onboard',payload-'referral_code');
  if payload->>'role'='passenger' then
    perform private.ensure_referral_code_v1(uid);
    if code_value<>'' then
      select owner_id into owner from public.referral_codes where code=code_value and active for update;
      if not found then raise exception 'El código de invitación no existe o ya no está activo.';end if;
      if owner=uid then raise exception 'No puedes usar tu propio código de invitación.';end if;
      insert into public.referrals(code,inviter_id,invitee_id) values(code_value,owner,uid)
      on conflict(invitee_id) do nothing;
      if found then
        insert into public.reward_entries(user_id,points,entry_type,description,source_key,detail)
        values(owner,30,'referral_registered','Invitación efectiva · nuevo pasajero','referral:registered:'||uid::text,
          jsonb_build_object('invitee_id',uid,'referral_code',code_value));
        insert into public.audit_log(actor_id,action,target_id,detail)
        values(uid,'referral_registered',owner,jsonb_build_object('code',code_value));
      end if;
    end if;
  end if;
  return result;
end $$;
revoke all on function private.onboard_referral_v1(jsonb) from public,anon;
grant execute on function private.onboard_referral_v1(jsonb) to authenticated;

create function private.save_driver_profile_draft_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;clean jsonb:=coalesce(payload->'draft','{}');
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.role<>'driver' or p.suspended then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
  if jsonb_typeof(clean)<>'object' or octet_length(clean::text)>24000 then raise exception 'El borrador del expediente no es válido.';end if;
  insert into public.driver_profile_drafts(driver_id,draft,updated_at) values(uid,clean,now())
  on conflict(driver_id) do update set draft=excluded.draft,updated_at=now();
  return jsonb_build_object('ok',true,'saved_at',now());
end $$;
revoke all on function private.save_driver_profile_draft_v1(jsonb) from public,anon;
grant execute on function private.save_driver_profile_draft_v1(jsonb) to authenticated;

create function private.driver_profile_v9(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result:=private.driver_profile_v8(payload);
  delete from public.driver_profile_drafts where driver_id=auth.uid();
  return result;
end $$;
revoke all on function private.driver_profile_v9(jsonb) from public,anon;
grant execute on function private.driver_profile_v9(jsonb) to authenticated;

create function private.upsert_reward_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;result public.reward_catalog;program_value text:=coalesce(payload->>'program_type','standard');registered_value integer;trip_value integer;
begin
  if program_value not in ('standard','referral') then raise exception 'Programa de recompensa inválido.';end if;
  registered_value:=coalesce(nullif(payload->>'min_referrals_registered','')::integer,0);
  trip_value:=coalesce(nullif(payload->>'min_referrals_first_trip','')::integer,0);
  if registered_value<0 or trip_value<0 then raise exception 'Las metas de referidos no pueden ser negativas.';end if;
  if program_value='standard' then registered_value:=0;trip_value:=0;end if;
  base:=private.upsert_reward_v2(payload);
  update public.reward_catalog set program_type=program_value,min_referrals_registered=registered_value,
    min_referrals_first_trip=trip_value,updated_at=now()
  where id=base->>'id' returning * into result;
  return to_jsonb(result);
end $$;
revoke all on function private.upsert_reward_v3(jsonb) from public,anon;
grant execute on function private.upsert_reward_v3(jsonb) to authenticated;

insert into public.reward_catalog(
  id,audience,name,description,kind,icon,points_cost,value_percent,max_discount_cents,eligible_category,
  min_trips,min_income_cents,partner_name,fulfillment_note,automatic,active,sort_order,terms,delivery_mode,
  expires_days,claim_method,claim_instructions,claim_button_label,program_type,min_referrals_registered,min_referrals_first_trip
) values
('passenger_referral_discount_10','passenger','10% por tu primera invitación','Desbloquea 10% para un viaje cuando una persona invitada complete su primer viaje.','fare_discount_percent','users-round',100,10,5000,null,0,0,'Yavoi!','Se aplica antes de confirmar el cobro.',false,true,6,'Máximo $50 MXN. Una recompensa por viaje.','trip',180,'trip','Elige este beneficio al confirmar un próximo viaje.','Aplicar al viaje','referral',1,1),
('passenger_referral_discount_20','passenger','20% por dos viajeros nuevos','Desbloquea 20% para un viaje cuando dos invitados completen su primer viaje.','fare_discount_percent','user-round-plus',200,20,8000,null,0,0,'Yavoi!','Se aplica antes de confirmar el cobro.',false,true,7,'Máximo $80 MXN. Una recompensa por viaje.','trip',180,'trip','Elige este beneficio al confirmar un próximo viaje.','Aplicar al viaje','referral',2,2),
('passenger_referral_free_local','passenger','Viaje Básico gratis por tres invitados','Desbloquea un viaje local Básico cuando tres personas invitadas completen su primer viaje.','free_local_trip','car-front',300,null,null,'basic',0,0,'Yavoi!','Se aplica antes de confirmar el cobro.',false,true,8,'Válido en un viaje local Básico, sin incluir propina.','trip',365,'trip','Elige este beneficio al confirmar un viaje local Básico.','Aplicar al viaje','referral',3,3)
on conflict(id) do update set name=excluded.name,description=excluded.description,kind=excluded.kind,icon=excluded.icon,
  points_cost=excluded.points_cost,value_percent=excluded.value_percent,max_discount_cents=excluded.max_discount_cents,
  eligible_category=excluded.eligible_category,partner_name=excluded.partner_name,fulfillment_note=excluded.fulfillment_note,
  active=excluded.active,sort_order=excluded.sort_order,terms=excluded.terms,delivery_mode=excluded.delivery_mode,
  expires_days=excluded.expires_days,claim_method=excluded.claim_method,claim_instructions=excluded.claim_instructions,
  claim_button_label=excluded.claim_button_label,program_type=excluded.program_type,
  min_referrals_registered=excluded.min_referrals_registered,min_referrals_first_trip=excluded.min_referrals_first_trip,updated_at=now();

create function private.redeem_reward_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();reward public.reward_catalog;registered_count integer;trip_count integer;
begin
  select * into reward from public.reward_catalog where id=payload->>'reward_id';
  if reward.program_type='referral' then
    select count(*),count(*) filter(where first_trip_at is not null) into registered_count,trip_count
    from public.referrals where inviter_id=uid;
    if registered_count<reward.min_referrals_registered or trip_count<reward.min_referrals_first_trip then
      raise exception 'Esta recompensa requiere más invitaciones efectivas o primeros viajes completados.';
    end if;
  end if;
  return private.redeem_reward_v4(payload);
end $$;
revoke all on function private.redeem_reward_v5(jsonb) from public,anon;
grant execute on function private.redeem_reward_v5(jsonb) to authenticated;

create function private.transition_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;ref public.referrals;
begin
  result:=private.transition_v7(payload);
  if payload->>'status'='completed' then
    select * into t from public.trips where id=(payload->>'trip_id')::uuid;
    if t.status='completed' then
      update public.referrals set first_trip_at=coalesce(t.completed_at,now()),first_trip_id=t.id
      where invitee_id=t.passenger_id and first_trip_at is null returning * into ref;
      if found then
        insert into public.reward_entries(user_id,trip_id,points,entry_type,description,source_key,detail)
        values(ref.inviter_id,t.id,70,'referral_first_trip','Invitación efectiva · primer viaje completado',
          'referral:first_trip:'||ref.invitee_id::text,jsonb_build_object('invitee_id',ref.invitee_id,'referral_id',ref.id));
        insert into public.reward_entries(user_id,trip_id,points,entry_type,description,source_key,detail)
        values(ref.invitee_id,t.id,25,'referral_welcome','Bienvenida por completar tu primer viaje con invitación',
          'referral:welcome:'||ref.invitee_id::text,jsonb_build_object('inviter_id',ref.inviter_id,'referral_id',ref.id));
        insert into public.audit_log(actor_id,action,target_id,detail)
        values(auth.uid(),'referral_first_trip_completed',ref.id,jsonb_build_object('inviter_id',ref.inviter_id,'invitee_id',ref.invitee_id,'trip_id',t.id));
      end if;
    end if;
  end if;
  return result;
end $$;
revoke all on function private.transition_v8(jsonb) from public,anon;
grant execute on function private.transition_v8(jsonb) to authenticated;

create function private.dashboard_v14(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;wallet jsonb;operations jsonb;code_value text;
begin
  select * into p from public.profiles where id=uid;
  base:=private.dashboard_v13(payload);
  if p.role='passenger' then
    code_value:=private.ensure_referral_code_v1(uid);
    wallet:=coalesce(base->'reward_wallet','{}'::jsonb);
    wallet:=wallet||jsonb_build_object(
      'referral_code',code_value,
      'referral_registered_count',(select count(*) from public.referrals where inviter_id=uid),
      'referral_first_trip_count',(select count(*) from public.referrals where inviter_id=uid and first_trip_at is not null),
      'referral_pending_count',(select count(*) from public.referrals where inviter_id=uid and first_trip_at is null),
      'referral_points',(select coalesce(sum(points),0) from public.reward_entries where user_id=uid and entry_type in ('referral_registered','referral_first_trip')),
      'referrals',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'invitee_name',split_part(pr.full_name,' ',1),'registered_at',r.registered_at,'first_trip_at',r.first_trip_at) order by r.registered_at desc),'[]') from public.referrals r join public.profiles pr on pr.id=r.invitee_id where r.inviter_id=uid)
    );
    base:=jsonb_set(base,'{reward_wallet}',wallet,true);
  elsif p.role='admin' then
    operations:=coalesce(base->'reward_operations','{}'::jsonb);
    operations:=operations||jsonb_build_object(
      'referral_summary',jsonb_build_object(
        'registered',(select count(*) from public.referrals),
        'first_trips',(select count(*) from public.referrals where first_trip_at is not null),
        'points_awarded',(select coalesce(sum(points),0) from public.reward_entries where entry_type in ('referral_registered','referral_first_trip','referral_welcome'))
      ),
      'referrals',(select coalesce(jsonb_agg(to_jsonb(x) order by x.registered_at desc),'[]') from (
        select r.id,r.code,r.registered_at,r.first_trip_at,r.first_trip_id,pi.full_name inviter_name,pn.full_name invitee_name
        from public.referrals r join public.profiles pi on pi.id=r.inviter_id join public.profiles pn on pn.id=r.invitee_id
        order by r.registered_at desc limit 300
      )x)
    );
    base:=jsonb_set(base,'{reward_operations}',operations,true);
  elsif p.role='driver' then
    base:=jsonb_set(base,'{driver_profile_draft}',coalesce((select to_jsonb(d) from public.driver_profile_drafts d where d.driver_id=uid),'null'::jsonb),true);
  end if;
  return base;
end $$;
revoke all on function private.dashboard_v14(jsonb) from public,anon;
grant execute on function private.dashboard_v14(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload)
   when 'dashboard' then private.dashboard_v14(payload)
   when 'onboard' then private.onboard_referral_v1(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload)
   when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v9(payload)
   when 'trip' then private.trip_v10(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v9(payload)
   when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v3(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v6(payload)
   when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v7(payload)
   when 'accept' then private.accept_offer_v3(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
   when 'transition' then private.transition_v8(payload)
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
   when 'operations_report' then private.operations_report_v4(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload)
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
   when 'upsert_service_shift' then private.upsert_service_shift_v1(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
