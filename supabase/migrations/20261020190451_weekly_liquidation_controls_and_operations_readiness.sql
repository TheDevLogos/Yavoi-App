-- Guard weekly settlements until Operations has recorded a real payment destination.
-- Cut deadlines are fixed at first issue (48 hours) and are not refreshed by cron.

create or replace function private.valid_clabe_v1(candidate text)
returns boolean language plpgsql immutable set search_path='' as $$
declare digits_value text:=regexp_replace(coalesce(candidate,''),'\s','','g');
  position_value integer; weight_value integer; weighted_sum integer:=0; expected_digit integer;
begin
  if digits_value !~ '^[0-9]{18}$' then return false; end if;
  for position_value in 1..17 loop
    weight_value:=case position_value%3 when 1 then 3 when 2 then 7 else 1 end;
    weighted_sum:=weighted_sum+substring(digits_value from position_value for 1)::integer*weight_value;
  end loop;
  expected_digit:=(10-(weighted_sum%10))%10;
  return expected_digit=substring(digits_value from 18 for 1)::integer;
end $$;
revoke all on function private.valid_clabe_v1(text) from public,anon,authenticated;

create or replace function private.weekly_transfer_destination_v1(payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare settings private.commission_policy_settings;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  select * into settings from private.commission_policy_settings where id;
  if not found then raise exception 'No existe la configuración de comisiones.'; end if;
  return jsonb_build_object(
    'bank',coalesce(settings.transfer_bank,''),
    'clabe',coalesce(settings.transfer_clabe,''),
    'configured',length(trim(coalesce(settings.transfer_bank,'')))>=2 and private.valid_clabe_v1(settings.transfer_clabe),
    'settlement_days',2,
    'note','Los cortes se generan el lunes y vencen 48 horas después del primer aviso.'
  );
end $$;
revoke all on function private.weekly_transfer_destination_v1(jsonb) from public,anon;
grant execute on function private.weekly_transfer_destination_v1(jsonb) to authenticated;

create or replace function private.set_weekly_transfer_destination_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare bank_value text:=left(trim(coalesce(payload->>'bank','')),100);
  clabe_value text:=regexp_replace(coalesce(payload->>'clabe',''),'\s','','g');
  note_value text:=left(trim(coalesce(payload->>'note','')),500); settings private.commission_policy_settings;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  if length(bank_value)<2 or not private.valid_clabe_v1(clabe_value) then
    raise exception 'Registra el banco y una CLABE válida de 18 dígitos.' using errcode='22023';
  end if;
  if length(note_value)<5 then raise exception 'Registra la referencia de validación de la cuenta.' using errcode='22023'; end if;
  select * into settings from private.commission_policy_settings where id for update;
  if not found then raise exception 'No existe la configuración de comisiones.'; end if;
  if (coalesce(settings.transfer_bank,'')<>bank_value or coalesce(settings.transfer_clabe,'')<>clabe_value)
    and exists(select 1 from public.driver_commission_settlements where status in ('pending','submitted','overdue')) then
    raise exception 'No se puede cambiar el destino mientras haya liquidaciones abiertas; concílialas antes para conservar el banco indicado en cada aviso.' using errcode='22023';
  end if;
  update private.commission_policy_settings
    set transfer_bank=bank_value,transfer_clabe=clabe_value,updated_at=now()
    where id;
  if not found then raise exception 'No existe la configuración de comisiones.'; end if;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(auth.uid(),'weekly_liquidation_destination_updated',null,jsonb_build_object(
    'bank',bank_value,'clabe_last_four',right(clabe_value,4),'note',note_value,'settlement_days',2));
  return private.weekly_transfer_destination_v1('{}'::jsonb)||jsonb_build_object('saved',true);
end $$;
revoke all on function private.set_weekly_transfer_destination_v1(jsonb) from public,anon;
grant execute on function private.set_weekly_transfer_destination_v1(jsonb) to authenticated;

-- Do not create, age, or enforce a payable settlement while drivers have no
-- valid destination to transfer to. A rerun cannot extend the original due date.
create or replace function private.reconcile_weekly_commission_settlements(reference_at timestamptz default now())
returns integer language plpgsql security definer set search_path='' as $$
declare commission_policy private.commission_policy_settings; liquidation_policy private.driver_liquidation_policy_settings;
  changed integer:=0; local_reference timestamp;
begin
  local_reference:=timezone('America/Chihuahua',reference_at);
  if extract(isodow from local_reference)=1 and local_reference::time<time '07:00' then return 0; end if;
  select * into commission_policy from private.commission_policy_settings where id for share;
  if not found or length(trim(coalesce(commission_policy.transfer_bank,'')))<2
    or not private.valid_clabe_v1(commission_policy.transfer_clabe) then return 0; end if;
  select * into liquidation_policy from private.driver_liquidation_policy_settings where id for share;
  with trip_facts as (
    select t.driver_id,date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date as week_start,
      t.completed_at,t.id,t.total_cents,t.fare_cents,private.trip_liquidation_components_v1(t) as parts,
      a.accepted_at,a.policy_version as accepted_version,coalesce(t.total_cents,t.fare_cents,0)::bigint as gross_cents
    from public.trips t
    left join private.driver_liquidation_policy_acceptances a
      on a.driver_id=t.driver_id and a.policy_version=liquidation_policy.policy_version
    where t.status='completed' and t.payment_status<>'refunded' and t.payment_method='cash' and t.billing_mode='commission'
      and t.driver_id is not null and t.completed_at>=commission_policy.effective_at
      and date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date
        < date_trunc('week',timezone('America/Chihuahua',reference_at))::date
  ), eligible as (
    select driver_id,week_start,sum(gross_cents)::integer as gross_cash_cents,
      sum((parts->>'commission_cents')::bigint)::integer as commission_due_cents,
      sum(case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'isr_reference_cents')::bigint else 0 end)::integer as isr_reference_cents,
      sum(case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'vat_reference_cents')::bigint else 0 end)::integer as vat_reference_cents,
      sum(case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'state_contribution_cents')::bigint else 0 end)::integer as state_contribution_cents,
      count(*)::integer as trip_count,
      coalesce(max(accepted_version) filter(where accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at),'commission-only-legacy') as liquidation_policy_version,
      jsonb_agg(parts||jsonb_build_object(
        'accepted_for_new_components',accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at,
        'isr_reference_cents',case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'isr_reference_cents')::bigint else 0 end,
        'vat_reference_cents',case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'vat_reference_cents')::bigint else 0 end,
        'state_contribution_cents',case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'state_contribution_cents')::bigint else 0 end,
        'settlement_due_cents',(parts->>'commission_cents')::bigint+case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'isr_reference_cents')::bigint+(parts->>'vat_reference_cents')::bigint+(parts->>'state_contribution_cents')::bigint else 0 end
      ) order by completed_at,id) as liquidation_breakdown
    from trip_facts group by driver_id,week_start
  ), upserted as (
    insert into public.driver_commission_settlements(
      driver_id,week_start,due_at,gross_cash_cents,commission_due_cents,isr_reference_cents,vat_reference_cents,
      state_contribution_cents,settlement_due_cents,trip_count,liquidation_policy_version,liquidation_breakdown,status,note
    )
    select driver_id,week_start,reference_at+interval '48 hours',gross_cash_cents,commission_due_cents,
      isr_reference_cents,vat_reference_cents,state_contribution_cents,
      commission_due_cents+isr_reference_cents+vat_reference_cents+state_contribution_cents,
      trip_count,liquidation_policy_version,liquidation_breakdown,'pending','Liquidación semanal Yavoi!'
    from eligible
    on conflict(driver_id,week_start) do update set
      gross_cash_cents=excluded.gross_cash_cents,commission_due_cents=excluded.commission_due_cents,
      isr_reference_cents=excluded.isr_reference_cents,vat_reference_cents=excluded.vat_reference_cents,
      state_contribution_cents=excluded.state_contribution_cents,settlement_due_cents=excluded.settlement_due_cents,
      trip_count=excluded.trip_count,liquidation_policy_version=excluded.liquidation_policy_version,
      liquidation_breakdown=excluded.liquidation_breakdown,updated_at=now()
    where public.driver_commission_settlements.status in ('pending','submitted','overdue')
    returning id,driver_id,due_at,week_start,commission_due_cents,isr_reference_cents,vat_reference_cents,
      state_contribution_cents,settlement_due_cents
  )
  insert into public.driver_settlement_notices(driver_id,settlement_id,title,body,due_at)
  select u.driver_id,u.id,'Tu liquidación semanal está lista',
    format('Operaciones registró %s viaje(s) en efectivo de la semana del %s. Comisión Yavoi!: $%s; ISR de referencia: $%s; IVA de referencia: $%s; aportación estatal de referencia, sujeta a autorización/convenio: $%s. TOTAL A TRANSFERIR A YAVOI!: $%s. Banco: %s. CLABE: %s. Tienes 48 horas desde este aviso; vence %s. Los importes de referencia no acreditan retención ni pago a la autoridad.',
      (select e.trip_count from eligible e where e.driver_id=u.driver_id and e.week_start=u.week_start),
      to_char(u.week_start,'DD/MM/YYYY'),to_char(u.commission_due_cents::numeric/100,'FM999999990.00'),
      to_char(u.isr_reference_cents::numeric/100,'FM999999990.00'),to_char(u.vat_reference_cents::numeric/100,'FM999999990.00'),
      to_char(u.state_contribution_cents::numeric/100,'FM999999990.00'),to_char(u.settlement_due_cents::numeric/100,'FM999999990.00'),
      commission_policy.transfer_bank,commission_policy.transfer_clabe,
      to_char(timezone('America/Chihuahua',u.due_at),'DD/MM/YYYY HH24:MI')),
    u.due_at from upserted u
  on conflict(settlement_id) do update set body=excluded.body,due_at=excluded.due_at;
  get diagnostics changed=row_count;

  update public.driver_commission_settlements set status='overdue',updated_at=now()
  where status='pending' and due_at<reference_at;
  update public.drivers d set account_active=false,online=false,updated_at=now(),
    account_access_note='Liquidación semanal vencida; comprobante pendiente.'
  where d.account_active and exists(select 1 from public.driver_commission_settlements s where s.driver_id=d.id and s.status='overdue');
  update public.drivers set online=false,updated_at=now(),
    account_access_note='Operaciones debe activar la modalidad de comisión semanal vigente.'
  where online and billing_mode is distinct from 'commission' and now()>=liquidation_policy.effective_at;
  return changed;
end $$;
revoke all on function private.reconcile_weekly_commission_settlements(timestamptz) from public,anon,authenticated;

-- A weekly message carries the destination only to its authenticated owner.
create or replace function private.driver_weekly_settlement_messages_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',n.id,'title','Resumen de tu liquidación semanal','category','payment','created_at',n.created_at,
    'ends_at',n.due_at,'is_read',n.read_at is not null,'due_at',n.due_at,'settlement_id',n.settlement_id,
    'amount_due_cents',s.settlement_due_cents,'trip_count',s.trip_count,'commission_due_cents',s.commission_due_cents,
    'isr_reference_cents',s.isr_reference_cents,'vat_reference_cents',s.vat_reference_cents,
    'state_contribution_cents',s.state_contribution_cents,'liquidation_breakdown',s.liquidation_breakdown,
    'body',n.body
  ) order by n.created_at desc),'[]'::jsonb)
  from public.driver_settlement_notices n
  join public.driver_commission_settlements s on s.id=n.settlement_id
  where n.driver_id=auth.uid() and s.status in ('pending','submitted','overdue')
$$;
revoke all on function private.driver_weekly_settlement_messages_v1() from public,anon;
grant execute on function private.driver_weekly_settlement_messages_v1() to authenticated;

-- Add the registration card's expiry to the Operations review, not to the
-- driver's list of documents to enter manually.
create or replace function private.driver_legal_missing_v1(target uuid) returns text[]
language sql stable security definer set search_path='' as $$
  select coalesce(array_agg(label order by sort_order) filter(where not ok),array[]::text[])
  from public.drivers d join public.profiles p on p.id=d.id
  cross join lateral (values
    (1,'Fotografía del conductor',p.avatar_path is not null),
    (2,'Identificación oficial INE',d.government_id_path is not null),
    (3,'Licencia vigente',d.license_path is not null and d.license_expires>=current_date),
    (4,'Tarjeta de circulación vigente',d.vehicle_registration_path is not null and d.vehicle_registration_expires>=current_date),
    (5,'Póliza particular vigente',d.insurance_path is not null and d.insurance_expires>=current_date),
    (6,'Datos oficiales de la unidad',length(trim(d.vehicle_make))>=2 and length(trim(d.vehicle_model))>=1 and d.vehicle_year between 1990 and extract(year from current_date)::integer+1 and length(trim(d.vehicle_color))>=3 and length(trim(d.plate))>=5),
    (7,'Tarjetón de transporte',length(trim(d.transport_card_number))>=3 and d.transport_card_expires>=current_date),
    (8,'Afiliación Yavoi!',d.affiliation_number is not null and d.affiliation_expires>=current_date)
  ) as requirement(sort_order,label,ok)
  where d.id=target
$$;
revoke all on function private.driver_legal_missing_v1(uuid) from public,anon,authenticated;

create or replace function private.driver_permit_prerequisites_v1(target uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d public.drivers; p public.profiles; policy private.driver_liquidation_policy_settings; terms jsonb;
  missing text[];
begin
  select * into p from public.profiles where id=target;
  select * into d from public.drivers where id=target;
  if target is null or p.id is null or p.role is distinct from 'driver' or d.id is null then
    return jsonb_build_object('allowed',false,'code','not_driver','label','Perfil de conductor no disponible','message','El perfil de conductor no está disponible.');
  end if;
  if p.suspended then return jsonb_build_object('allowed',false,'code','profile_suspended','label','Cuenta suspendida','message','Operaciones debe revisar la suspensión.'); end if;
  if not private.driver_dossier_complete(target) then
    return jsonb_build_object('allowed',false,'code','documents_or_policies','label','Documentos o políticas pendientes','message','Se requieren fotografía, INE, licencia, tarjeta de circulación, póliza vigente y aceptación de Privacidad y Términos.');
  end if;
  if not d.approved then return jsonb_build_object('allowed',false,'code','operations_review','label','Expediente sin autorización','message','Operaciones debe revisar y autorizar el expediente.'); end if;
  missing:=private.driver_legal_missing_v1(target);
  if cardinality(missing)>0 then
    return jsonb_build_object('allowed',false,'code','official_data_or_expiry','label','Vigencias o datos oficiales pendientes','message','Operaciones debe revisar: '||array_to_string(missing,', ')||'.');
  end if;
  if coalesce(d.license_expires<current_date,true) then return jsonb_build_object('allowed',false,'code','license_expired','label','Licencia vencida','message','Actualiza tu licencia vigente con Operaciones.'); end if;
  if coalesce(d.insurance_expires<current_date,true) then return jsonb_build_object('allowed',false,'code','insurance_expired','label','Seguro vencido','message','Actualiza tu póliza vigente con Operaciones.'); end if;
  if coalesce(d.vehicle_registration_expires<current_date,true) then return jsonb_build_object('allowed',false,'code','registration_expired','label','Tarjeta de circulación vencida','message','Actualiza la vigencia de tu tarjeta de circulación con Operaciones.'); end if;
  if coalesce(d.transport_card_expires<current_date,true) then return jsonb_build_object('allowed',false,'code','transport_card_expired','label','Tarjetón de transporte vencido','message','Operaciones debe actualizar el registro oficial de transporte.'); end if;
  if coalesce(d.affiliation_expires<current_date,true) then return jsonb_build_object('allowed',false,'code','affiliation_expired','label','Afiliación vencida','message','Operaciones debe renovar tu permiso de afiliación.'); end if;
  if d.billing_mode is distinct from 'commission' then return jsonb_build_object('allowed',false,'code','commission_mode_pending','label','Modalidad semanal pendiente','message','Operaciones debe activar la modalidad de comisión semanal.'); end if;
  select * into policy from private.driver_liquidation_policy_settings where id;
  if policy.id and now()>=policy.effective_at then
    terms:=private.driver_liquidation_policy_status_v1(target);
    if not coalesce((terms->>'fiscal_profile_verified')::boolean,false) then
      return jsonb_build_object('allowed',false,'code','fiscal_profile_pending','label','Validación fiscal pendiente','message','Operaciones debe validar el tipo fiscal y RFC antes de habilitar la liquidación semanal.');
    end if;
    if not coalesce((terms->>'accepted')::boolean,false) then
      return jsonb_build_object('allowed',false,'code','liquidation_terms','label','Aceptación semanal pendiente','message','Acepta el desglose de comisión y referencias fiscales desde Mi perfil.');
    end if;
  end if;
  return jsonb_build_object('allowed',true,'code','ready','label','Requisitos vigentes','message','Expediente, políticas, vigencias y modalidad semanal completos.');
end $$;
revoke all on function private.driver_permit_prerequisites_v1(uuid) from public,anon,authenticated;

create or replace function private.driver_permission_status_v1(target uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.drivers; prerequisites jsonb;
begin
  select * into d from public.drivers where id=target;
  prerequisites:=private.driver_permit_prerequisites_v1(target);
  if not coalesce((prerequisites->>'allowed')::boolean,false) then return prerequisites; end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='overdue') then
    return jsonb_build_object('allowed',false,'code','settlement_overdue','label','Liquidación semanal vencida','message','Sube el comprobante y espera la conciliación de Operaciones.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='submitted') then
    return jsonb_build_object('allowed',false,'code','settlement_review','label','Comprobante en revisión','message','Operaciones está revisando tu comprobante semanal.');
  end if;
  if not d.account_active then
    return jsonb_build_object('allowed',false,'code','operations_authorization','label','Permiso pendiente de Operaciones','message','Operaciones debe activar tu permiso después de validar el expediente y la liquidación.');
  end if;
  return jsonb_build_object('allowed',true,'code','authorized','label','Permiso para conducir activo','message','Expediente vigente, políticas aceptadas y liquidación semanal al corriente.');
end $$;
revoke all on function private.driver_permission_status_v1(uuid) from public,anon,authenticated;

do $$ begin
  if to_regprocedure('private.set_driver_access_before_permit_gate_v3(jsonb)') is null then
    alter function private.set_driver_access_v3(jsonb) rename to set_driver_access_before_permit_gate_v3;
  end if;
end $$;
create or replace function private.set_driver_access_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid:=nullif(payload->>'driver_id','')::uuid;
  active_value boolean:=coalesce((payload->>'active')::boolean,false); prerequisites jsonb;
begin
  if active_value then
    prerequisites:=private.driver_permit_prerequisites_v1(target);
    if not coalesce((prerequisites->>'allowed')::boolean,false) then
      raise exception '%',coalesce(prerequisites->>'message','El expediente no cumple los requisitos para autorizar el permiso.') using errcode='22023';
    end if;
    if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status in ('overdue','submitted')) then
      raise exception 'No se puede activar el permiso mientras exista una liquidación vencida o un comprobante en revisión.' using errcode='22023';
    end if;
  end if;
  return private.set_driver_access_before_permit_gate_v3(payload);
end $$;
revoke all on function private.set_driver_access_v3(jsonb) from public,anon;
grant execute on function private.set_driver_access_v3(jsonb) to authenticated;

-- Wrap the existing Operations review so it records and validates the expiry
-- date from the uploaded circulation card.
do $$ begin
  if to_regprocedure('private.review_driver_v4_before_registration_expiry(jsonb)') is null then
    alter function private.review_driver_v4(jsonb) rename to review_driver_v4_before_registration_expiry;
  end if;
end $$;
create or replace function private.review_driver_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; target uuid:=nullif(payload->>'driver_id','')::uuid;
  approved_value boolean:=coalesce((payload->>'approved')::boolean,false);
  registration_until date:=nullif(payload->>'vehicle_registration_expires','')::date;
begin
  result:=private.review_driver_v4_before_registration_expiry(payload);
  if approved_value and (registration_until is null or registration_until<current_date) then
    raise exception 'Operaciones debe registrar una fecha vigente de la tarjeta de circulación antes de autorizar.' using errcode='22023';
  end if;
  if approved_value then
    update public.drivers set vehicle_registration_expires=registration_until,updated_at=now() where id=target;
  end if;
  return result;
end $$;
revoke all on function private.review_driver_v4(jsonb) from public,anon;
grant execute on function private.review_driver_v4(jsonb) to authenticated;

-- A paid receipt can reactivate a driver only if every non-payment prerequisite
-- is still satisfied; otherwise the payment is reconciled but permission stays off.
do $$ begin
  if to_regprocedure('private.review_weekly_commission_before_permit_gate_v1(jsonb)') is null then
    alter function private.review_weekly_commission_v1(jsonb) rename to review_weekly_commission_before_permit_gate_v1;
  end if;
end $$;
create or replace function private.review_weekly_commission_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare settlement_id uuid:=nullif(payload->>'settlement_id','')::uuid; safe_payload jsonb:=payload;
  prereq jsonb; result jsonb; allow_driver boolean:=coalesce((payload->>'authorize_driver')::boolean,true);
begin
  if allow_driver then
    prereq:=private.driver_permit_prerequisites_v1((select driver_id from public.driver_commission_settlements where id=settlement_id));
    if not coalesce((prereq->>'allowed')::boolean,false)
      or exists(select 1 from public.driver_commission_settlements s where s.driver_id=(select driver_id from public.driver_commission_settlements where id=settlement_id)
        and s.id<>settlement_id and s.status in ('overdue','submitted')) then
      safe_payload:=safe_payload||jsonb_build_object('authorize_driver',false);
    end if;
  end if;
  result:=private.review_weekly_commission_before_permit_gate_v1(safe_payload);
  if allow_driver and safe_payload->>'authorize_driver'='false' then
    result:=result||jsonb_build_object('driver_authorized',false,'permit_block_reason',coalesce(prereq->>'message','Existe otra liquidación vencida o en revisión.'));
  end if;
  return result;
end $$;
revoke all on function private.review_weekly_commission_v1(jsonb) from public,anon;
grant execute on function private.review_weekly_commission_v1(jsonb) to authenticated;

-- Apply the same period, driver, and settlement-status scope to every
-- Operations metric, chart, driver row, and cut list.
create or replace function private.weekly_commission_dashboard_v4(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; start_day date; end_day date; target uuid;
  status_value text:=nullif(payload->>'status',''); summary_value jsonb;
  series_value jsonb; drivers_value jsonb; settlements_value jsonb; open_settlements_value jsonb;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  if status_value is not null and status_value not in ('pending','submitted','paid','overdue','waived') then
    raise exception 'Estado de liquidación inválido.' using errcode='22023';
  end if;
  target:=nullif(payload->>'driver_id','')::uuid;
  result:=private.weekly_commission_dashboard_v3(payload);
  start_day:=(result->>'start_day')::date;
  end_day:=(result->>'end_day')::date;

  with scoped as (
    select t.*,private.trip_liquidation_components_v1(t) as parts,a.accepted_at,lp.effective_at
    from public.trips t
    left join private.driver_liquidation_policy_settings lp on lp.id
    left join private.driver_liquidation_policy_acceptances a
      on a.driver_id=t.driver_id and a.policy_version=lp.policy_version
    where t.status='completed' and t.payment_status<>'refunded' and t.payment_method='cash'
      and timezone('America/Chihuahua',t.completed_at)::date>=start_day
      and timezone('America/Chihuahua',t.completed_at)::date<end_day
      and (target is null or t.driver_id=target)
      and (status_value is null or (t.billing_mode='commission' and exists(
        select 1 from public.driver_commission_settlements cut
        where cut.driver_id=t.driver_id
          and cut.week_start=date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date
          and cut.status=status_value)))
  )
  select jsonb_build_object(
    'trips',count(*),
    'gross_cash_cents',coalesce(sum(coalesce(sc.total_cents,sc.fare_cents,0)),0),
    'commission_due_cents',coalesce(sum(coalesce(sc.commission_cents,0)),0),
    'commission_base_cents',coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'commission_base_cents','')::bigint,0)),0),
    'commission_vat_cents',coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'commission_vat_cents','')::bigint,0)),0),
    'taxable_base_cents',coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'taxable_base_cents','')::bigint,0)),0),
    'fare_vat_cents',coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'fare_vat_cents','')::bigint,0)),0),
    'isr_reference_cents',coalesce(sum(case when sc.billing_mode='commission' then (sc.parts->>'isr_reference_cents')::bigint else 0 end),0),
    'vat_reference_cents',coalesce(sum(case when sc.billing_mode='commission' then (sc.parts->>'vat_reference_cents')::bigint else 0 end),0),
    'state_contribution_cents',coalesce(sum(case when sc.billing_mode='commission' then (sc.parts->>'state_contribution_cents')::bigint else 0 end),0),
    'cash_liquidation_component_cents',coalesce(sum(case when sc.accepted_at is not null
      and sc.billing_mode='commission' and sc.effective_at is not null and sc.completed_at>=sc.effective_at and sc.completed_at>=sc.accepted_at
      then (sc.parts->>'isr_reference_cents')::bigint+(sc.parts->>'vat_reference_cents')::bigint+(sc.parts->>'state_contribution_cents')::bigint else 0 end),0),
    'isr_liquidation_reference_cents',coalesce(sum(case when sc.accepted_at is not null
      and sc.billing_mode='commission' and sc.effective_at is not null and sc.completed_at>=sc.effective_at and sc.completed_at>=sc.accepted_at
      then (sc.parts->>'isr_reference_cents')::bigint else 0 end),0),
    'vat_liquidation_reference_cents',coalesce(sum(case when sc.accepted_at is not null
      and sc.billing_mode='commission' and sc.effective_at is not null and sc.completed_at>=sc.effective_at and sc.completed_at>=sc.accepted_at
      then (sc.parts->>'vat_reference_cents')::bigint else 0 end),0),
    'state_liquidation_reference_cents',coalesce(sum(case when sc.accepted_at is not null
      and sc.billing_mode='commission' and sc.effective_at is not null and sc.completed_at>=sc.effective_at and sc.completed_at>=sc.accepted_at
      then (sc.parts->>'state_contribution_cents')::bigint else 0 end),0)
  ) into summary_value from scoped sc;

  with scoped as (
    select t.*,timezone('America/Chihuahua',t.completed_at)::date as local_day
    from public.trips t
    where t.status='completed' and t.payment_status<>'refunded' and t.payment_method='cash'
      and timezone('America/Chihuahua',t.completed_at)::date>=start_day
      and timezone('America/Chihuahua',t.completed_at)::date<end_day
      and (target is null or t.driver_id=target)
      and (status_value is null or (t.billing_mode='commission' and exists(
        select 1 from public.driver_commission_settlements cut
        where cut.driver_id=t.driver_id
          and cut.week_start=date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date
          and cut.status=status_value)))
  )
  select coalesce(jsonb_agg(jsonb_build_object('day',daily.local_day,
    'gross_cash_cents',daily.gross_cash_cents,'commission_due_cents',daily.commission_due_cents) order by daily.local_day),'[]'::jsonb)
  into series_value from (
    select sc.local_day,sum(coalesce(sc.total_cents,sc.fare_cents,0))::bigint as gross_cash_cents,
      sum(coalesce(sc.commission_cents,0))::bigint as commission_due_cents
    from scoped sc group by sc.local_day
  ) daily;

  with scoped as (
    select t.*,private.trip_liquidation_components_v1(t) as parts
    from public.trips t
    where t.status='completed' and t.payment_status<>'refunded' and t.payment_method='cash'
      and timezone('America/Chihuahua',t.completed_at)::date>=start_day
      and timezone('America/Chihuahua',t.completed_at)::date<end_day
      and (target is null or t.driver_id=target)
      and (status_value is null or (t.billing_mode='commission' and exists(
        select 1 from public.driver_commission_settlements cut
        where cut.driver_id=t.driver_id
          and cut.week_start=date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date
          and cut.status=status_value)))
  ), driver_totals as (
    select d.id,p.full_name,d.account_active,count(sc.id)::integer as trips,
      coalesce(sum(coalesce(sc.total_cents,sc.fare_cents,0)),0)::bigint as gross_cash_cents,
      coalesce(sum(coalesce(sc.commission_cents,0)),0)::bigint as commission_due_cents,
      coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'commission_base_cents','')::bigint,0)),0)::bigint as commission_base_cents,
      coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'commission_vat_cents','')::bigint,0)),0)::bigint as commission_vat_cents,
      coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'taxable_base_cents','')::bigint,0)),0)::bigint as taxable_base_cents,
      coalesce(sum(coalesce(nullif(sc.financial_breakdown->>'fare_vat_cents','')::bigint,0)),0)::bigint as fare_vat_cents,
      coalesce(sum(case when sc.billing_mode='commission' then (sc.parts->>'isr_reference_cents')::bigint else 0 end),0)::bigint as isr_reference_cents,
      coalesce(sum(case when sc.billing_mode='commission' then (sc.parts->>'vat_reference_cents')::bigint else 0 end),0)::bigint as vat_reference_cents,
      coalesce(sum(case when sc.billing_mode='commission' then (sc.parts->>'state_contribution_cents')::bigint else 0 end),0)::bigint as state_contribution_cents
    from public.drivers d join public.profiles p on p.id=d.id
    left join scoped sc on sc.driver_id=d.id
    where target is null or d.id=target
    group by d.id,p.full_name,d.account_active
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',totals.id,'full_name',totals.full_name,'account_active',totals.account_active,'trips',totals.trips,
    'gross_cash_cents',totals.gross_cash_cents,'commission_due_cents',totals.commission_due_cents,
    'commission_base_cents',totals.commission_base_cents,'commission_vat_cents',totals.commission_vat_cents,
    'taxable_base_cents',totals.taxable_base_cents,'fare_vat_cents',totals.fare_vat_cents,
    'isr_reference_cents',totals.isr_reference_cents,'vat_reference_cents',totals.vat_reference_cents,
    'state_contribution_cents',totals.state_contribution_cents
  ) order by totals.full_name),'[]'::jsonb) into drivers_value from driver_totals totals;

  select coalesce(jsonb_agg(cut order by (cut->>'due_at')::timestamptz),'[]'::jsonb)
  into settlements_value from jsonb_array_elements(coalesce(result->'settlements','[]'::jsonb)) cut
  where (cut->>'week_start')::date<end_day and (cut->>'week_start')::date+7>start_day
    and (target is null or cut->>'driver_id'=target::text)
    and (status_value is null or cut->>'status'=status_value);
  select coalesce(jsonb_agg(cut order by (cut->>'due_at')::timestamptz),'[]'::jsonb)
  into open_settlements_value from jsonb_array_elements(coalesce(result->'settlements','[]'::jsonb)) cut
  where cut->>'status' in ('pending','submitted','overdue');

  summary_value:=coalesce(result->'summary','{}'::jsonb)||summary_value||jsonb_build_object(
    'pending_liquidation_cents',coalesce((select sum((cut->>'settlement_due_cents')::bigint)
      from jsonb_array_elements(settlements_value) cut where cut->>'status' in ('pending','submitted','overdue')),0),
    'paid_liquidation_cents',coalesce((select sum((cut->>'settlement_due_cents')::bigint)
      from jsonb_array_elements(settlements_value) cut where cut->>'status'='paid'),0));
  return result||jsonb_build_object('summary',summary_value,'series',series_value,'drivers',drivers_value,
    'settlements',settlements_value,'open_settlements',open_settlements_value,
    'filters',jsonb_build_object('driver_id',target,'status',status_value,'period',result->>'period',
      'start_day',start_day,'end_day',end_day));
end $$;
revoke all on function private.weekly_commission_dashboard_v4(jsonb) from public,anon;
grant execute on function private.weekly_commission_dashboard_v4(jsonb) to authenticated;

-- Expose only these two new commands; all existing routes continue through the
-- previous dispatcher unchanged.
do $$ begin
  if to_regprocedure('private.yavoi_before_liquidation_controls(text,jsonb)') is null then
    alter function public.yavoi(text,jsonb) rename to yavoi_before_liquidation_controls;
    alter function public.yavoi_before_liquidation_controls(text,jsonb) set schema private;
  end if;
end $$;
revoke all on function private.yavoi_before_liquidation_controls(text,jsonb) from public,anon;
grant execute on function private.yavoi_before_liquidation_controls(text,jsonb) to authenticated;
create or replace function public.yavoi(command text,payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if command='weekly_transfer_destination' then return private.weekly_transfer_destination_v1(payload); end if;
  if command='set_weekly_transfer_destination' then return private.set_weekly_transfer_destination_v1(payload); end if;
  if command='weekly_commission_dashboard' then return private.weekly_commission_dashboard_v4(payload); end if;
  return private.yavoi_before_liquidation_controls(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
