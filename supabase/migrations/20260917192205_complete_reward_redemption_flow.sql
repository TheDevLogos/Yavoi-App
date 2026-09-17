-- Complete, single-use reward redemption flow for trip benefits, partner
-- tickets and benefits coordinated by Operations.

alter table public.reward_catalog
  add column claim_method text not null default 'show_ticket'
    check(claim_method in ('trip','show_ticket','partner_counter','contact_operations','operations_delivery')),
  add column claim_instructions text not null default '' check(char_length(claim_instructions)<=1200),
  add column claim_contact text not null default '' check(char_length(claim_contact)<=200),
  add column claim_contact_url text not null default '' check(char_length(claim_contact_url)<=500),
  add column claim_location text not null default '' check(char_length(claim_location)<=300),
  add column claim_button_label text not null default '' check(char_length(claim_button_label)<=60);

update public.reward_catalog set
  claim_method=case
    when delivery_mode='trip' then 'trip'
    when delivery_mode='operations' then 'contact_operations'
    else 'show_ticket'
  end,
  claim_instructions=case
    when delivery_mode='trip' then 'Elige esta recompensa en la confirmación de un próximo viaje. Sólo puede aplicarse una recompensa por viaje.'
    when delivery_mode='operations' then coalesce(nullif(fulfillment_note,''),'Envía tu solicitud a Operaciones y espera la confirmación dentro de Yavoi!.')
    else coalesce(nullif(fulfillment_note,''),'Presenta el ticket y su código de barras antes de recibir el beneficio.')
  end,
  claim_button_label=case when delivery_mode='operations' then 'Solicitar a Operaciones' else 'Mostrar ticket' end;

update public.reward_catalog set
  claim_method='partner_counter',
  claim_instructions='Presenta el ticket Yavoi! y su código de barras en la taquilla participante antes de elegir la función. El personal validará el folio una sola vez.',
  claim_location='Taquilla del cine participante indicada por Operaciones',
  claim_button_label='Presentar en taquilla'
where id='passenger_movie_ticket';

update public.reward_catalog set
  claim_method='partner_counter',
  claim_instructions='Presenta este ticket al negocio participante antes de pagar. El comercio y Operaciones validarán el folio una sola vez.',
  claim_button_label='Presentar al negocio'
where id='passenger_partner_coupon';

insert into public.reward_catalog(
  id,audience,name,description,kind,icon,points_cost,min_trips,min_rating,min_income_cents,
  max_recent_incidents,partner_name,fulfillment_note,automatic,total_stock,active,sort_order,
  terms,delivery_mode,expires_days,claim_method,claim_instructions,claim_contact,
  claim_contact_url,claim_location,claim_button_label
) values (
  'driver_mobile_data_1gb','driver','Paquete de datos móviles de 1 GB',
  'Apoyo de conectividad para navegación, mensajes y operación diaria en Yavoi!.',
  'driver_benefit','smartphone',320,20,4.50,500000,1,'Yavoi! Operaciones',
  'Envía a Operaciones el número móvil y la compañía. No publiques esos datos en el ticket.',
  false,null,true,35,
  'Un paquete por canje. Sujeto a cobertura, compañía compatible y validación de Operaciones.',
  'operations',45,'contact_operations',
  'Presiona Solicitar a Operaciones, indica tu número móvil y compañía, y conserva el folio. Operaciones registrará la entrega cuando la recarga sea confirmada.',
  'Operaciones Yavoi!','mailto:admin.yavoi@gmail.com','Atención remota','Solicitar a Operaciones'
) on conflict(id) do update set
  name=excluded.name,description=excluded.description,icon=excluded.icon,points_cost=excluded.points_cost,
  min_trips=excluded.min_trips,min_rating=excluded.min_rating,min_income_cents=excluded.min_income_cents,
  max_recent_incidents=excluded.max_recent_incidents,partner_name=excluded.partner_name,
  fulfillment_note=excluded.fulfillment_note,active=excluded.active,sort_order=excluded.sort_order,
  terms=excluded.terms,delivery_mode=excluded.delivery_mode,expires_days=excluded.expires_days,
  claim_method=excluded.claim_method,claim_instructions=excluded.claim_instructions,
  claim_contact=excluded.claim_contact,claim_contact_url=excluded.claim_contact_url,
  claim_location=excluded.claim_location,claim_button_label=excluded.claim_button_label,updated_at=now();

alter table public.reward_redemptions drop constraint if exists reward_redemptions_status_check;
alter table public.reward_redemptions add constraint reward_redemptions_status_check
  check(status in ('available','requested','applied','fulfilled','redeemed','cancelled','expired'));
alter table public.reward_redemptions
  add column ready_at timestamptz,
  add column redeemed_at timestamptz,
  add column redeemed_by uuid references public.profiles(id),
  add column redemption_reference text not null default '' check(char_length(redemption_reference)<=120);

create unique index reward_redemptions_one_active_manual_reward
  on public.reward_redemptions(user_id,reward_id)
  where source_key is null and status in ('available','requested','applied','fulfilled');
create index reward_redemptions_operations_queue
  on public.reward_redemptions(status,requested_at desc)
  where status in ('available','requested','fulfilled');

create function private.upsert_reward_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;result public.reward_catalog;method_value text;instructions_value text;
  contact_value text;contact_url_value text;location_value text;button_value text;delivery_value text;
begin
  method_value:=coalesce(nullif(payload->>'claim_method',''),case when payload->>'delivery_mode'='trip' then 'trip' else 'show_ticket' end);
  delivery_value:=coalesce(payload->>'delivery_mode','operations');
  instructions_value:=trim(coalesce(payload->>'claim_instructions',''));
  contact_value:=trim(coalesce(payload->>'claim_contact',''));
  contact_url_value:=trim(coalesce(payload->>'claim_contact_url',''));
  location_value:=trim(coalesce(payload->>'claim_location',''));
  button_value:=trim(coalesce(payload->>'claim_button_label',''));
  if method_value not in ('trip','show_ticket','partner_counter','contact_operations','operations_delivery') then raise exception 'Método de canje inválido.';end if;
  if delivery_value='trip' and method_value<>'trip' then raise exception 'Una recompensa para viaje debe canjearse durante la confirmación.';end if;
  if delivery_value<>'trip' and method_value='trip' then raise exception 'Selecciona una forma de entrega compatible con este canje.';end if;
  if delivery_value<>'trip' and length(instructions_value)<10 then raise exception 'Explica claramente cómo debe canjearse la recompensa.';end if;
  if contact_url_value<>'' and contact_url_value!~*'^(https://|mailto:|tel:)' then raise exception 'El enlace de contacto debe usar https, mailto o tel.';end if;
  base:=private.upsert_reward_v1(payload);
  update public.reward_catalog set
    claim_method=method_value,
    claim_instructions=left(instructions_value,1200),
    claim_contact=left(contact_value,200),
    claim_contact_url=left(contact_url_value,500),
    claim_location=left(location_value,300),
    claim_button_label=left(button_value,60),
    updated_at=now()
  where id=base->>'id' returning * into result;
  return to_jsonb(result);
end $$;
revoke all on function private.upsert_reward_v2(jsonb) from public,anon;
grant execute on function private.upsert_reward_v2(jsonb) to authenticated;

create function private.redeem_reward_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target text:=payload->>'reward_id';result jsonb;
begin
  if uid is null then raise exception 'Inicia sesión para canjear.' using errcode='42501';end if;
  if exists(
    select 1 from public.reward_redemptions
    where user_id=uid and reward_id=target and source_key is null
      and status in ('available','requested','applied','fulfilled')
  ) then raise exception 'Ya tienes esta recompensa activa. Úsala o espera su resolución antes de solicitarla otra vez.';end if;
  begin
    result:=private.redeem_reward_v3(payload);
  exception when unique_violation then
    raise exception 'Ya tienes esta recompensa activa. Actualiza la pantalla para consultarla.';
  end;
  return result;
end $$;
revoke all on function private.redeem_reward_v4(jsonb) from public,anon;
grant execute on function private.redeem_reward_v4(jsonb) to authenticated;

create function private.review_reward_redemption_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();redemption public.reward_redemptions;reward public.reward_catalog;
  decision text:=payload->>'status';note_value text:=trim(coalesce(payload->>'note',''));
  reference_value text:=trim(coalesce(payload->>'reference',''));
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede gestionar recompensas.' using errcode='42501';
  end if;
  if decision not in ('fulfilled','redeemed','cancelled') or length(note_value)<5 then raise exception 'Indica un resultado y una nota de seguimiento.';end if;
  if decision in ('fulfilled','redeemed') and length(reference_value)<3 then raise exception 'Registra un folio, referencia o comprobación de entrega.';end if;
  select * into redemption from public.reward_redemptions where id=(payload->>'redemption_id')::uuid for update;
  if not found then raise exception 'Canje no encontrado.';end if;
  select * into reward from public.reward_catalog where id=redemption.reward_id;
  if decision='fulfilled' then
    if redemption.status<>'requested' or reward.delivery_mode='trip' then raise exception 'Este canje no está pendiente de preparación.';end if;
    update public.reward_redemptions set status='fulfilled',ready_at=now(),fulfilled_at=now(),fulfilled_by=uid,
      operations_note=left(note_value,500),redemption_reference=left(reference_value,120),updated_at=now()
    where id=redemption.id returning * into redemption;
  elsif decision='redeemed' then
    if redemption.status not in ('available','fulfilled') or reward.delivery_mode='trip' then raise exception 'Este ticket no está disponible para validar.';end if;
    if redemption.expires_at is not null and redemption.expires_at<=now() then raise exception 'El ticket ya venció.';end if;
    update public.reward_redemptions set status='redeemed',redeemed_at=now(),redeemed_by=uid,
      operations_note=left(note_value,500),redemption_reference=left(reference_value,120),updated_at=now()
    where id=redemption.id returning * into redemption;
  else
    if redemption.status not in ('available','requested','fulfilled') then raise exception 'El canje ya fue utilizado o no puede cancelarse.';end if;
    update public.reward_redemptions set status='cancelled',operations_note=left(note_value,500),
      fulfilled_by=uid,updated_at=now() where id=redemption.id returning * into redemption;
    if redemption.points_spent>0 then
      insert into public.reward_entries(user_id,trip_id,points,entry_type,description,redemption_id)
      values(redemption.user_id,null,redemption.points_spent,'redemption_refund','Devolución por canje cancelado',redemption.id)
      on conflict(redemption_id,entry_type) where redemption_id is not null do nothing;
    end if;
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'reward_redemption_'||decision,redemption.id,jsonb_build_object(
    'user_id',redemption.user_id,'reward_id',redemption.reward_id,'reference',left(reference_value,120),'note',left(note_value,500)
  ));
  return to_jsonb(redemption)||jsonb_build_object('reward',to_jsonb(reward));
end $$;
revoke all on function private.review_reward_redemption_v2(jsonb) from public,anon;
grant execute on function private.review_reward_redemption_v2(jsonb) to authenticated;

create function private.dashboard_v12(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;wallet jsonb;operations jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  update public.reward_redemptions set status='expired',updated_at=now()
  where expires_at<=now() and status in ('available','requested','fulfilled');
  base:=private.dashboard_v11(payload);
  if p.role in ('passenger','driver') then
    wallet:=coalesce(base->'reward_wallet','{}'::jsonb);
    wallet:=jsonb_set(wallet,'{catalog}',(
      select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order,c.points_cost),'[]')
      from public.reward_catalog c where c.audience=p.role
    ),true);
    wallet:=jsonb_set(wallet,'{redemptions}',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at desc),'[]') from (
        select r.*,c.name,c.description,c.kind,c.icon,c.partner_name,c.fulfillment_note,c.value_cents,c.value_percent,
          c.max_discount_cents,c.eligible_category,c.image_path,c.terms,c.delivery_mode,c.expires_days,c.claim_method,
          c.claim_instructions,c.claim_contact,c.claim_contact_url,c.claim_location,c.claim_button_label
        from public.reward_redemptions r join public.reward_catalog c on c.id=r.reward_id
        where r.user_id=uid order by r.requested_at desc limit 100
      )x
    ),true);
    base:=jsonb_set(base,'{reward_wallet}',wallet,true);
  elsif p.role='admin' then
    operations:=coalesce(base->'reward_operations','{}'::jsonb);
    operations:=jsonb_set(operations,'{redemptions}',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at desc),'[]') from (
        select r.*,pr.full_name as user_name,pr.phone,pr.role as audience,c.name,c.description,c.kind,c.icon,
          c.partner_name,c.image_path,c.terms,c.delivery_mode,c.claim_method,c.claim_instructions,c.claim_contact,
          c.claim_contact_url,c.claim_location,c.claim_button_label
        from public.reward_redemptions r join public.reward_catalog c on c.id=r.reward_id
        join public.profiles pr on pr.id=r.user_id
        order by r.requested_at desc limit 200
      )x
    ),true);
    base:=jsonb_set(base,'{reward_operations}',operations,true);
  end if;
  return base;
end $$;
revoke all on function private.dashboard_v12(jsonb) from public,anon;
grant execute on function private.dashboard_v12(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload)
   when 'dashboard' then private.dashboard_v12(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v9(payload)
   when 'trip' then private.trip_v10(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v8(payload)
   when 'review_driver' then private.review_driver_v3(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v5(payload)
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
   when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v4(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v2(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v2(payload)
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
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
