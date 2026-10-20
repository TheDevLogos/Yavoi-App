-- A tax-reference rate must not be accepted from an unverified default.
-- Operations verifies entity and RFC before the driver can accept this policy.

update private.driver_liquidation_policy_settings
set policy_version='2026-10-weekly-liquidation-v3',updated_at=now()
where id and policy_version='2026-10-weekly-liquidation-v2';

create or replace function private.driver_liquidation_policy_status_v1(target uuid default auth.uid())
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'version',s.policy_version,'effective_at',s.effective_at,
    'accepted',a.accepted_at is not null and f.verified_by is not null and f.verified_at is not null
      and coalesce(a.terms_snapshot->>'entity','individual')=coalesce(f.entity,'individual')
      and coalesce((a.terms_snapshot->>'rfc_provided')::boolean,false)=coalesce(f.rfc_provided,false),
    'accepted_at',case when a.accepted_at is not null and f.verified_by is not null and f.verified_at is not null
      and coalesce(a.terms_snapshot->>'entity','individual')=coalesce(f.entity,'individual')
      and coalesce((a.terms_snapshot->>'rfc_provided')::boolean,false)=coalesce(f.rfc_provided,false)
      then a.accepted_at else null end,
    'required',timezone('America/Chihuahua',now())::date >= timezone('America/Chihuahua',s.effective_at)::date - 6,
    'commission_bps',coalesce((select commission_bps from private.commission_policy_at_v1(s.effective_at)),1500),
    'entity',coalesce(f.entity,'individual'),'rfc_provided',coalesce(f.rfc_provided,false),
    'fiscal_profile_verified',f.verified_by is not null and f.verified_at is not null,
    'rfc_isr_reference_bps',s.rfc_isr_reference_bps,
    'no_rfc_isr_reference_bps',s.no_rfc_isr_reference_bps,
    'company_rfc_isr_reference_bps',s.company_rfc_isr_reference_bps,
    'company_no_rfc_isr_reference_bps',s.company_no_rfc_isr_reference_bps,
    'rfc_vat_fraction_bps',s.rfc_vat_fraction_bps,
    'no_rfc_vat_fraction_bps',s.no_rfc_vat_fraction_bps,
    'state_reference_bps',s.state_reference_bps
  )
  from private.driver_liquidation_policy_settings s
  left join private.driver_liquidation_policy_acceptances a
    on a.driver_id=target and a.policy_version=s.policy_version
  left join public.driver_fiscal_profiles f on f.driver_id=target
  where s.id
$$;
revoke all on function private.driver_liquidation_policy_status_v1(uuid) from public, anon, authenticated;

create or replace function private.accept_driver_liquidation_terms_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.profiles; f public.driver_fiscal_profiles;
  policy private.driver_liquidation_policy_settings; entity_value text; rfc_value boolean;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.role<>'driver' or p.suspended then
    raise exception 'Acceso de conductor requerido.' using errcode='42501';
  end if;
  select * into policy from private.driver_liquidation_policy_settings where id;
  if not found or payload->>'policy_version' is distinct from policy.policy_version
    or coalesce((payload->>'accepted')::boolean,false) is not true then
    raise exception 'Lee y acepta el esquema semanal vigente para continuar.';
  end if;
  select * into f from public.driver_fiscal_profiles where driver_id=uid;
  if f.driver_id is null or f.verified_by is null or f.verified_at is null then
    raise exception 'Operaciones debe validar primero tu tipo fiscal y RFC para mostrarte el cálculo correcto.';
  end if;
  entity_value:=case when f.entity='company' then 'company' else 'individual' end;
  rfc_value:=coalesce(f.rfc_provided,false);
  insert into private.driver_liquidation_policy_acceptances(driver_id,policy_version,terms_snapshot)
  values(uid,policy.policy_version,jsonb_build_object(
    'effective_at',policy.effective_at,
    'commission_bps',coalesce((select commission_bps from private.commission_policy_at_v1(policy.effective_at)),1500),
    'entity',entity_value,'rfc_provided',rfc_value,
    'rfc_isr_reference_bps',policy.rfc_isr_reference_bps,
    'no_rfc_isr_reference_bps',policy.no_rfc_isr_reference_bps,
    'company_rfc_isr_reference_bps',policy.company_rfc_isr_reference_bps,
    'company_no_rfc_isr_reference_bps',policy.company_no_rfc_isr_reference_bps,
    'rfc_vat_fraction_bps',policy.rfc_vat_fraction_bps,
    'no_rfc_vat_fraction_bps',policy.no_rfc_vat_fraction_bps,
    'state_reference_bps',policy.state_reference_bps,'settlement_day','Monday'))
  on conflict(driver_id,policy_version) do update set
    accepted_at=excluded.accepted_at,terms_snapshot=excluded.terms_snapshot;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'driver_weekly_liquidation_terms_accepted',uid,jsonb_build_object(
    'version',policy.policy_version,'effective_at',policy.effective_at,'entity',entity_value,'rfc_provided',rfc_value));
  return jsonb_build_object('ok',true,'policy',private.driver_liquidation_policy_status_v1(uid));
end $$;
revoke all on function private.accept_driver_liquidation_terms_v1(jsonb) from public, anon;
grant execute on function private.accept_driver_liquidation_terms_v1(jsonb) to authenticated;

create or replace function private.driver_permission_status_v1(target uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.drivers; p public.profiles; policy private.driver_liquidation_policy_settings;
begin
  select * into p from public.profiles where id=target;
  select * into d from public.drivers where id=target;
  if p.id is null or p.role is distinct from 'driver' or d.id is null then
    return jsonb_build_object('allowed',false,'code','not_driver','label','Perfil de conductor no disponible','message','Tu perfil de conductor no está disponible. Contacta a Operaciones.');
  end if;
  if p.suspended then
    return jsonb_build_object('allowed',false,'code','profile_suspended','label','Cuenta suspendida por Operaciones','message','Tu cuenta está suspendida por Operaciones. Revisa tu Bandeja de Entrada.');
  end if;
  if not d.approved then
    return jsonb_build_object('allowed',false,'code','dossier_pending','label','Expediente pendiente de autorización','message','Tu expediente debe estar aprobado por Operaciones antes de que puedas conducir.');
  end if;
  if coalesce(d.license_expires<current_date,true) then
    return jsonb_build_object('allowed',false,'code','license_expired','label','Licencia vencida o pendiente','message','Actualiza tu licencia vigente en Mi perfil para solicitar la autorización.');
  end if;
  if coalesce(d.insurance_expires<current_date,true) then
    return jsonb_build_object('allowed',false,'code','insurance_expired','label','Seguro vencido o pendiente','message','Actualiza tu póliza vigente en Mi perfil para solicitar la autorización.');
  end if;
  select * into policy from private.driver_liquidation_policy_settings where id;
  if policy.id and now()>=policy.effective_at
    and not coalesce((private.driver_liquidation_policy_status_v1(target)->>'accepted')::boolean,false) then
    return jsonb_build_object('allowed',false,'code','liquidation_terms','label','Esquema semanal pendiente de validación','message','Operaciones debe validar tu tipo fiscal y RFC; después podrás aceptar el desglose semanal en Mi perfil.');
  end if;
  if d.billing_mode is distinct from 'commission' then
    return jsonb_build_object('allowed',false,'code','commission_mode_pending','label','Comisión semanal pendiente de Operaciones','message','Operaciones debe activar la modalidad de comisión semanal antes de que puedas conectarte.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='overdue') then
    return jsonb_build_object('allowed',false,'code','settlement_overdue','label','Liquidación semanal vencida','message','Tu liquidación semanal está vencida. Sube el comprobante desde Mi perfil para que Operaciones lo concilie.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='submitted') then
    return jsonb_build_object('allowed',false,'code','settlement_review','label','Comprobante en revisión','message','Operaciones está validando tu comprobante. Recibirás el resultado en tu Bandeja de Entrada.');
  end if;
  if not d.account_active then
    return jsonb_build_object('allowed',false,'code','operations_authorization','label','Permiso pendiente de Operaciones','message','Operaciones debe autorizar tu permiso para conducir. Revisa tu Bandeja de Entrada.');
  end if;
  return jsonb_build_object('allowed',true,'code','authorized','label','Permiso para conducir activo','message','Tu expediente, liquidación y autorización están vigentes.');
end $$;
revoke all on function private.driver_permission_status_v1(uuid) from public,anon,authenticated;

create or replace function private.require_driver_liquidation_eligibility_v1()
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); policy private.driver_liquidation_policy_settings; driver_row public.drivers;
begin
  if uid is null then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  select * into policy from private.driver_liquidation_policy_settings where id;
  if policy.id and now()>=policy.effective_at
    and not coalesce((private.driver_liquidation_policy_status_v1(uid)->>'accepted')::boolean,false) then
    raise exception 'Operaciones debe validar tu tipo fiscal y RFC, y tú aceptar el esquema semanal, antes de conectarte.';
  end if;
  select * into driver_row from public.drivers where id=uid;
  if not found or driver_row.billing_mode is distinct from 'commission' then
    raise exception 'Operaciones debe activar tu modalidad de comisión semanal antes de conectarte.';
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=uid and s.status='submitted') then
    raise exception 'Tu comprobante está en revisión. Operaciones debe conciliarlo antes de que vuelvas a conectarte.';
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=uid and s.status='overdue') then
    raise exception 'Tu liquidación semanal está vencida. Operaciones debe conciliarla antes de que vuelvas a conectarte.';
  end if;
end $$;
revoke all on function private.require_driver_liquidation_eligibility_v1() from public,anon;
grant execute on function private.require_driver_liquidation_eligibility_v1() to authenticated;
