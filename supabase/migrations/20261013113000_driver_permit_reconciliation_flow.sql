-- A weekly cut must never leave a driver with an unexplained generic block.
-- This migration makes the evidence, reconciliation receipt and operating
-- authorization one auditable flow.

create table if not exists public.driver_settlement_receipts (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null unique references public.driver_commission_settlements(id) on delete restrict,
  driver_id uuid not null references public.profiles(id) on delete restrict,
  receipt_number text not null unique,
  amount_cents integer not null check (amount_cents >= 0),
  proof_path text not null,
  reference text not null check (char_length(reference) between 5 and 500),
  verified_by uuid not null references public.profiles(id) on delete restrict,
  verified_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
alter table public.driver_settlement_receipts enable row level security;
revoke all on public.driver_settlement_receipts from anon, authenticated;
create index if not exists driver_settlement_receipts_driver_created_idx
  on public.driver_settlement_receipts(driver_id, created_at desc);

create table if not exists public.driver_operating_notices (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('permit_authorized','permit_suspended','reconciliation_received')),
  title text not null check (char_length(title) between 3 and 160),
  body text not null check (char_length(body) between 3 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
alter table public.driver_operating_notices enable row level security;
revoke all on public.driver_operating_notices from anon, authenticated;
create index if not exists driver_operating_notices_driver_created_idx
  on public.driver_operating_notices(driver_id, created_at desc);

create or replace function private.driver_permission_status_v1(target uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.drivers; p public.profiles;
begin
  select * into p from public.profiles where id=target;
  select * into d from public.drivers where id=target;
  if not found or p.role <> 'driver' then
    return jsonb_build_object('allowed',false,'code','not_driver','label','Perfil de conductor no disponible','message','Tu perfil de conductor no está disponible. Contacta a Operaciones.');
  end if;
  if p.suspended then
    return jsonb_build_object('allowed',false,'code','profile_suspended','label','Cuenta suspendida por Operaciones','message','Tu cuenta está suspendida por Operaciones. Revisa tu Bandeja de Entrada.');
  end if;
  if not d.approved then
    return jsonb_build_object('allowed',false,'code','dossier_pending','label','Expediente pendiente de autorización','message','Tu expediente debe estar aprobado por Operaciones antes de que puedas conducir.');
  end if;
  if coalesce(d.license_expires < current_date,true) then
    return jsonb_build_object('allowed',false,'code','license_expired','label','Licencia vencida o pendiente','message','Actualiza tu licencia vigente en Mi perfil para solicitar la autorización.');
  end if;
  if coalesce(d.insurance_expires < current_date,true) then
    return jsonb_build_object('allowed',false,'code','insurance_expired','label','Seguro vencido o pendiente','message','Actualiza tu póliza vigente en Mi perfil para solicitar la autorización.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='overdue') then
    return jsonb_build_object('allowed',false,'code','settlement_overdue','label','Corte semanal vencido','message','Tu corte semanal está vencido. Sube el comprobante desde Mi perfil para que Operaciones lo concilie.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='submitted') then
    return jsonb_build_object('allowed',false,'code','settlement_review','label','Comprobante en revisión','message','Operaciones está validando tu comprobante de corte semanal. Recibirás el comprobante de conciliación en tu Bandeja de Entrada.');
  end if;
  if not d.account_active then
    return jsonb_build_object('allowed',false,'code','operations_authorization','label','Permiso pendiente de Operaciones','message','Operaciones debe autorizar tu permiso para conducir. Revisa tu Bandeja de Entrada.');
  end if;
  return jsonb_build_object('allowed',true,'code','authorized','label','Permiso para conducir activo','message','Tu expediente, corte semanal y autorización están vigentes.');
end $$;
revoke all on function private.driver_permission_status_v1(uuid) from public, anon, authenticated;

-- A submitted proof is evidence awaiting review, never an automatic overdue
-- balance. Only a cut with no evidence after the deadline becomes overdue.
create or replace function private.reconcile_weekly_commission_settlements(reference_at timestamptz default now())
returns integer language plpgsql security definer set search_path='' as $$
declare policy private.commission_policy_settings; changed integer:=0;
begin
  select * into policy from private.commission_policy_settings where id for share;
  with eligible as (
    select t.driver_id,
      date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date as week_start,
      sum(coalesce(t.total_cents,t.fare_cents,0))::integer as gross_cash_cents,
      sum(coalesce(t.commission_cents,0))::integer as commission_due_cents
    from public.trips t
    where t.status='completed' and t.payment_method='cash' and t.billing_mode='commission'
      and t.driver_id is not null and t.completed_at >= policy.effective_at
      and date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date
          < date_trunc('week', timezone('America/Chihuahua', reference_at))::date
    group by t.driver_id, date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date
  ), upserted as (
    insert into public.driver_commission_settlements(driver_id,week_start,due_at,gross_cash_cents,commission_due_cents,status,note)
    select driver_id,week_start,
      (((week_start + 7 + policy.settlement_days)::timestamp + time '23:59:59') at time zone 'America/Chihuahua'),
      gross_cash_cents,commission_due_cents,'pending','Corte semanal de comisión Yavoi!'
    from eligible
    on conflict (driver_id,week_start) do update set
      gross_cash_cents=excluded.gross_cash_cents, commission_due_cents=excluded.commission_due_cents,
      due_at=excluded.due_at, updated_at=now()
    where public.driver_commission_settlements.status in ('pending','submitted','overdue')
    returning id,driver_id,due_at,commission_due_cents,week_start
  )
  insert into public.driver_settlement_notices(driver_id,settlement_id,title,body,due_at)
  select u.driver_id,u.id,'Tu corte semanal está listo',
    format('Operaciones registró tu corte del %s. Retención comercial pendiente: $%s. Sube tu comprobante antes del %s para conservar tu autorización de conducción.',
      to_char(u.week_start,'DD/MM/YYYY'),to_char(u.commission_due_cents::numeric/100,'FM999999990.00'),
      to_char(timezone('America/Chihuahua',u.due_at),'DD/MM/YYYY HH24:MI')),
    u.due_at from upserted u
  on conflict (settlement_id) do update set body=excluded.body,due_at=excluded.due_at;
  get diagnostics changed = row_count;

  update public.driver_commission_settlements set status='overdue',updated_at=now()
  where status='pending' and due_at < reference_at;

  update public.drivers d set account_active=false,online=false,updated_at=now(),
    account_access_note='Acceso suspendido por corte semanal vencido; comprobante pendiente.'
  where d.account_active and exists(select 1 from public.driver_commission_settlements s where s.driver_id=d.id and s.status='overdue');
  return changed;
end $$;
revoke all on function private.reconcile_weekly_commission_settlements(timestamptz) from public, anon;

create or replace function private.submit_driver_settlement_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.profiles; settlement public.driver_commission_settlements; path_value text;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  select * into settlement from public.driver_commission_settlements where id=(payload->>'settlement_id')::uuid and driver_id=uid for update;
  if not found or settlement.status in ('paid','waived') then raise exception 'Este corte ya no admite comprobante.'; end if;
  path_value:=nullif(trim(payload->>'proof_path'),'');
  if path_value is null or not exists(select 1 from storage.objects where bucket_id='yavoi-payment-proofs' and name=path_value and (storage.foldername(name))[1]=uid::text) then raise exception 'Carga un comprobante válido de tu propio perfil.'; end if;
  update public.driver_commission_settlements set proof_path=path_value,status='submitted',submitted_at=now(),updated_at=now() where id=settlement.id returning * into settlement;
  insert into public.driver_operating_notices(driver_id,kind,title,body)
  values(uid,'reconciliation_received','Comprobante enviado a Operaciones','Tu comprobante fue enviado para conciliación. Mientras se valida, tu permiso para conducir queda en revisión.') ;
  return jsonb_build_object('ok',true,'settlement',to_jsonb(settlement));
end $$;
revoke all on function private.submit_driver_settlement_v1(jsonb) from public, anon;
grant execute on function private.submit_driver_settlement_v1(jsonb) to authenticated;

create or replace function private.review_weekly_commission_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); settlement public.driver_commission_settlements; received integer; note_value text; allow_driver boolean:=coalesce((payload->>'authorize_driver')::boolean,true); d public.drivers; p public.profiles; receipt_no text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501'; end if;
  select * into settlement from public.driver_commission_settlements where id=(payload->>'settlement_id')::uuid for update;
  if not found then raise exception 'Corte no encontrado.'; end if;
  received:=coalesce((payload->>'received_cents')::integer,-1);
  note_value:=left(trim(coalesce(payload->>'note','')),500);
  if settlement.status <> 'submitted' or settlement.proof_path is null then raise exception 'Es necesario que el conductor cargue su comprobante antes de conciliar el corte.'; end if;
  if received<>settlement.commission_due_cents then raise exception 'El importe recibido debe coincidir exactamente con el saldo del corte.'; end if;
  if char_length(note_value)<5 then raise exception 'Registra la referencia o comprobación de Operaciones.'; end if;
  update public.driver_commission_settlements set status='paid',verified_by=uid,verified_at=now(),note=note_value,updated_at=now() where id=settlement.id returning * into settlement;
  receipt_no:=format('YV-CC-%s-%s',to_char(now() at time zone 'America/Chihuahua','YYYYMMDD'),upper(left(replace(settlement.id::text,'-',''),6)));
  insert into public.driver_settlement_receipts(settlement_id,driver_id,receipt_number,amount_cents,proof_path,reference,verified_by,verified_at)
  values(settlement.id,settlement.driver_id,receipt_no,received,settlement.proof_path,note_value,uid,now());
  select * into d from public.drivers where id=settlement.driver_id for update;
  select * into p from public.profiles where id=settlement.driver_id;
  if allow_driver and not p.suspended and d.approved and d.license_expires>=current_date and d.insurance_expires>=current_date then
    update public.drivers set account_active=true,account_access_authorized_at=now(),account_access_authorized_by=uid,
      account_access_note='Permiso autorizado al conciliar el corte '||receipt_no,updated_at=now() where id=settlement.driver_id;
    insert into public.driver_operating_notices(driver_id,kind,title,body) values(settlement.driver_id,'permit_authorized','Permiso para conducir autorizado',format('Operaciones concilió tu corte semanal por $%s. Comprobante %s. Tu permiso para conducir está activo.',to_char(received::numeric/100,'FM999999990.00'),receipt_no));
  else
    insert into public.driver_operating_notices(driver_id,kind,title,body) values(settlement.driver_id,'reconciliation_received','Conciliación confirmada',format('Operaciones validó tu corte semanal por $%s. Comprobante %s. Tu permiso requiere una autorización separada de Operaciones.',to_char(received::numeric/100,'FM999999990.00'),receipt_no));
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'weekly_commission_reconciled',settlement.driver_id,jsonb_build_object('settlement_id',settlement.id,'receipt_number',receipt_no,'received_cents',received,'authorize_driver',allow_driver,'note',note_value));
  return jsonb_build_object('ok',true,'settlement',to_jsonb(settlement),'receipt_number',receipt_no,'driver_authorized',allow_driver and not p.suspended and d.approved and d.license_expires>=current_date and d.insurance_expires>=current_date);
end $$;
revoke all on function private.review_weekly_commission_v1(jsonb) from public, anon;
grant execute on function private.review_weekly_commission_v1(jsonb) to authenticated;

create or replace function private.set_driver_access_v3(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); target uuid; active_value boolean; note_value text; d public.drivers; p public.profiles;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501'; end if;
  target:=(payload->>'driver_id')::uuid; active_value:=coalesce((payload->>'active')::boolean,false); note_value:=left(trim(coalesce(payload->>'note','')),500);
  if char_length(note_value)<5 then raise exception 'Describe el motivo del cambio de permiso.'; end if;
  perform private.reconcile_weekly_commission_settlements(now());
  select * into d from public.drivers where id=target for update; select * into p from public.profiles where id=target;
  if not found then raise exception 'Conductor no encontrado.'; end if;
  if active_value and (p.suspended or not d.approved or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then raise exception 'El conductor necesita expediente aprobado y documentos vigentes antes de autorizar el permiso.'; end if;
  if active_value and exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status in ('overdue','submitted')) then raise exception 'Primero concilia el comprobante del corte semanal pendiente antes de autorizar el permiso.'; end if;
  update public.drivers set account_active=active_value,online=case when active_value then online else false end,
    account_access_authorized_at=case when active_value then now() else null end,account_access_authorized_by=case when active_value then uid else null end,
    account_access_note=note_value,updated_at=now() where id=target;
  insert into public.driver_operating_notices(driver_id,kind,title,body) values(target,case when active_value then 'permit_authorized' else 'permit_suspended' end,case when active_value then 'Permiso para conducir autorizado' else 'Permiso para conducir suspendido' end,case when active_value then 'Operaciones autorizó tu permiso para usar Yavoi! Drive. Puedes conectarte durante tu turno activo.' else 'Operaciones suspendió temporalmente tu permiso para conducir. Revisa la nota en tu perfil o contacta a Operaciones.' end);
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'set_driver_access',target,jsonb_build_object('active',active_value,'note',note_value));
  return jsonb_build_object('ok',true,'active',active_value);
end $$;
revoke all on function private.set_driver_access_v3(jsonb) from public, anon;
grant execute on function private.set_driver_access_v3(jsonb) to authenticated;

create or replace function private.availability_v9(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); going_online boolean:=coalesce((payload->>'online')::boolean,false); d public.drivers; p public.profiles; shift_value public.service_shifts; settings private.transport_compliance_settings; item record; permit jsonb;
begin
  if uid is null then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  perform private.reconcile_weekly_commission_settlements(now());
  select * into p from public.profiles where id=uid; select * into d from public.drivers where id=uid for update;
  if not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  select * into settings from private.transport_compliance_settings where id;
  if going_online and settings.enforcement_mode='enforce' and (not private.company_transport_ready_v1() or not private.driver_dossier_complete(uid)) then raise exception 'Cumplimiento de transporte pendiente. Revisa el expediente y la póliza de la empresa con Operaciones.'; end if;
  permit:=private.driver_permission_status_v1(uid);
  if going_online and not coalesce((permit->>'allowed')::boolean,false) then
    if permit->>'code'='settlement_overdue' then update public.drivers set account_active=false,online=false,updated_at=now() where id=uid; end if;
    raise exception '%',permit->>'message';
  end if;
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
  return jsonb_build_object('ok',true,'account_active',d.account_active,'commission_bps',coalesce(d.cash_commission_bps,1500),'shift_code',d.service_shift_code,'shift_name',shift_value.name,'permission',permit);
end $$;
revoke all on function private.availability_v9(jsonb) from public, anon;
grant execute on function private.availability_v9(jsonb) to authenticated;

create or replace function private.driver_settlement_receipts_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'settlement_id',r.settlement_id,'receipt_number',r.receipt_number,'amount_cents',r.amount_cents,'reference',r.reference,'verified_at',r.verified_at,'created_at',r.created_at,'read_at',r.read_at) order by r.created_at desc),'[]'::jsonb)
  from public.driver_settlement_receipts r where r.driver_id=auth.uid()
$$;
revoke all on function private.driver_settlement_receipts_v1() from public, anon;

create or replace function private.driver_operating_notices_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'title',n.title,'body',n.body,'created_at',n.created_at,'read_at',n.read_at,'kind',n.kind) order by n.created_at desc),'[]'::jsonb)
  from public.driver_operating_notices n where n.driver_id=auth.uid()
$$;
revoke all on function private.driver_operating_notices_v1() from public, anon;

create or replace function private.driver_operating_notice_read_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare notice_id uuid:=nullif(payload->>'announcement_id','')::uuid;
begin
  update public.driver_operating_notices set read_at=coalesce(read_at,now()) where id=notice_id and driver_id=auth.uid();
  if found then return jsonb_build_object('ok',true,'announcement_id',notice_id); end if;
  update public.driver_settlement_receipts set read_at=coalesce(read_at,now()) where id=notice_id and driver_id=auth.uid();
  if found then return jsonb_build_object('ok',true,'announcement_id',notice_id); end if;
  raise exception 'El mensaje no está dirigido a tu perfil.' using errcode='42501';
end $$;
revoke all on function private.driver_operating_notice_read_v1(jsonb) from public, anon;
grant execute on function private.driver_operating_notice_read_v1(jsonb) to authenticated;

create or replace function private.driver_receipt_inbox_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'title','Comprobante de conciliación '||r.receipt_number,
    'body',format('Operaciones confirmó tu pago semanal por $%s. Referencia: %s. Conserva este comprobante para tu control.',to_char(r.amount_cents::numeric/100,'FM999999990.00'),r.reference),
    'created_at',r.created_at,'read_at',r.read_at,'kind','reconciliation_receipt') order by r.created_at desc),'[]'::jsonb)
  from public.driver_settlement_receipts r where r.driver_id=auth.uid()
$$;
revoke all on function private.driver_receipt_inbox_v1() from public, anon;

create or replace function private.bootstrap_v8(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result:=private.bootstrap_v7(payload);
  if (result->'profile'->>'role')='driver' then
    result:=result||jsonb_build_object('driver_permission',private.driver_permission_status_v1(auth.uid()),'settlement_receipts',private.driver_settlement_receipts_v1(),'operating_notices',private.driver_operating_notices_v1());
  end if;
  return result;
end $$;
revoke all on function private.bootstrap_v8(jsonb) from public, anon;
grant execute on function private.bootstrap_v8(jsonb) to authenticated;

create or replace function private.weekly_commission_dashboard_v2(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result:=private.weekly_commission_dashboard_v1(payload);
  return result || jsonb_build_object('settlements',(
    select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'driver_id',s.driver_id,'driver_name',p.full_name,'week_start',s.week_start,'due_at',s.due_at,'gross_cash_cents',s.gross_cash_cents,'commission_due_cents',s.commission_due_cents,'status',s.status,'note',s.note,'proof_path',s.proof_path,'submitted_at',s.submitted_at,'account_active',d.account_active) order by s.due_at asc),'[]'::jsonb)
    from public.driver_commission_settlements s join public.profiles p on p.id=s.driver_id join public.drivers d on d.id=s.driver_id
  ));
end $$;
revoke all on function private.weekly_commission_dashboard_v2(jsonb) from public, anon;
grant execute on function private.weekly_commission_dashboard_v2(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_driver_permit_reconciliation;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  case command
    when 'bootstrap' then return private.bootstrap_v8(payload);
    when 'availability' then return private.availability_v9(payload);
    when 'weekly_commission_dashboard' then return private.weekly_commission_dashboard_v2(payload);
    when 'submit_driver_settlement' then return private.submit_driver_settlement_v1(payload);
    when 'review_weekly_commission' then return private.review_weekly_commission_v1(payload);
    when 'set_driver_access' then return private.set_driver_access_v3(payload);
    else return public.yavoi_before_driver_permit_reconciliation(command,payload);
  end case;
end $$;
revoke all on function public.yavoi(text,jsonb) from public, anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

alter function public.yavoi_inbox(text,jsonb) rename to yavoi_inbox_before_driver_permit_reconciliation;
create function public.yavoi_inbox(command text,payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; role_value text;
begin
  if command='read' and (exists(select 1 from public.driver_operating_notices n where n.id=nullif(payload->>'announcement_id','')::uuid) or exists(select 1 from public.driver_settlement_receipts r where r.id=nullif(payload->>'announcement_id','')::uuid)) then
    return private.driver_operating_notice_read_v1(payload);
  end if;
  result:=public.yavoi_inbox_before_driver_permit_reconciliation(command,payload);
  if command='list' and auth.uid() is not null then
    select role into role_value from public.profiles where id=auth.uid();
    if role_value='driver' then
      result:=result||jsonb_build_object('messages',coalesce(result->'messages','[]'::jsonb)||private.driver_operating_notices_v1()||private.driver_receipt_inbox_v1());
    end if;
  end if;
  return result;
end $$;
revoke all on function public.yavoi_inbox(text,jsonb) from public, anon;
grant execute on function public.yavoi_inbox(text,jsonb) to authenticated;
