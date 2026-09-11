-- Transparent cancellation protection, trip-level support and atomic rating reports.
alter table private.app_settings
  add column cancellation_grace_seconds integer not null default 120 check(cancellation_grace_seconds between 0 and 900),
  add column cancellation_fee_cents integer not null default 2500 check(cancellation_fee_cents between 0 and 10000),
  add column arrived_cancellation_fee_cents integer not null default 3500 check(arrived_cancellation_fee_cents between 0 and 15000);

alter table public.trips
  add column cancelled_by uuid references public.profiles(id),
  add column cancelled_by_role text check(cancelled_by_role in ('passenger','driver','admin')),
  add column cancelled_at timestamptz,
  add column cancellation_reason_code text,
  add column cancellation_fee_cents integer not null default 0 check(cancellation_fee_cents between 0 and 15000),
  add column cancellation_refund_cents integer not null default 0 check(cancellation_refund_cents>=0),
  add column cancellation_commission_cents integer not null default 0 check(cancellation_commission_cents>=0),
  add column cancellation_policy_version text;
create index trips_cancelled_by on public.trips(cancelled_by) where cancelled_by is not null;

alter table public.trips drop constraint trips_payment_status_check;
alter table public.trips add constraint trips_payment_status_check
  check(payment_status in ('pending','paid','refund_pending','refunded','failed','cancelled'));

alter table public.payments
  add column refund_amount_cents integer not null default 0 check(refund_amount_cents>=0 and refund_amount_cents<=amount_cents),
  add column retained_amount_cents integer not null default 0 check(retained_amount_cents>=0 and retained_amount_cents<=amount_cents);
alter table public.payments drop constraint payments_kind_check;
alter table public.payments add constraint payments_kind_check
  check(kind in ('ride','tip','weekly_fee','cancellation_fee'));
alter table public.payments drop constraint payments_check;
alter table public.payments add constraint payments_check
  check((kind='weekly_fee' and driver_id is not null) or kind<>'weekly_fee');
alter table public.payments drop constraint payments_check1;
alter table public.payments add constraint payments_check1
  check((kind in ('ride','tip','cancellation_fee') and trip_id is not null) or kind='weekly_fee');
create unique index payments_trip_cancellation_fee on public.payments(trip_id,kind) where kind='cancellation_fee';

alter table public.ledger drop constraint ledger_kind_check;
alter table public.ledger add constraint ledger_kind_check
  check(kind in ('fare','commission','cash_tip','card_tip','cancellation_fee'));

create or replace function private.passenger_profile_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p
    where p.id=target and p.role='passenger'
      and length(trim(p.full_name))>=2 and length(trim(p.phone))>=10
      and length(trim(p.emergency_name))>=2 and length(trim(p.emergency_phone))>=10
      and p.avatar_path is not null
      and p.passenger_policy_accepted_at is not null and p.passenger_policy_version='2026-09-11-cancelaciones'
      and p.privacy_policy_accepted_at is not null and p.privacy_policy_version='2026-09-11'
      and p.terms_accepted_at is not null and p.terms_version='2026-09-11'
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars'
        and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.passenger_profile_complete(uuid) from public,anon,authenticated;

-- Existing passengers must review the new cancellation commitments once.
update public.profiles set profile_locked_at=null,profile_edit_allowed_until=null,
  profile_edit_authorized_by=null,profile_edit_authorization_note='Política de cancelación pendiente de aceptación'
where role='passenger' and not private.passenger_profile_complete(id);

create function private.profile_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;result jsonb;already_current boolean;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found then raise exception 'Tu cuenta no está habilitada.' using errcode='42501';end if;
  if p.role<>'passenger' then return private.profile_v4(payload);end if;
  if coalesce((payload->>'accept_passenger_policy')::boolean,false)<>true
    or coalesce(payload->>'passenger_policy_version','')<>'2026-09-11-cancelaciones' then
    raise exception 'Lee y acepta las Políticas de Seguridad y Cancelación vigentes.';
  end if;
  already_current:=p.passenger_policy_accepted_at is not null and p.passenger_policy_version='2026-09-11-cancelaciones';
  result:=private.profile_v4(jsonb_set(payload,'{passenger_policy_version}','"2026-09-10"'::jsonb,true));
  update public.profiles set passenger_policy_accepted_at=case when already_current then passenger_policy_accepted_at else now() end,
    passenger_policy_version='2026-09-11-cancelaciones',updated_at=now() where id=uid returning * into p;
  if not already_current then
    insert into public.audit_log(actor_id,action,target_id,detail)
    values(uid,'passenger_policy_accepted',uid,jsonb_build_object('version','2026-09-11-cancelaciones','includes_cancellation_terms',true));
  end if;
  if private.passenger_profile_complete(uid) then update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid;end if;
  return result||jsonb_build_object('complete',private.passenger_profile_complete(uid),'profile_locked',(select profile_locked_at is not null from public.profiles where id=uid));
end $$;
revoke all on function private.profile_v5(jsonb) from public,anon;
grant execute on function private.profile_v5(jsonb) to authenticated;
revoke execute on function private.profile_v4(jsonb) from authenticated;

create function private.cancellation_terms_v1(target_trip uuid,target_actor uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t public.trips;p public.profiles;settings private.app_settings;accepted_at timestamptz;
  fee_value integer:=0;refund_value integer:=0;grace_until timestamptz;explanation text;
begin
  select * into p from public.profiles where id=target_actor;
  select * into t from public.trips where id=target_trip;
  select * into settings from private.app_settings where id;
  if p.id is null or t.id is null or p.suspended or (t.passenger_id is distinct from target_actor and t.driver_id is distinct from target_actor and p.role<>'admin') then
    raise exception 'No tienes acceso a este viaje.' using errcode='42501';
  end if;
  if t.status in ('completed','cancelled') then raise exception 'El viaje ya finalizó.';end if;
  if t.status='in_progress' and p.role<>'admin' then raise exception 'Durante el recorrido usa Reportar viaje o Emergencias 911.';end if;
  if p.role='passenger' and t.driver_id is not null then
    select max(created_at) into accepted_at from public.trip_events where trip_id=t.id and event='accepted';
    grace_until:=accepted_at+make_interval(secs=>settings.cancellation_grace_seconds);
    if t.status='arrived' then
      fee_value:=settings.arrived_cancellation_fee_cents;
      explanation:='La unidad ya llegó al punto de partida. La cuota protege el tiempo y traslado del conductor.';
    elsif t.status='accepted' and (grace_until is null or now()>grace_until) then
      fee_value:=settings.cancellation_fee_cents;
      explanation:='Terminó la gracia de 2 minutos después de la asignación. La cuota compensa parte del traslado del conductor.';
    else
      explanation:='Esta cancelación está dentro del periodo gratuito y no genera cargo.';
    end if;
  elsif p.role='passenger' then
    explanation:='Aún no hay un conductor asignado; puedes cancelar sin cargo.';
  elsif p.role='driver' then
    explanation:='La cancelación del conductor no genera cuota al pasajero y queda registrada para seguimiento de confiabilidad.';
  else
    explanation:='Operaciones puede cancelar por seguridad o soporte sin generar una cuota automática al pasajero.';
  end if;
  fee_value:=least(greatest(fee_value,0),greatest(coalesce(t.total_cents,t.fare_cents,0),0));
  if t.payment_method='card' and t.payment_status='paid' then refund_value:=greatest(coalesce(t.total_cents,t.fare_cents,0)-fee_value,0);end if;
  return jsonb_build_object(
    'trip_id',t.id,'fee_cents',fee_value,'refund_cents',refund_value,'payment_method',t.payment_method,
    'grace_until',grace_until,'grace_remaining_seconds',greatest(0,extract(epoch from grace_until-now())::integer),
    'explanation',explanation,'policy_version','2026-09-11-cancelaciones','actor_role',p.role
  );
end $$;
revoke all on function private.cancellation_terms_v1(uuid,uuid) from public,anon,authenticated;

create function private.cancellation_quote_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  return private.cancellation_terms_v1((payload->>'trip_id')::uuid,uid);
end $$;
revoke all on function private.cancellation_quote_v1(jsonb) from public,anon;
grant execute on function private.cancellation_quote_v1(jsonb) to authenticated;

create function private.transition_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;t public.trips;terms jsonb;fee_value integer;refund_value integer;
  commission_value integer:=0;pay public.payments;reason_value text;reason_code_value text;
begin
  if payload->>'status'<>'cancelled' then return private.transition_v5(payload);end if;
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Tu cuenta no está habilitada.' using errcode='42501';end if;
  if p.role='admin' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
  if not found or (t.passenger_id is distinct from uid and t.driver_id is distinct from uid and p.role<>'admin') then raise exception 'No tienes acceso a este viaje.' using errcode='42501';end if;
  if t.status in ('completed','cancelled') then raise exception 'El viaje ya finalizó.';end if;
  if t.status='in_progress' and p.role<>'admin' then raise exception 'Durante el recorrido usa Reportar viaje o Emergencias 911.';end if;
  reason_value:=trim(coalesce(payload->>'reason',''));reason_code_value:=coalesce(payload->>'reason_code','other');
  if length(reason_value)<5 then raise exception 'Escribe el motivo de cancelación.';end if;
  if reason_code_value not in ('changed_plans','wrong_location','driver_delay','safety','vehicle_issue','passenger_absent','operations','other') then raise exception 'Motivo de cancelación inválido.';end if;
  terms:=private.cancellation_terms_v1(t.id,uid);fee_value:=(terms->>'fee_cents')::integer;refund_value:=(terms->>'refund_cents')::integer;
  if fee_value>0 and t.driver_id is not null then commission_value:=round(fee_value*t.commission_bps_applied/10000.0)::integer;end if;
  update public.trips set status='cancelled',cancel_reason=left(reason_value,500),cancelled_by=uid,cancelled_by_role=p.role,
    cancelled_at=now(),cancellation_reason_code=reason_code_value,cancellation_fee_cents=fee_value,
    cancellation_refund_cents=refund_value,cancellation_commission_cents=commission_value,
    cancellation_policy_version='2026-09-11-cancelaciones',
    payment_status=case
      when payment_method='card' and payment_status='paid' and refund_value>0 then 'refund_pending'
      when payment_method='card' and payment_status='paid' then 'paid'
      when payment_method='card' then 'cancelled'
      when fee_value>0 then 'pending' else 'cancelled' end,
    updated_at=now() where id=t.id returning * into t;

  if t.payment_method='card' then
    if refund_value>0 then
      update public.payments set status='refund_pending',refund_amount_cents=refund_value,retained_amount_cents=fee_value,
        status_detail='trip_cancelled_partial_refund',updated_at=now()
      where trip_id=t.id and kind='ride' and status='approved' returning * into pay;
    else
      update public.payments set status=case when status='approved' then 'approved' else 'cancelled' end,
        retained_amount_cents=case when status='approved' then fee_value else 0 end,status_detail='trip_cancelled',updated_at=now()
      where trip_id=t.id and kind='ride';
    end if;
    if fee_value>0 and t.driver_id is not null then
      insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,'cancellation_fee',fee_value) on conflict do nothing;
      if commission_value>0 then insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,'commission',-commission_value) on conflict do nothing;end if;
    end if;
  else
    update public.payments set status='cancelled',status_detail='trip_cancelled',updated_at=now() where trip_id=t.id and kind='ride';
    if fee_value>0 and t.driver_id is not null then
      insert into public.payments(trip_id,payer_id,driver_id,kind,provider,amount_cents,status,status_detail)
      values(t.id,t.passenger_id,t.driver_id,'cancellation_fee','cash',fee_value,'pending','awaiting_cash_confirmation')
      on conflict(trip_id,kind) where kind='cancellation_fee' do nothing;
    end if;
  end if;
  if t.reward_redemption_id is not null then
    update public.reward_redemptions set status='available',trip_id=null,applied_at=null,updated_at=now()
    where id=t.reward_redemption_id and status='applied';
  end if;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,'cancelled',jsonb_build_object(
    'reason',t.cancel_reason,'reason_code',reason_code_value,'cancelled_by_role',p.role,
    'cancellation_fee_cents',fee_value,'cancellation_refund_cents',refund_value,'policy_version','2026-09-11-cancelaciones'));
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'trip_cancelled',t.id,jsonb_build_object(
    'reason',t.cancel_reason,'cancelled_by_role',p.role,'cancellation_fee_cents',fee_value,
    'cancellation_refund_cents',refund_value,'policy_version','2026-09-11-cancelaciones'));
  return to_jsonb(t)||jsonb_build_object('refund_payment_id',pay.id);
end $$;
revoke all on function private.transition_v6(jsonb) from public,anon;
grant execute on function private.transition_v6(jsonb) to authenticated;

create function private.refund_checkout_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;pay public.payments;refund_value integer;
begin
  select * into p from public.profiles where id=uid;
  select * into pay from public.payments where id=(payload->>'payment_id')::uuid for update;
  if uid is null or not found or p.suspended or not found or (pay.payer_id<>uid and p.role<>'admin')
    or pay.status<>'refund_pending' or pay.provider_payment_id is null then raise exception 'Reembolso no disponible.' using errcode='42501';end if;
  if p.role='admin' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';end if;
  refund_value:=case when pay.refund_amount_cents>0 then pay.refund_amount_cents else pay.amount_cents end;
  return jsonb_build_object('payment_id',pay.id,'provider_payment_id',pay.provider_payment_id,
    'refund_idempotency_key',pay.refund_idempotency_key,'amount_cents',refund_value,'original_amount_cents',pay.amount_cents);
end $$;
revoke all on function private.refund_checkout_v2(jsonb) from public,anon;
grant execute on function private.refund_checkout_v2(jsonb) to authenticated;

create function private.settle_cancellation_fee_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;t public.trips;pay public.payments;status_value text;note_value text;
  commission_value integer:=0;start_day date;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Cuenta no disponible.' using errcode='42501';end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
  select * into pay from public.payments where trip_id=t.id and kind='cancellation_fee' for update;
  status_value:=payload->>'status';note_value:=trim(coalesce(payload->>'note',''));
  if not found or pay.status<>'pending' or t.status<>'cancelled' then raise exception 'Cuota de cancelación no disponible.';end if;
  if p.role='driver' and (t.driver_id<>uid or status_value<>'paid') then raise exception 'Sólo puedes confirmar una cuota que recibiste.' using errcode='42501';end if;
  if p.role='admin' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';end if;
  if p.role not in ('driver','admin') or status_value not in ('paid','waived') or length(note_value)<5 then raise exception 'Revisa el estado y la nota de conciliación.';end if;
  if status_value='paid' then
    commission_value:=round(pay.amount_cents*t.commission_bps_applied/10000.0)::integer;
    update public.payments set status='approved',status_detail='cash_cancellation_fee_received',provider_approved_at=now(),updated_at=now() where id=pay.id;
    update public.trips set payment_status='paid',cancellation_commission_cents=commission_value,updated_at=now() where id=t.id;
    insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,'cancellation_fee',pay.amount_cents) on conflict do nothing;
    if commission_value>0 then insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,'commission',-commission_value) on conflict do nothing;end if;
    if t.billing_mode='commission' and commission_value>0 then
      start_day:=date_trunc('week',timezone('America/Chihuahua',now()))::date;
      insert into public.driver_commission_settlements(driver_id,week_start,due_at,gross_cash_cents,commission_due_cents)
      values(t.driver_id,start_day,(start_day+7)::timestamp at time zone 'America/Chihuahua',pay.amount_cents,commission_value)
      on conflict(driver_id,week_start) do update set gross_cash_cents=public.driver_commission_settlements.gross_cash_cents+excluded.gross_cash_cents,
        commission_due_cents=public.driver_commission_settlements.commission_due_cents+excluded.commission_due_cents,updated_at=now();
    end if;
  else
    update public.payments set status='cancelled',status_detail='waived_by_operations',updated_at=now() where id=pay.id;
    update public.trips set payment_status='cancelled',cancellation_fee_cents=0,cancellation_commission_cents=0,updated_at=now() where id=t.id;
  end if;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,case when status_value='paid' then 'cancellation_fee_paid' else 'cancellation_fee_waived' end,
    jsonb_build_object('amount_cents',case when status_value='paid' then pay.amount_cents else 0 end,'note',left(note_value,500)));
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'cancellation_fee_settled',t.id,
    jsonb_build_object('status',status_value,'cancellation_fee_cents',case when status_value='paid' then pay.amount_cents else 0 end,'note',left(note_value,500)));
  return jsonb_build_object('ok',true,'status',status_value);
end $$;
revoke all on function private.settle_cancellation_fee_v1(jsonb) from public,anon;
grant execute on function private.settle_cancellation_fee_v1(jsonb) to authenticated;

create function private.rating_and_report_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;report_result jsonb;
begin
  if coalesce((payload->>'report_issue')::boolean,false) then
    if length(trim(coalesce(payload->>'report_subject','')))<3 or length(trim(coalesce(payload->>'report_body','')))<10 then raise exception 'Completa el motivo y la descripción del reporte.';end if;
  end if;
  result:=private.rating_v3(payload);
  if coalesce((payload->>'report_issue')::boolean,false) then
    report_result:=private.dispatch('complaint',jsonb_build_object('trip_id',payload->>'trip_id','subject',payload->>'report_subject','body',payload->>'report_body'));
  end if;
  return result||jsonb_build_object('report',report_result);
end $$;
revoke all on function private.rating_and_report_v1(jsonb) from public,anon;
grant execute on function private.rating_and_report_v1(jsonb) to authenticated;

create function private.trip_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid:=(payload->>'trip_id')::uuid;base jsonb;p public.profiles;
begin
  base:=private.trip_v5(payload);
  select * into p from public.profiles where id=uid;
  return base||jsonb_build_object('reports',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
    select id,subject,body,status,response,created_at,updated_at from public.complaints
    where trip_id=target and (owner_id=uid or p.role='admin') order by created_at desc
  )x));
end $$;
revoke all on function private.trip_v6(jsonb) from public,anon;
grant execute on function private.trip_v6(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v8(payload)
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
