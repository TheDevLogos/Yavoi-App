-- Chihuahua's 1.5% mobility-fund contribution is conditional on the network
-- transport authorization and agreement. Keep an audited effective history;
-- never add it to driver settlements by default or retroactively.

create table if not exists private.driver_state_contribution_policy_history (
  id bigint generated always as identity primary key,
  effective_at timestamptz not null unique,
  enabled boolean not null,
  authorization_reference text not null default '',
  note text not null default '',
  actor_id uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (not enabled or char_length(trim(authorization_reference)) >= 5)
);
revoke all on private.driver_state_contribution_policy_history from public,anon,authenticated;
alter table private.driver_state_contribution_policy_history enable row level security;

insert into private.driver_state_contribution_policy_history(effective_at,enabled,note)
select effective_at-interval '1 second',false,'Aportación estatal desactivada hasta validar autorización y convenio de Yavoi!.'
from private.driver_liquidation_policy_settings where id
on conflict(effective_at) do nothing;

create or replace function private.state_contribution_policy_at_v1(moment timestamptz default now())
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce((
    select jsonb_build_object(
      'enabled',h.enabled,
      'effective_at',h.effective_at,
      'authorization_reference',h.authorization_reference,
      'rate_bps',case when h.enabled then s.state_reference_bps else 0 end
    )
    from private.driver_state_contribution_policy_history h
    cross join private.driver_liquidation_policy_settings s
    where s.id and h.effective_at<=moment
    order by h.effective_at desc,h.id desc limit 1
  ),jsonb_build_object('enabled',false,'effective_at',null,'authorization_reference','','rate_bps',0))
$$;
revoke all on function private.state_contribution_policy_at_v1(timestamptz) from public,anon,authenticated;

create or replace function private.trip_liquidation_components_v1(item public.trips)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare fare_gross bigint; taxable bigint; vat bigint; isr_bps integer; vat_fraction_bps integer;
  state_cents bigint; state_policy jsonb; state_enabled boolean; state_rate integer;
  rfc_value boolean; entity_value text; commission_value bigint; isr_value bigint; vat_value bigint;
  policy private.driver_liquidation_policy_settings;
begin
  select * into policy from private.driver_liquidation_policy_settings where id;
  fare_gross:=coalesce(nullif(item.financial_breakdown->>'passenger_total_cents','')::bigint-coalesce(item.tip_cents,0),
    nullif(item.financial_breakdown->>'fare_cents','')::bigint,greatest(0,item.fare_cents-item.reward_discount_cents));
  taxable:=coalesce(nullif(item.financial_breakdown->>'taxable_base_cents','')::bigint,round(fare_gross/1.16)::bigint);
  vat:=coalesce(nullif(item.financial_breakdown->>'fare_vat_cents','')::bigint,greatest(0,fare_gross-taxable));
  rfc_value:=coalesce((item.financial_terms->>'rfc_provided')::boolean,false);
  entity_value:=case when item.financial_terms->>'entity'='company' then 'company' else 'individual' end;
  isr_bps:=case
    when entity_value='company' and rfc_value then policy.company_rfc_isr_reference_bps
    when entity_value='company' then policy.company_no_rfc_isr_reference_bps
    else policy.rfc_isr_reference_bps
  end;
  vat_fraction_bps:=case when rfc_value then policy.rfc_vat_fraction_bps else policy.no_rfc_vat_fraction_bps end;
  state_policy:=private.state_contribution_policy_at_v1(coalesce(item.completed_at,now()));
  state_enabled:=coalesce((state_policy->>'enabled')::boolean,false);
  state_rate:=coalesce((state_policy->>'rate_bps')::integer,0);
  state_cents:=case when state_enabled then round(fare_gross*state_rate/10000.0)::bigint else 0 end;
  commission_value:=greatest(0,coalesce(nullif(item.financial_breakdown->>'commission_cents','')::bigint,item.commission_cents,0));
  isr_value:=case when item.payment_method='cash' then round(taxable*isr_bps/10000.0)::bigint else 0 end;
  vat_value:=case when item.payment_method<>'cash' then 0 else round(vat*vat_fraction_bps/10000.0)::bigint end;
  return jsonb_build_object(
    'trip_id',item.id,'completed_at',item.completed_at,'payment_method',item.payment_method,
    'origin',item.origin,'destination',item.destination,'taxpayer_entity',entity_value,
    'commission_rate_bps',coalesce(item.commission_bps_applied,1500),
    'fare_gross_cents',fare_gross,'taxable_base_cents',taxable,'fare_vat_cents',vat,
    'isr_rate_bps',isr_bps,'vat_fraction_bps',vat_fraction_bps,'state_rate_bps',state_rate,
    'isr_reference_cents',isr_value,'vat_reference_cents',vat_value,
    'state_contribution_cents',state_cents,'state_contribution_enabled',state_enabled,
    'state_authorization_reference',coalesce(state_policy->>'authorization_reference',''),
    'commission_cents',commission_value,
    'settlement_due_cents',commission_value+isr_value+vat_value+state_cents,
    'rfc_provided',rfc_value,
    'calculation_note','ISR/IVA son referencias contractuales, no retenciones. La aportación estatal sólo se incluye con autorización y convenio vigentes; este corte no acredita entero fiscal.'
  );
end $$;
revoke all on function private.trip_liquidation_components_v1(public.trips) from public,anon,authenticated;

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
    'state_reference_bps',s.state_reference_bps,
    'state_reference_enabled',coalesce((private.state_contribution_policy_at_v1(now())->>'enabled')::boolean,false),
    'state_reference_effective_at',private.state_contribution_policy_at_v1(now())->>'effective_at'
  )
  from private.driver_liquidation_policy_settings s
  left join private.driver_liquidation_policy_acceptances a on a.driver_id=target and a.policy_version=s.policy_version
  left join public.driver_fiscal_profiles f on f.driver_id=target
  where s.id
$$;
revoke all on function private.driver_liquidation_policy_status_v1(uuid) from public,anon,authenticated;

create or replace function private.state_contribution_policy_v1(payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_policy jsonb; next_policy jsonb;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  current_policy:=private.state_contribution_policy_at_v1(now());
  select jsonb_build_object('enabled',h.enabled,'effective_at',h.effective_at,
      'authorization_reference',h.authorization_reference,'rate_bps',case when h.enabled then s.state_reference_bps else 0 end)
    into next_policy from private.driver_state_contribution_policy_history h
    cross join private.driver_liquidation_policy_settings s
    where s.id and h.effective_at>now() and h.actor_id is not null
    order by h.effective_at,h.id limit 1;
  return current_policy||jsonb_build_object('next_change',next_policy);
end $$;
revoke all on function private.state_contribution_policy_v1(jsonb) from public,anon;
grant execute on function private.state_contribution_policy_v1(jsonb) to authenticated;

create or replace function private.set_state_contribution_policy_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare enabled_value boolean:=coalesce((payload->>'enabled')::boolean,false);
  reference_value text:=left(trim(coalesce(payload->>'authorization_reference','')),240);
  note_value text:=left(trim(coalesce(payload->>'note','')),500);
  current_policy jsonb; latest_policy jsonb; policy private.driver_liquidation_policy_settings;
  effective_value timestamptz; result jsonb; title_value text; body_value text;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  if char_length(note_value)<5 then raise exception 'Registra el motivo del cambio.' using errcode='22023'; end if;
  if enabled_value and char_length(reference_value)<5 then
    raise exception 'Para activar el 1.5%% estatal, registra el folio de autorización y convenio vigentes.' using errcode='22023';
  end if;
  current_policy:=private.state_contribution_policy_at_v1(now());
  select jsonb_build_object('enabled',h.enabled,'authorization_reference',h.authorization_reference,'effective_at',h.effective_at)
    into latest_policy from private.driver_state_contribution_policy_history h
    order by h.effective_at desc,h.id desc limit 1;
  if coalesce((latest_policy->>'enabled')::boolean,false)=enabled_value
    and coalesce(latest_policy->>'authorization_reference','')=(case when enabled_value then reference_value else '' end) then
    return current_policy;
  end if;
  select * into policy from private.driver_liquidation_policy_settings where id for update;
  effective_value:=greatest(clock_timestamp(),policy.effective_at,coalesce((latest_policy->>'effective_at')::timestamptz+interval '1 second',policy.effective_at));
  insert into private.driver_state_contribution_policy_history(effective_at,enabled,authorization_reference,note,actor_id)
  values(effective_value,enabled_value,case when enabled_value then reference_value else '' end,note_value,auth.uid());
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(auth.uid(),'state_contribution_policy_changed',null,jsonb_build_object(
    'enabled',enabled_value,'effective_at',effective_value,'authorization_reference',case when enabled_value then reference_value else '' end,'note',note_value));
  title_value:=case when enabled_value then 'Aportación estatal aplicable a viajes futuros' else 'Aportación estatal desactivada para viajes futuros' end;
  body_value:=case when enabled_value
    then format('Operaciones validó el folio de autorización/convenio %s. La referencia del 1.5%% se incluirá sólo en viajes completados desde %s; los viajes anteriores conservan su cálculo. No es una retención al conductor.',reference_value,to_char(timezone('America/Chihuahua',effective_value),'DD/MM/YYYY HH24:MI'))
    else format('Operaciones desactivó la referencia estatal. No se incluirá en viajes completados desde %s; los viajes anteriores conservan su cálculo.',to_char(timezone('America/Chihuahua',effective_value),'DD/MM/YYYY HH24:MI')) end;
  insert into public.driver_operating_notices(driver_id,kind,title,body)
  select a.driver_id,'state_contribution_policy',title_value,body_value
  from private.driver_liquidation_policy_acceptances a
  where a.policy_version=policy.policy_version;
  result:=private.state_contribution_policy_at_v1(now());
  return result||jsonb_build_object('saved',true,'effective_at',effective_value);
end $$;
revoke all on function private.set_state_contribution_policy_v1(jsonb) from public,anon;
grant execute on function private.set_state_contribution_policy_v1(jsonb) to authenticated;

-- Keep the monthly Finance dashboard consistent with weekly settlements: the
-- state reference is zero unless an authorized period covers each trip.
do $$ begin
  if to_regprocedure('private.finance_operations_before_state_policy_v1(jsonb)') is null
    and to_regprocedure('private.finance_operations_v1(jsonb)') is not null then
    alter function private.finance_operations_v1(jsonb) rename to finance_operations_before_state_policy_v1;
  end if;
end $$;
revoke all on function private.finance_operations_before_state_policy_v1(jsonb) from public,anon;
grant execute on function private.finance_operations_before_state_policy_v1(jsonb) to authenticated;

create or replace function private.finance_operations_v1(payload jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; month_value date:=coalesce(nullif(payload->>'month','')::date,date_trunc('month',timezone('America/Chihuahua',now()))::date);
  state_total bigint; state_policy jsonb;
begin
  result:=private.finance_operations_before_state_policy_v1(payload);
  select coalesce(sum((parts->>'state_contribution_cents')::bigint),0) into state_total
  from public.trips t cross join lateral private.trip_liquidation_components_v1(t) parts
  where t.status='completed' and t.payment_status<>'refunded'
    and timezone('America/Chihuahua',t.completed_at)::date>=month_value
    and timezone('America/Chihuahua',t.completed_at)::date<month_value+interval '1 month';
  state_policy:=private.state_contribution_policy_at_v1(now());
  return result||jsonb_build_object('state_summary',state_total,'state_contribution_policy',state_policy);
end $$;
revoke all on function private.finance_operations_v1(jsonb) from public,anon;
grant execute on function private.finance_operations_v1(jsonb) to authenticated;

alter table public.driver_operating_notices drop constraint if exists driver_operating_notices_kind_check;
alter table public.driver_operating_notices add constraint driver_operating_notices_kind_check
  check (kind in ('permit_authorized','permit_suspended','reconciliation_received','state_contribution_policy'));

do $$ begin
  if to_regprocedure('private.yavoi_before_state_contribution(text,jsonb)') is null then
    if to_regprocedure('private.yavoi(text,jsonb)') is null and to_regprocedure('public.yavoi(text,jsonb)') is not null then
      alter function public.yavoi(text,jsonb) rename to yavoi_before_state_contribution;
      alter function public.yavoi_before_state_contribution(text,jsonb) set schema private;
    end if;
  end if;
end $$;
revoke all on function private.yavoi_before_state_contribution(text,jsonb) from public,anon;
grant execute on function private.yavoi_before_state_contribution(text,jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if command='state_contribution_policy' then return private.state_contribution_policy_v1(payload); end if;
  if command='set_state_contribution_policy' then return private.set_state_contribution_policy_v1(payload); end if;
  return private.yavoi_before_state_contribution(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
