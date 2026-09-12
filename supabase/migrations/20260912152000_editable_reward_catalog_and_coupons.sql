-- Editable reward catalog and shareable, immutable coupon grants.
alter table public.reward_catalog
  add column image_path text,
  add column terms text not null default '' check(char_length(terms)<=1000),
  add column delivery_mode text not null default 'operations' check(delivery_mode in ('digital_coupon','trip','operations')),
  add column expires_days integer not null default 180 check(expires_days between 1 and 730);

update public.reward_catalog set delivery_mode=case
  when kind in ('fare_discount_fixed','fare_discount_percent','free_local_trip','ride_amenity') then 'trip'
  when kind='partner_coupon' then 'digital_coupon'
  else 'operations' end;

alter table public.reward_redemptions
  add column reward_snapshot jsonb not null default '{}';
update public.reward_redemptions r set reward_snapshot=to_jsonb(c)
from public.reward_catalog c where c.id=r.reward_id and r.reward_snapshot='{}'::jsonb;
alter table public.reward_redemptions drop constraint reward_redemptions_code_check;
alter table public.reward_redemptions add constraint reward_redemptions_code_check
  check(code ~ '^YV-[A-F0-9]{8,12}$');

create function private.upsert_reward_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target text;existing public.reward_catalog;result public.reward_catalog;
  audience_value text;name_value text;description_value text;kind_value text;delivery_value text;
  image_value text;automatic_value boolean;milestone_value integer;points_value integer;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede administrar recompensas.' using errcode='42501';
  end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>24000 then raise exception 'Solicitud inválida.';end if;
  target:=nullif(trim(coalesce(payload->>'id','')),'');
  if target is null then target:='reward_'||substr(replace(gen_random_uuid()::text,'-',''),1,12);end if;
  if target !~ '^[a-z0-9_]{3,60}$' then raise exception 'Identificador de recompensa inválido.';end if;
  select * into existing from public.reward_catalog where id=target;
  audience_value:=coalesce(payload->>'audience','');name_value:=trim(coalesce(payload->>'name',''));
  description_value:=trim(coalesce(payload->>'description',''));kind_value:=coalesce(payload->>'kind','');
  delivery_value:=coalesce(payload->>'delivery_mode','operations');image_value:=nullif(payload->>'image_path','');
  automatic_value:=coalesce((payload->>'automatic')::boolean,false);
  milestone_value:=nullif(payload->>'milestone_every','')::integer;
  points_value:=coalesce((payload->>'points_cost')::integer,0);
  if audience_value not in ('passenger','driver') then raise exception 'Selecciona Pasajeros o Conductores.';end if;
  if length(name_value)<3 or length(description_value)<5 then raise exception 'Completa nombre y descripción.';end if;
  if kind_value not in ('fare_discount_fixed','fare_discount_percent','free_local_trip','ride_amenity','partner_coupon','driver_benefit') then raise exception 'Tipo de recompensa inválido.';end if;
  if delivery_value not in ('digital_coupon','trip','operations') then raise exception 'Forma de entrega inválida.';end if;
  if points_value<0 then raise exception 'El costo en puntos no puede ser negativo.';end if;
  if automatic_value and coalesce(milestone_value,0)<1 then raise exception 'Indica cada cuántos viajes se genera.';end if;
  if kind_value='fare_discount_fixed' and nullif(payload->>'value_cents','') is null then raise exception 'Indica el descuento fijo.';end if;
  if kind_value='fare_discount_percent' and (nullif(payload->>'value_percent','') is null or nullif(payload->>'max_discount_cents','') is null) then raise exception 'Indica porcentaje y descuento máximo.';end if;
  if image_value is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-marketing' and name=image_value) then raise exception 'La imagen de la recompensa no existe.';end if;
  insert into public.reward_catalog(id,audience,name,description,kind,icon,points_cost,value_cents,value_percent,max_discount_cents,
    eligible_category,min_trips,min_rating,min_income_cents,max_recent_incidents,partner_name,fulfillment_note,automatic,
    milestone_every,total_stock,active,sort_order,image_path,terms,delivery_mode,expires_days,updated_at)
  values(target,audience_value,left(name_value,100),left(description_value,500),kind_value,left(coalesce(nullif(payload->>'icon',''),'gift'),40),points_value,
    nullif(payload->>'value_cents','')::integer,nullif(payload->>'value_percent','')::numeric,nullif(payload->>'max_discount_cents','')::integer,
    nullif(payload->>'eligible_category',''),coalesce(nullif(payload->>'min_trips','')::integer,0),nullif(payload->>'min_rating','')::numeric,
    coalesce(nullif(payload->>'min_income_cents','')::integer,0),nullif(payload->>'max_recent_incidents','')::integer,
    left(trim(coalesce(payload->>'partner_name','')),100),left(trim(coalesce(payload->>'fulfillment_note','')),500),automatic_value,
    milestone_value,nullif(payload->>'total_stock','')::integer,coalesce((payload->>'active')::boolean,true),
    coalesce(nullif(payload->>'sort_order','')::integer,100),image_value,left(trim(coalesce(payload->>'terms','')),1000),delivery_value,
    coalesce(nullif(payload->>'expires_days','')::integer,180),now())
  on conflict(id) do update set audience=excluded.audience,name=excluded.name,description=excluded.description,kind=excluded.kind,
    icon=excluded.icon,points_cost=excluded.points_cost,value_cents=excluded.value_cents,value_percent=excluded.value_percent,
    max_discount_cents=excluded.max_discount_cents,eligible_category=excluded.eligible_category,min_trips=excluded.min_trips,
    min_rating=excluded.min_rating,min_income_cents=excluded.min_income_cents,max_recent_incidents=excluded.max_recent_incidents,
    partner_name=excluded.partner_name,fulfillment_note=excluded.fulfillment_note,automatic=excluded.automatic,
    milestone_every=excluded.milestone_every,total_stock=excluded.total_stock,active=excluded.active,sort_order=excluded.sort_order,
    image_path=excluded.image_path,terms=excluded.terms,delivery_mode=excluded.delivery_mode,expires_days=excluded.expires_days,updated_at=now()
  returning * into result;
  insert into public.audit_log(actor_id,action,detail) values(uid,case when existing.id is null then 'reward_catalog_created' else 'reward_catalog_updated' end,
    jsonb_build_object('reward_id',result.id,'name',result.name,'audience',result.audience,'active',result.active,'delivery_mode',result.delivery_mode));
  return to_jsonb(result);
end $$;
revoke all on function private.upsert_reward_v1(jsonb) from public,anon;
grant execute on function private.upsert_reward_v1(jsonb) to authenticated;

create function private.redeem_reward_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;reward public.reward_catalog;redemption public.reward_redemptions;new_status text;
begin
  result:=private.redeem_reward_v2(payload);
  select * into reward from public.reward_catalog where id=payload->>'reward_id';
  new_status:=case when reward.delivery_mode in ('digital_coupon','trip') then 'available' else 'requested' end;
  update public.reward_redemptions set code='YV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),
    status=new_status,reward_snapshot=to_jsonb(reward),expires_at=now()+make_interval(days=>reward.expires_days),updated_at=now()
  where id=(result->>'id')::uuid returning * into redemption;
  return to_jsonb(redemption)||jsonb_build_object('reward',to_jsonb(reward),'balance',result->'balance');
end $$;
revoke all on function private.redeem_reward_v3(jsonb) from public,anon;
grant execute on function private.redeem_reward_v3(jsonb) to authenticated;

create function private.dashboard_v9(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;wallet jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  base:=private.dashboard_v8(payload);
  if p.role in ('passenger','driver') then
    wallet:=coalesce(base->'reward_wallet','{}'::jsonb);
    wallet:=jsonb_set(wallet,'{catalog}',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order,c.points_cost),'[]') from public.reward_catalog c where c.audience=p.role),true);
    wallet:=jsonb_set(wallet,'{redemptions}',(select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at desc),'[]') from (
      select r.*,c.name,c.description,c.kind,c.icon,c.partner_name,c.fulfillment_note,c.value_cents,c.value_percent,
        c.max_discount_cents,c.eligible_category,c.image_path,c.terms,c.delivery_mode,c.expires_days
      from public.reward_redemptions r join public.reward_catalog c on c.id=r.reward_id where r.user_id=uid
      order by r.requested_at desc limit 50)x),true);
    base:=jsonb_set(base,'{reward_wallet}',wallet,true);
  end if;
  return base;
end $$;
revoke all on function private.dashboard_v9(jsonb) from public,anon;
grant execute on function private.dashboard_v9(jsonb) to authenticated;

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
