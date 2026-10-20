-- Keep weekly contractual references aligned with the driver's fiscal entity.
-- These amounts remain contractual items paid to Yavoi!, not tax withholding.

alter table private.driver_liquidation_policy_settings
  add column if not exists company_rfc_isr_reference_bps integer not null default 250
    check (company_rfc_isr_reference_bps between 0 and 10000),
  add column if not exists company_no_rfc_isr_reference_bps integer not null default 2000
    check (company_no_rfc_isr_reference_bps between 0 and 10000);

update private.driver_liquidation_policy_settings
set policy_version='2026-10-weekly-liquidation-v2',
    company_rfc_isr_reference_bps=250,
    company_no_rfc_isr_reference_bps=2000,
    updated_at=now()
where id and policy_version='2026-10-weekly-liquidation-v1';

create or replace function private.trip_liquidation_components_v1(item public.trips)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare fare_gross bigint; taxable bigint; vat bigint; isr_bps integer; vat_fraction_bps integer; state_cents bigint;
  rfc_value boolean; entity_value text; commission_value bigint; isr_value bigint; vat_value bigint;
  policy private.driver_liquidation_policy_settings;
begin
  select * into policy from private.driver_liquidation_policy_settings where id;
  fare_gross:=coalesce(nullif(item.financial_breakdown->>'passenger_total_cents','')::bigint-coalesce(item.tip_cents,0),
    nullif(item.financial_breakdown->>'fare_cents','')::bigint,
    greatest(0,item.fare_cents-item.reward_discount_cents));
  taxable:=coalesce(nullif(item.financial_breakdown->>'taxable_base_cents','')::bigint,
    round(fare_gross/1.16)::bigint);
  vat:=coalesce(nullif(item.financial_breakdown->>'fare_vat_cents','')::bigint,
    greatest(0,fare_gross-taxable));
  rfc_value:=coalesce((item.financial_terms->>'rfc_provided')::boolean,false);
  entity_value:=case when item.financial_terms->>'entity'='company' then 'company' else 'individual' end;
  isr_bps:=case
    when entity_value='company' and rfc_value then policy.company_rfc_isr_reference_bps
    when entity_value='company' then policy.company_no_rfc_isr_reference_bps
    else policy.rfc_isr_reference_bps
  end;
  vat_fraction_bps:=case when rfc_value then policy.rfc_vat_fraction_bps else policy.no_rfc_vat_fraction_bps end;
  state_cents:=coalesce(nullif(item.financial_breakdown->>'state_contribution_cents','')::bigint,
    round(fare_gross*policy.state_reference_bps/10000.0)::bigint);
  commission_value:=greatest(0,coalesce(nullif(item.financial_breakdown->>'commission_cents','')::bigint,item.commission_cents,0));
  isr_value:=case when item.payment_method='cash' then round(taxable*isr_bps/10000.0)::bigint else 0 end;
  vat_value:=case when item.payment_method<>'cash' then 0 else round(vat*vat_fraction_bps/10000.0)::bigint end;
  return jsonb_build_object(
    'trip_id',item.id,'completed_at',item.completed_at,'payment_method',item.payment_method,
    'origin',item.origin,'destination',item.destination,'taxpayer_entity',entity_value,
    'commission_rate_bps',coalesce(item.commission_bps_applied,1500),
    'fare_gross_cents',fare_gross,'taxable_base_cents',taxable,'fare_vat_cents',vat,
    'isr_rate_bps',isr_bps,'vat_fraction_bps',vat_fraction_bps,'state_rate_bps',policy.state_reference_bps,
    'isr_reference_cents',isr_value,'vat_reference_cents',vat_value,
    'state_contribution_cents',state_cents,'commission_cents',commission_value,
    'settlement_due_cents',commission_value+isr_value+vat_value+state_cents,
    'rfc_provided',rfc_value,
    'calculation_note','Importes de referencia incluidos en la liquidación contractual; no acreditan retención ni entero fiscal.'
  );
end $$;
revoke all on function private.trip_liquidation_components_v1(public.trips) from public, anon, authenticated;

create or replace function private.driver_liquidation_policy_status_v1(target uuid default auth.uid())
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'version',s.policy_version,'effective_at',s.effective_at,
    'accepted',a.accepted_at is not null
      and coalesce(a.terms_snapshot->>'entity','individual')=coalesce(f.entity,'individual')
      and coalesce((a.terms_snapshot->>'rfc_provided')::boolean,false)=coalesce(f.rfc_provided,false),
    'accepted_at',case when a.accepted_at is not null
      and coalesce(a.terms_snapshot->>'entity','individual')=coalesce(f.entity,'individual')
      and coalesce((a.terms_snapshot->>'rfc_provided')::boolean,false)=coalesce(f.rfc_provided,false)
      then a.accepted_at else null end,
    'required',timezone('America/Chihuahua',now())::date >= timezone('America/Chihuahua',s.effective_at)::date - 6,
    'commission_bps',coalesce((select commission_bps from private.commission_policy_at_v1(s.effective_at)),1500),
    'entity',coalesce(f.entity,'individual'),
    'rfc_provided',coalesce(f.rfc_provided,false),
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
  policy private.driver_liquidation_policy_settings;
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
  insert into private.driver_liquidation_policy_acceptances(driver_id,policy_version,terms_snapshot)
  values(uid,policy.policy_version,jsonb_build_object(
    'effective_at',policy.effective_at,
    'commission_bps',coalesce((select commission_bps from private.commission_policy_at_v1(policy.effective_at)),1500),
    'entity',case when f.entity='company' then 'company' else 'individual' end,
    'rfc_provided',coalesce(f.rfc_provided,false),
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
    'version',policy.policy_version,'effective_at',policy.effective_at,
    'entity',case when f.entity='company' then 'company' else 'individual' end,
    'rfc_provided',coalesce(f.rfc_provided,false)));
  return jsonb_build_object('ok',true,'policy',private.driver_liquidation_policy_status_v1(uid));
end $$;
revoke all on function private.accept_driver_liquidation_terms_v1(jsonb) from public, anon;
grant execute on function private.accept_driver_liquidation_terms_v1(jsonb) to authenticated;
