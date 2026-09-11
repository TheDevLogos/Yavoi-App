-- Passenger legal consent plus centrally managed rewards and advertising.
alter table public.profiles
  add column privacy_policy_accepted_at timestamptz,
  add column privacy_policy_version text,
  add column terms_accepted_at timestamptz,
  add column terms_version text;

alter table private.app_settings
  add column rewards_enabled boolean not null default true,
  add column advertising_enabled boolean not null default true;

create table public.advertising_campaigns(
  id uuid primary key default gen_random_uuid(),
  title text not null check(char_length(title) between 3 and 100),
  advertiser_name text not null check(char_length(advertiser_name) between 2 and 100),
  description text not null check(char_length(description) between 5 and 700),
  discount_label text not null default '' check(char_length(discount_label)<=100),
  audience text not null default 'all' check(audience in ('all','passenger','driver')),
  image_path text,
  cta_label text not null default '' check(char_length(cta_label)<=50),
  cta_url text not null default '' check(char_length(cta_url)<=500),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  active boolean not null default true,
  priority integer not null default 100 check(priority between 0 and 1000),
  created_by uuid not null references public.profiles(id),
  updated_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at>starts_at),
  check(cta_url='' or cta_url ~ '^https://')
);
create index advertising_campaigns_active_window
  on public.advertising_campaigns(active,starts_at,ends_at,audience,priority);
create index advertising_campaigns_created_by on public.advertising_campaigns(created_by);
create index advertising_campaigns_updated_by on public.advertising_campaigns(updated_by);

alter table public.advertising_campaigns enable row level security;
revoke all on public.advertising_campaigns from anon,authenticated;
grant select on public.advertising_campaigns to authenticated;
create policy advertising_campaigns_read on public.advertising_campaigns for select to authenticated
using(
  (select private.is_admin()) or (
    active and starts_at<=now() and ends_at>now() and
    (audience='all' or audience=(select role from public.profiles where id=(select auth.uid())))
  )
);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('yavoi-marketing','yavoi-marketing',true,4194304,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy marketing_images_admin_insert on storage.objects for insert to authenticated with check(
  bucket_id='yavoi-marketing' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select private.is_admin())
);
create policy marketing_images_read on storage.objects for select to authenticated using(bucket_id='yavoi-marketing');

create or replace function private.passenger_profile_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p
    where p.id=target and p.role='passenger'
      and length(trim(p.full_name))>=2 and length(trim(p.phone))>=10
      and length(trim(p.emergency_name))>=2 and length(trim(p.emergency_phone))>=10
      and p.avatar_path is not null
      and p.passenger_policy_accepted_at is not null and p.passenger_policy_version='2026-09-10'
      and p.privacy_policy_accepted_at is not null and p.privacy_policy_version='2026-09-11'
      and p.terms_accepted_at is not null and p.terms_version='2026-09-11'
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars'
        and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.passenger_profile_complete(uuid) from public,anon,authenticated;

-- Existing passengers can accept the new agreements without an Operations edit window.
update public.profiles set profile_locked_at=null,profile_edit_allowed_until=null,
  profile_edit_authorized_by=null,profile_edit_authorization_note='Actualización de privacidad y términos pendiente'
where role='passenger' and not private.passenger_profile_complete(id);

create function private.profile_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;accept_safety boolean;accept_privacy boolean;accept_terms boolean;
  had_safety boolean;had_privacy boolean;had_terms boolean;
begin
  select * into p from public.profiles where id=uid for update;
  if uid is null or not found or p.suspended then raise exception 'Tu cuenta no está habilitada.' using errcode='42501';end if;
  if p.role in ('passenger','driver') and not private.profile_edit_open(uid) then
    raise exception 'Tu perfil está protegido. Operaciones debe autorizar temporalmente cualquier modificación.' using errcode='42501';
  end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>20000 then raise exception 'Solicitud inválida.';end if;
  if length(trim(coalesce(payload->>'name','')))<2 or length(trim(coalesce(payload->>'phone','')))<10 then raise exception 'Completa nombre y teléfono.';end if;
  if char_length(coalesce(payload->>'emergency_name',''))>100 or char_length(coalesce(payload->>'emergency_phone',''))>25 then raise exception 'Revisa el contacto de emergencia.';end if;
  if payload->>'avatar_path' is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-avatars'
    and name=payload->>'avatar_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'La fotografía no pertenece a tu cuenta.';end if;
  accept_safety:=coalesce((payload->>'accept_passenger_policy')::boolean,false);
  accept_privacy:=coalesce((payload->>'accept_privacy_policy')::boolean,false);
  accept_terms:=coalesce((payload->>'accept_terms')::boolean,false);
  had_safety:=p.passenger_policy_accepted_at is not null and p.passenger_policy_version='2026-09-10';
  had_privacy:=p.privacy_policy_accepted_at is not null and p.privacy_policy_version='2026-09-11';
  had_terms:=p.terms_accepted_at is not null and p.terms_version='2026-09-11';
  if p.role='passenger' then
    if not accept_safety or coalesce(payload->>'passenger_policy_version','')<>'2026-09-10' then raise exception 'Lee y acepta las Políticas de Seguridad vigentes.';end if;
    if not accept_privacy or coalesce(payload->>'privacy_policy_version','')<>'2026-09-11' then raise exception 'Lee y acepta la Política de Privacidad vigente.';end if;
    if not accept_terms or coalesce(payload->>'terms_version','')<>'2026-09-11' then raise exception 'Lee y acepta los Términos de Servicio vigentes.';end if;
  end if;
  update public.profiles set
    full_name=left(trim(payload->>'name'),100),phone=left(trim(payload->>'phone'),25),
    emergency_name=left(trim(coalesce(payload->>'emergency_name','')),100),
    emergency_phone=left(trim(coalesce(payload->>'emergency_phone','')),25),
    avatar_path=coalesce(nullif(payload->>'avatar_path',''),avatar_path),
    passenger_policy_accepted_at=case when role='passenger' and accept_safety then coalesce(passenger_policy_accepted_at,now()) else passenger_policy_accepted_at end,
    passenger_policy_version=case when role='passenger' and accept_safety then '2026-09-10' else passenger_policy_version end,
    privacy_policy_accepted_at=case when role='passenger' and accept_privacy then coalesce(privacy_policy_accepted_at,now()) else privacy_policy_accepted_at end,
    privacy_policy_version=case when role='passenger' and accept_privacy then '2026-09-11' else privacy_policy_version end,
    terms_accepted_at=case when role='passenger' and accept_terms then coalesce(terms_accepted_at,now()) else terms_accepted_at end,
    terms_version=case when role='passenger' and accept_terms then '2026-09-11' else terms_version end,
    updated_at=now() where id=uid returning * into p;
  if p.role='passenger' and accept_safety and not had_safety then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'passenger_policy_accepted',uid,jsonb_build_object('version','2026-09-10'));end if;
  if p.role='passenger' and accept_privacy and not had_privacy then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'privacy_policy_accepted',uid,jsonb_build_object('version','2026-09-11'));end if;
  if p.role='passenger' and accept_terms and not had_terms then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'terms_accepted',uid,jsonb_build_object('version','2026-09-11'));end if;
  if (p.role='passenger' and private.passenger_profile_complete(uid)) or (p.role='driver' and private.driver_dossier_complete(uid)) then
    update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid;
  end if;
  return jsonb_build_object('ok',true,'complete',case when p.role='passenger' then private.passenger_profile_complete(uid) else true end,
    'profile_locked',(select profile_locked_at is not null from public.profiles where id=uid));
end $$;
revoke all on function private.profile_v4(jsonb) from public,anon;
grant execute on function private.profile_v4(jsonb) to authenticated;

create function private.set_marketing_settings_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();rewards_value boolean;ads_value boolean;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede administrar promociones.' using errcode='42501';end if;
  rewards_value:=coalesce((payload->>'rewards_enabled')::boolean,true);ads_value:=coalesce((payload->>'advertising_enabled')::boolean,true);
  update private.app_settings set rewards_enabled=rewards_value,advertising_enabled=ads_value,updated_at=now() where id;
  insert into public.audit_log(actor_id,action,detail) values(uid,'marketing_settings_changed',jsonb_build_object('rewards_enabled',rewards_value,'advertising_enabled',ads_value));
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.set_marketing_settings_v1(jsonb) from public,anon;
grant execute on function private.set_marketing_settings_v1(jsonb) to authenticated;

create function private.set_reward_active_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();reward_id text;active_value boolean;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede administrar recompensas.' using errcode='42501';end if;
  reward_id:=payload->>'reward_id';active_value:=coalesce((payload->>'active')::boolean,false);
  update public.reward_catalog set active=active_value,updated_at=now() where id=reward_id;
  if not found then raise exception 'Recompensa no encontrada.';end if;
  insert into public.audit_log(actor_id,action,detail) values(uid,'reward_availability_changed',jsonb_build_object('reward_id',reward_id,'active',active_value));
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.set_reward_active_v1(jsonb) from public,anon;
grant execute on function private.set_reward_active_v1(jsonb) to authenticated;

create function private.upsert_campaign_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;result public.advertising_campaigns;start_value timestamptz;end_value timestamptz;
  title_value text;advertiser_value text;description_value text;audience_value text;image_value text;cta_url_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede administrar publicidad.' using errcode='42501';end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>12000 then raise exception 'Solicitud inválida.';end if;
  target:=nullif(payload->>'id','')::uuid;title_value:=trim(coalesce(payload->>'title',''));
  advertiser_value:=trim(coalesce(payload->>'advertiser_name',''));description_value:=trim(coalesce(payload->>'description',''));
  audience_value:=coalesce(payload->>'audience','all');image_value:=nullif(payload->>'image_path','');
  cta_url_value:=trim(coalesce(payload->>'cta_url',''));start_value:=(payload->>'starts_at')::timestamptz;end_value:=(payload->>'ends_at')::timestamptz;
  if length(title_value)<3 or length(advertiser_value)<2 or length(description_value)<5 then raise exception 'Completa negocio, título y descripción.';end if;
  if audience_value not in ('all','passenger','driver') or end_value<=start_value then raise exception 'Revisa audiencia y vigencia.';end if;
  if cta_url_value<>'' and cta_url_value!~'^https://' then raise exception 'El enlace debe comenzar con https://';end if;
  if image_value is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-marketing' and name=image_value) then raise exception 'La fotografía promocional no existe.';end if;
  if target is null then
    insert into public.advertising_campaigns(title,advertiser_name,description,discount_label,audience,image_path,cta_label,cta_url,starts_at,ends_at,active,priority,created_by,updated_by)
    values(left(title_value,100),left(advertiser_value,100),left(description_value,700),left(coalesce(payload->>'discount_label',''),100),audience_value,image_value,left(coalesce(payload->>'cta_label',''),50),left(cta_url_value,500),start_value,end_value,coalesce((payload->>'active')::boolean,true),coalesce((payload->>'priority')::integer,100),uid,uid) returning * into result;
  else
    update public.advertising_campaigns set title=left(title_value,100),advertiser_name=left(advertiser_value,100),description=left(description_value,700),
      discount_label=left(coalesce(payload->>'discount_label',''),100),audience=audience_value,image_path=coalesce(image_value,image_path),
      cta_label=left(coalesce(payload->>'cta_label',''),50),cta_url=left(cta_url_value,500),starts_at=start_value,ends_at=end_value,
      active=coalesce((payload->>'active')::boolean,active),priority=coalesce((payload->>'priority')::integer,priority),updated_by=uid,updated_at=now()
    where id=target returning * into result;
    if not found then raise exception 'Campaña no encontrada.';end if;
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'advertising_campaign_saved',result.id,jsonb_build_object('title',result.title,'advertiser_name',result.advertiser_name,'active',result.active,'ends_at',result.ends_at));
  return to_jsonb(result);
end $$;
revoke all on function private.upsert_campaign_v1(jsonb) from public,anon;
grant execute on function private.upsert_campaign_v1(jsonb) to authenticated;

create function private.set_campaign_active_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid:=(payload->>'campaign_id')::uuid;active_value boolean:=coalesce((payload->>'active')::boolean,false);
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede administrar publicidad.' using errcode='42501';end if;
  update public.advertising_campaigns set active=active_value,updated_by=uid,updated_at=now() where id=target;
  if not found then raise exception 'Campaña no encontrada.';end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'advertising_campaign_status_changed',target,jsonb_build_object('active',active_value));
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.set_campaign_active_v1(jsonb) from public,anon;
grant execute on function private.set_campaign_active_v1(jsonb) to authenticated;

create function private.redeem_reward_v2(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not (select rewards_enabled from private.app_settings where id) then raise exception 'El Sistema de Recompensas está temporalmente pausado.';end if;
  return private.redeem_reward_v1(payload);
end $$;
revoke all on function private.redeem_reward_v2(jsonb) from public,anon;
grant execute on function private.redeem_reward_v2(jsonb) to authenticated;

create function private.request_trip_v7(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if nullif(trim(coalesce(payload->>'reward_code','')),'') is not null and not (select rewards_enabled from private.app_settings where id) then raise exception 'Las recompensas están pausadas; confirma el viaje sin aplicar un canje.';end if;
  return private.request_trip_v6(payload);
end $$;
revoke all on function private.request_trip_v7(jsonb) from public,anon;
grant execute on function private.request_trip_v7(jsonb) to authenticated;

create function private.transition_v5(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;
begin
  if (select rewards_enabled from private.app_settings where id) then return private.transition_v4(payload);end if;
  result:=private.transition_v3(payload);
  if result ? 'error' then return result;end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if t.status='completed' then
    delete from public.reward_entries where trip_id=t.id and entry_type='trip_complete';
  end if;
  if t.status='cancelled' and t.reward_redemption_id is not null then update public.reward_redemptions set status='available',trip_id=null,applied_at=null,updated_at=now() where id=t.reward_redemption_id and status='applied';end if;
  return to_jsonb(t)||jsonb_build_object('refund_payment_id',result->'refund_payment_id');
end $$;
revoke all on function private.transition_v5(jsonb) from public,anon;
grant execute on function private.transition_v5(jsonb) to authenticated;

create function private.rating_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if (select rewards_enabled from private.app_settings where id) then return private.rating_v2(payload);end if;
  return private.dispatch('rating',payload)||jsonb_build_object('points_awarded',0,'driver_bonus',0);
end $$;
revoke all on function private.rating_v3(jsonb) from public,anon;
grant execute on function private.rating_v3(jsonb) to authenticated;

create function private.dashboard_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;rewards_value boolean;ads_value boolean;campaigns jsonb;catalog jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  base:=private.dashboard_v7(payload);
  select rewards_enabled,advertising_enabled into rewards_value,ads_value from private.app_settings where id;
  if p.role='admin' then
    select coalesce(jsonb_agg(to_jsonb(c) order by c.priority,c.created_at desc),'[]') into campaigns from public.advertising_campaigns c;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.audience,r.sort_order,r.points_cost),'[]') into catalog from public.reward_catalog r;
  else
    select coalesce(jsonb_agg(to_jsonb(c) order by c.priority,c.created_at desc),'[]') into campaigns from public.advertising_campaigns c
      where ads_value and c.active and c.starts_at<=now() and c.ends_at>now() and c.audience in ('all',p.role);
    catalog:='[]'::jsonb;
    if not rewards_value then base:=jsonb_set(base,'{reward_wallet,catalog}','[]'::jsonb,true);end if;
  end if;
  return base||jsonb_build_object('marketing',jsonb_build_object('rewards_enabled',rewards_value,'advertising_enabled',ads_value,'campaigns',campaigns,'reward_catalog',catalog));
end $$;
revoke all on function private.dashboard_v8(jsonb) from public,anon;
grant execute on function private.dashboard_v8(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v8(payload)
   when 'profile' then private.profile_v4(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v7(payload)
   when 'trip' then private.trip_v5(payload)
   when 'driver_profile' then private.driver_profile_v5(payload)
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
   when 'transition' then private.transition_v5(payload)
   when 'rating' then private.rating_v3(payload)
   when 'redeem_reward' then private.redeem_reward_v2(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
   when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload)
   when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v1(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

alter publication supabase_realtime add table public.advertising_campaigns;
