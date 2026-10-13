-- Weekly commission policy. Cash continues to be paid directly to the driver;
-- this records the commercial amount due to Yavoi! for Operations only.
create table if not exists private.commission_policy_settings (
  id boolean primary key default true check (id),
  effective_at timestamptz not null default now(),
  commission_bps integer not null default 1500 check (commission_bps between 0 and 5000),
  settlement_days integer not null default 2 check (settlement_days between 1 and 7),
  updated_at timestamptz not null default now()
);

insert into private.commission_policy_settings(id, effective_at, commission_bps, settlement_days)
values (true, now(), 1500, 2)
on conflict (id) do nothing;

create table if not exists public.driver_settlement_notices (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id) on delete cascade,
  settlement_id uuid not null references public.driver_commission_settlements(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 160),
  body text not null check (char_length(body) between 3 and 1000),
  due_at timestamptz not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (settlement_id)
);
alter table public.driver_settlement_notices enable row level security;
revoke all on public.driver_settlement_notices from anon, authenticated;
create index if not exists driver_settlement_notices_driver_created_idx on public.driver_settlement_notices(driver_id, created_at desc);

-- Existing records and legacy balances remain unchanged. Operations confirms
-- the 15% scheme per driver through set_driver_billing_v1; that change only
-- affects offers accepted after the confirmation.

create or replace function private.reconcile_weekly_commission_settlements(reference_at timestamptz default now())
returns integer language plpgsql security definer set search_path='' as $$
declare policy private.commission_policy_settings;
declare changed integer:=0;
begin
  select * into policy from private.commission_policy_settings where id for share;
  -- A settlement is created only after its Monday-Sunday service week closes.
  with eligible as (
    select t.driver_id,
      date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date as week_start,
      sum(coalesce(t.total_cents,t.fare_cents,0))::integer as gross_cash_cents,
      sum(coalesce(t.commission_cents,0))::integer as commission_due_cents
    from public.trips t
    where t.status='completed' and t.payment_method='cash'
      and t.billing_mode='commission' and t.driver_id is not null
      and t.completed_at >= policy.effective_at
      and date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date
          < date_trunc('week', timezone('America/Chihuahua', reference_at))::date
    group by t.driver_id, date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date
  ), upserted as (
    insert into public.driver_commission_settlements(driver_id,week_start,due_at,gross_cash_cents,commission_due_cents,status,note)
    select driver_id,week_start,
      (((week_start + 7 + policy.settlement_days)::timestamp + time '23:59:59') at time zone 'America/Chihuahua'),
      gross_cash_cents,commission_due_cents,'pending','Corte semanal de comisión Yavoi! 15%'
    from eligible
    on conflict (driver_id,week_start) do update set
      gross_cash_cents=excluded.gross_cash_cents,
      commission_due_cents=excluded.commission_due_cents,
      due_at=excluded.due_at,
      updated_at=now()
    where public.driver_commission_settlements.status in ('pending','submitted','overdue')
    returning id,driver_id,due_at,commission_due_cents,week_start
  )
  insert into public.driver_settlement_notices(driver_id,settlement_id,title,body,due_at)
  select u.driver_id,u.id,'Tu corte semanal está listo',
    format('Operaciones registró tu corte del %s. Comisión Yavoi! pendiente: $%s. Liquida a más tardar el %s para mantener tu autorización de conducción.',
      to_char(u.week_start,'DD/MM/YYYY'), to_char(u.commission_due_cents::numeric/100,'FM999999990.00'),
      to_char(timezone('America/Chihuahua',u.due_at),'DD/MM/YYYY HH24:MI')),
    u.due_at
  from upserted u
  on conflict (settlement_id) do update set body=excluded.body,due_at=excluded.due_at
  ;
  get diagnostics changed = row_count;

  update public.driver_commission_settlements
  set status='overdue', updated_at=now()
  where status in ('pending','submitted') and due_at < reference_at;

  update public.drivers d
  set account_active=false, online=false, updated_at=now(),
      account_access_note='Acceso suspendido por corte semanal vencido.'
  where d.account_active and exists (
    select 1 from public.driver_commission_settlements s
    where s.driver_id=d.id and s.status='overdue'
  );
  return changed;
end $$;
revoke all on function private.reconcile_weekly_commission_settlements(timestamptz) from public, anon;

create or replace function private.record_cash_commission_settlement()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='completed' and old.status is distinct from 'completed' and new.payment_method='cash'
     and new.billing_mode='commission' then
    perform private.reconcile_weekly_commission_settlements(now());
  end if;
  return new;
end $$;

create or replace function private.driver_commission_notices_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at desc),'[]'::jsonb)
  from public.driver_settlement_notices n
  where n.driver_id=auth.uid()
$$;
revoke all on function private.driver_commission_notices_v1() from public, anon;
grant execute on function private.driver_commission_notices_v1() to authenticated;

create or replace function private.bootstrap_v7(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  perform private.reconcile_weekly_commission_settlements(now());
  result:=private.bootstrap_v6(payload);
  if (result->'profile'->>'role')='driver' then
    result:=result||jsonb_build_object('commission_notices',private.driver_commission_notices_v1());
  end if;
  return result;
end $$;
revoke all on function private.bootstrap_v7(jsonb) from public, anon;
grant execute on function private.bootstrap_v7(jsonb) to authenticated;

create or replace function private.set_driver_billing_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); target uuid; note_value text; result public.drivers;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede confirmar el esquema comercial.' using errcode='42501';
  end if;
  target:=(payload->>'driver_id')::uuid;
  note_value:=left(trim(coalesce(payload->>'note','')),500);
  if char_length(note_value)<5 then raise exception 'Registra el motivo de la confirmación.'; end if;
  update public.drivers set billing_mode='commission',weekly_fee_cents=0,cash_commission_bps=1500,card_commission_bps=1500,updated_at=now()
  where id=target returning * into result;
  if not found then raise exception 'Conductor no encontrado.'; end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values
   (uid,'weekly_commission_policy_confirmed',target,jsonb_build_object('commission_bps',1500,'note',note_value));
  return jsonb_build_object('ok',true,'driver',to_jsonb(result));
end $$;

create or replace function private.review_weekly_commission_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); settlement public.driver_commission_settlements; received integer; note_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  select * into settlement from public.driver_commission_settlements where id=(payload->>'settlement_id')::uuid for update;
  if not found then raise exception 'Corte no encontrado.'; end if;
  received:=coalesce((payload->>'received_cents')::integer,-1);
  note_value:=left(trim(coalesce(payload->>'note','')),500);
  if settlement.status='paid' then raise exception 'Este corte ya fue conciliado.'; end if;
  if received<>settlement.commission_due_cents then raise exception 'El importe recibido debe coincidir exactamente con el saldo del corte.'; end if;
  if char_length(note_value)<5 then raise exception 'Registra la referencia o comprobación de Operaciones.'; end if;
  update public.driver_commission_settlements set status='paid',verified_by=uid,verified_at=now(),note=note_value,updated_at=now()
  where id=settlement.id returning * into settlement;
  insert into public.audit_log(actor_id,action,target_id,detail) values
   (uid,'weekly_commission_reconciled',settlement.driver_id,jsonb_build_object('settlement_id',settlement.id,'received_cents',received,'note',note_value));
  return jsonb_build_object('ok',true,'settlement',to_jsonb(settlement));
end $$;
revoke all on function private.review_weekly_commission_v1(jsonb) from public, anon;
grant execute on function private.review_weekly_commission_v1(jsonb) to authenticated;

create or replace function private.set_driver_access_v2(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); target uuid; active_value boolean; note_value text; d public.drivers;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501'; end if;
  target:=(payload->>'driver_id')::uuid; active_value:=coalesce((payload->>'active')::boolean,false); note_value:=left(trim(coalesce(payload->>'note','')),500);
  if char_length(note_value)<5 then raise exception 'Describe el motivo del cambio de acceso.'; end if;
  perform private.reconcile_weekly_commission_settlements(now());
  select * into d from public.drivers where id=target for update;
  if not found then raise exception 'Conductor no encontrado.'; end if;
  if active_value and (not d.approved or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then raise exception 'El conductor necesita expediente aprobado y documentos vigentes antes de reactivar su cuenta.'; end if;
  if active_value and exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='overdue') then raise exception 'Primero concilia los cortes semanales vencidos antes de reactivar esta cuenta.'; end if;
  update public.drivers set account_active=active_value,online=case when active_value then online else false end,
    account_access_authorized_at=case when active_value then now() else null end,
    account_access_authorized_by=case when active_value then uid else null end,
    account_access_note=note_value,updated_at=now() where id=target;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'set_driver_access',target,jsonb_build_object('active',active_value,'note',note_value));
  return jsonb_build_object('ok',true,'active',active_value);
end $$;
revoke all on function private.set_driver_access_v2(jsonb) from public, anon;
grant execute on function private.set_driver_access_v2(jsonb) to authenticated;

create or replace function private.availability_v8(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); going_online boolean:=coalesce((payload->>'online')::boolean,false); d public.drivers; p public.profiles; shift_value public.service_shifts; settings private.transport_compliance_settings; item record;
begin
  if uid is null then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  perform private.reconcile_weekly_commission_settlements(now());
  select * into p from public.profiles where id=uid;
  select * into d from public.drivers where id=uid for update;
  if not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  select * into settings from private.transport_compliance_settings where id;
  if going_online and settings.enforcement_mode='enforce' and (not private.company_transport_ready_v1() or not private.driver_dossier_complete(uid)) then raise exception 'Cumplimiento de transporte pendiente. Revisa el expediente y la póliza de la empresa con Operaciones.'; end if;
  if going_online and exists(select 1 from public.driver_commission_settlements s where s.driver_id=uid and s.status='overdue') then
    update public.drivers set account_active=false,online=false,updated_at=now() where id=uid;
    raise exception 'Tu corte semanal venció. Operaciones debe registrar la liquidación antes de que puedas conectarte.';
  end if;
  if going_online and (not d.approved or not d.account_active or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then raise exception 'Tu expediente debe estar aprobado; la autorización y los documentos deben estar vigentes.'; end if;
  if going_online then
    if d.service_shift_code is null then raise exception 'Operaciones debe asignarte un turno antes de conectarte.'; end if;
    select * into shift_value from public.service_shifts where code=d.service_shift_code and active;
    if not found or not private.shift_active_v1(d.service_shift_code,now()) then raise exception 'Tu turno asignado no está activo en este momento.'; end if;
  end if;
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de cambiar tu disponibilidad.'; end if;
  update public.drivers set online=going_online,shift_connected_at=case when going_online then now() else null end,updated_at=now() where id=uid;
  if not going_online then
    for item in update public.trip_offers set status='rejected',responded_at=now(),response_reason='Conductor desconectado' where driver_id=uid and status='offered' returning trip_id loop
      perform private.auto_assign_trip(item.trip_id,(select preferred_driver_id from public.trips where id=item.trip_id));
    end loop;
    delete from public.driver_presence where driver_id=uid;
  end if;
  return jsonb_build_object('ok',true,'account_active',d.account_active,'commission_bps',1500,'shift_code',d.service_shift_code,'shift_name',shift_value.name);
end $$;
revoke all on function private.availability_v8(jsonb) from public, anon;
grant execute on function private.availability_v8(jsonb) to authenticated;

create or replace function private.weekly_commission_dashboard_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare period text:=coalesce(payload->>'period','week'); anchor date:=coalesce(nullif(payload->>'anchor','')::date,timezone('America/Chihuahua',now())::date); start_day date; end_day date; policy private.commission_policy_settings;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'Acceso de Operaciones requerido.' using errcode='42501'; end if;
  if period not in ('day','week','month') then raise exception 'Periodo inválido.'; end if;
  start_day:=case period when 'day' then anchor when 'week' then date_trunc('week',anchor)::date else date_trunc('month',anchor)::date end;
  end_day:=case period when 'day' then start_day+1 when 'week' then start_day+7 else (start_day+interval '1 month')::date end;
  select * into policy from private.commission_policy_settings where id;
  perform private.reconcile_weekly_commission_settlements(now());
  return jsonb_build_object(
    'period',period,'start_day',start_day,'end_day',end_day,
    'policy',jsonb_build_object('commission_bps',policy.commission_bps,'effective_at',policy.effective_at,'settlement_days',policy.settlement_days),
    'summary',(select jsonb_build_object(
      'trips',count(*),'gross_cash_cents',coalesce(sum(coalesce(t.total_cents,t.fare_cents,0)),0),
      'commission_due_cents',coalesce(sum(coalesce(t.commission_cents,0)),0),
      'commission_base_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'commission_base_cents','')::bigint,0)),0),
      'commission_vat_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'commission_vat_cents','')::bigint,0)),0),
      'taxable_base_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'taxable_base_cents','')::bigint,0)),0),
      'fare_vat_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'fare_vat_cents','')::bigint,0)),0),
      'isr_reference_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'isr_withheld_cents','')::bigint,0)),0),
      'vat_reference_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'vat_withheld_cents','')::bigint,0)),0),
      'state_contribution_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'state_contribution_cents','')::bigint,0)),0)
    ) from public.trips t where t.status='completed' and t.payment_method='cash' and t.completed_at>=start_day and t.completed_at<end_day),
    'series',(select coalesce(jsonb_agg(jsonb_build_object('day',x.day,'gross_cash_cents',x.gross_cash_cents,'commission_due_cents',x.commission_due_cents) order by x.day),'[]'::jsonb) from (
      select timezone('America/Chihuahua',t.completed_at)::date as day,sum(coalesce(t.total_cents,t.fare_cents,0))::bigint as gross_cash_cents,sum(coalesce(t.commission_cents,0))::bigint as commission_due_cents
      from public.trips t where t.status='completed' and t.payment_method='cash' and t.completed_at>=start_day and t.completed_at<end_day group by 1
    ) x),
    'drivers',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',d.id,'full_name',p.full_name,'account_active',d.account_active,
      'trips',coalesce(a.trips,0),'gross_cash_cents',coalesce(a.gross_cash_cents,0),'commission_due_cents',coalesce(a.commission_due_cents,0),
      'commission_base_cents',coalesce(a.commission_base_cents,0),'commission_vat_cents',coalesce(a.commission_vat_cents,0),
      'taxable_base_cents',coalesce(a.taxable_base_cents,0),'fare_vat_cents',coalesce(a.fare_vat_cents,0),'isr_reference_cents',coalesce(a.isr_reference_cents,0),'vat_reference_cents',coalesce(a.vat_reference_cents,0),'state_contribution_cents',coalesce(a.state_contribution_cents,0),
      'settlements',coalesce(s.items,'[]'::jsonb)
    ) order by p.full_name),'[]'::jsonb)
    from public.drivers d join public.profiles p on p.id=d.id
    left join lateral (select count(*)::integer as trips,sum(coalesce(t.total_cents,t.fare_cents,0))::bigint gross_cash_cents,sum(coalesce(t.commission_cents,0))::bigint commission_due_cents,
      sum(coalesce(nullif(t.financial_breakdown->>'commission_base_cents','')::bigint,0))::bigint commission_base_cents,sum(coalesce(nullif(t.financial_breakdown->>'commission_vat_cents','')::bigint,0))::bigint commission_vat_cents,
      sum(coalesce(nullif(t.financial_breakdown->>'taxable_base_cents','')::bigint,0))::bigint taxable_base_cents,sum(coalesce(nullif(t.financial_breakdown->>'fare_vat_cents','')::bigint,0))::bigint fare_vat_cents,
      sum(coalesce(nullif(t.financial_breakdown->>'isr_withheld_cents','')::bigint,0))::bigint isr_reference_cents,sum(coalesce(nullif(t.financial_breakdown->>'vat_withheld_cents','')::bigint,0))::bigint vat_reference_cents,
      sum(coalesce(nullif(t.financial_breakdown->>'state_contribution_cents','')::bigint,0))::bigint state_contribution_cents
      from public.trips t where t.driver_id=d.id and t.status='completed' and t.payment_method='cash' and t.completed_at>=start_day and t.completed_at<end_day) a on true
    left join lateral (select jsonb_agg(jsonb_build_object('id',s.id,'week_start',s.week_start,'due_at',s.due_at,'gross_cash_cents',s.gross_cash_cents,'commission_due_cents',s.commission_due_cents,'status',s.status) order by s.week_start desc) items from public.driver_commission_settlements s where s.driver_id=d.id) s on true),
    'settlements',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'driver_id',s.driver_id,'driver_name',p.full_name,'week_start',s.week_start,'due_at',s.due_at,'gross_cash_cents',s.gross_cash_cents,'commission_due_cents',s.commission_due_cents,'status',s.status,'note',s.note,'account_active',d.account_active) order by s.due_at asc),'[]'::jsonb) from public.driver_commission_settlements s join public.profiles p on p.id=s.driver_id join public.drivers d on d.id=s.driver_id)
  );
end $$;
revoke all on function private.weekly_commission_dashboard_v1(jsonb) from public, anon;
grant execute on function private.weekly_commission_dashboard_v1(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_weekly_commissions;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  case command
    when 'bootstrap' then return private.bootstrap_v7(payload);
    when 'availability' then return private.availability_v8(payload);
    when 'weekly_commission_dashboard' then return private.weekly_commission_dashboard_v1(payload);
    when 'review_weekly_commission' then return private.review_weekly_commission_v1(payload);
    when 'set_driver_access' then return private.set_driver_access_v2(payload);
    else return public.yavoi_before_weekly_commissions(command,payload);
  end case;
end $$;
revoke all on function public.yavoi(text,jsonb) from public, anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
