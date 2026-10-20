-- Weekly driver settlements are a contractual payment to Yavoi!, not tax
-- withholding. Each item is kept distinct from amounts actually remitted to
-- SAT or Chihuahua. New items apply only to trips completed after the driver
-- accepts this version of the policy.

create table if not exists private.driver_liquidation_policy_settings (
  id boolean primary key default true check (id),
  policy_version text not null,
  effective_at timestamptz not null,
  state_reference_bps integer not null default 150 check (state_reference_bps between 0 and 1000),
  rfc_isr_reference_bps integer not null default 210 check (rfc_isr_reference_bps between 0 and 10000),
  no_rfc_isr_reference_bps integer not null default 210 check (no_rfc_isr_reference_bps between 0 and 10000),
  rfc_vat_fraction_bps integer not null default 5000 check (rfc_vat_fraction_bps between 0 and 10000),
  no_rfc_vat_fraction_bps integer not null default 10000 check (no_rfc_vat_fraction_bps between 0 and 10000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
revoke all on private.driver_liquidation_policy_settings from public, anon, authenticated;
alter table private.driver_liquidation_policy_settings enable row level security;

insert into private.driver_liquidation_policy_settings(id,policy_version,effective_at)
select true,'2026-10-weekly-liquidation-v1',
  ((date_trunc('week',timezone('America/Chihuahua',now()))::date + 7)::timestamp at time zone 'America/Chihuahua')
on conflict (id) do nothing;

create table if not exists private.driver_liquidation_policy_acceptances (
  driver_id uuid not null references public.profiles(id) on delete restrict,
  policy_version text not null,
  accepted_at timestamptz not null default now(),
  terms_snapshot jsonb not null default '{}'::jsonb,
  primary key(driver_id,policy_version)
);
revoke all on private.driver_liquidation_policy_acceptances from public, anon, authenticated;
alter table private.driver_liquidation_policy_acceptances enable row level security;
create index if not exists driver_liquidation_policy_acceptances_accepted_idx
  on private.driver_liquidation_policy_acceptances(accepted_at desc);

alter table public.driver_commission_settlements
  add column if not exists isr_reference_cents integer not null default 0 check (isr_reference_cents >= 0),
  add column if not exists vat_reference_cents integer not null default 0 check (vat_reference_cents >= 0),
  add column if not exists state_contribution_cents integer not null default 0 check (state_contribution_cents >= 0),
  add column if not exists settlement_due_cents integer not null default 0 check (settlement_due_cents >= 0),
  add column if not exists trip_count integer not null default 0 check (trip_count >= 0),
  add column if not exists liquidation_policy_version text not null default 'commission-only-legacy',
  add column if not exists liquidation_breakdown jsonb not null default '{}'::jsonb;

-- Existing cuts keep their historical amount and are never retroactively
-- increased by the new tax-reference components.
update public.driver_commission_settlements
set settlement_due_cents=commission_due_cents
where settlement_due_cents=0 and commission_due_cents>0
  and liquidation_policy_version='commission-only-legacy';

alter table public.driver_settlement_receipts
  add column if not exists breakdown jsonb not null default '{}'::jsonb;

create or replace function private.trip_liquidation_components_v1(item public.trips)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare fare_gross bigint; taxable bigint; vat bigint; isr_bps integer; vat_fraction_bps integer; state_cents bigint;
  rfc_value boolean; commission_value bigint; isr_value bigint; vat_value bigint; policy private.driver_liquidation_policy_settings;
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
  -- Use this policy's reference rate, not a rate left by an older fare rule.
  isr_bps:=case when rfc_value then policy.rfc_isr_reference_bps else policy.no_rfc_isr_reference_bps end;
  vat_fraction_bps:=case when rfc_value then policy.rfc_vat_fraction_bps else policy.no_rfc_vat_fraction_bps end;
  state_cents:=coalesce(nullif(item.financial_breakdown->>'state_contribution_cents','')::bigint,
    round(fare_gross*policy.state_reference_bps/10000.0)::bigint);
  commission_value:=greatest(0,coalesce(nullif(item.financial_breakdown->>'commission_cents','')::bigint,item.commission_cents,0));
  isr_value:=case when item.payment_method='cash' then round(taxable*isr_bps/10000.0)::bigint else 0 end;
  vat_value:=case when item.payment_method<>'cash' then 0 else
    round(vat*vat_fraction_bps/10000.0)::bigint end;
  return jsonb_build_object(
    'trip_id',item.id,'completed_at',item.completed_at,'payment_method',item.payment_method,
    'origin',item.origin,'destination',item.destination,'commission_rate_bps',coalesce(item.commission_bps_applied,1500),
    'fare_gross_cents',fare_gross,'taxable_base_cents',taxable,'fare_vat_cents',vat,
    'isr_rate_bps',isr_bps,'vat_fraction_bps',vat_fraction_bps,'state_rate_bps',policy.state_reference_bps,
    'isr_reference_cents',isr_value,
    'vat_reference_cents',vat_value,'state_contribution_cents',state_cents,
    'commission_cents',commission_value,
    'settlement_due_cents',commission_value+isr_value+vat_value+state_cents,
    'rfc_provided',rfc_value,
    'calculation_note','Importes de referencia incluidos en la liquidación contractual; no acreditan retención ni entero fiscal.'
  );
end $$;
revoke all on function private.trip_liquidation_components_v1(public.trips) from public, anon, authenticated;

-- Legacy cuts remain commission-only; enrich their history without adding
-- reference components retroactively.
with legacy_trip_rows as (
  select s.id as settlement_id,
    private.trip_liquidation_components_v1(t) || jsonb_build_object(
      'accepted_for_new_components',false,
      'isr_reference_cents',0,'vat_reference_cents',0,'state_contribution_cents',0,
      'settlement_due_cents',(private.trip_liquidation_components_v1(t)->>'commission_cents')::bigint
    ) as detail
  from public.driver_commission_settlements s
  join public.trips t on t.driver_id=s.driver_id and t.status='completed'
    and t.payment_method='cash' and t.billing_mode='commission'
    and date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date=s.week_start
  where s.liquidation_policy_version='commission-only-legacy' and s.liquidation_breakdown='{}'::jsonb
), legacy_totals as (
  select settlement_id,count(*)::integer as trip_count,
    jsonb_agg(detail order by detail->>'completed_at',detail->>'trip_id') as breakdown
  from legacy_trip_rows group by settlement_id
)
update public.driver_commission_settlements s set
  trip_count=legacy_totals.trip_count,
  liquidation_breakdown=legacy_totals.breakdown,
  settlement_due_cents=s.commission_due_cents
from legacy_totals where s.id=legacy_totals.settlement_id;

-- Old inbox wording must not call a contractual service charge a withholding.
update public.driver_settlement_notices
set body=replace(body,'Retención comercial pendiente','Comisión comercial pendiente')
where body ilike '%Retención comercial pendiente%';

create or replace function private.driver_liquidation_policy_status_v1(target uuid default auth.uid())
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'version',s.policy_version,'effective_at',s.effective_at,
    'accepted',a.accepted_at is not null,'accepted_at',a.accepted_at,
    'required',timezone('America/Chihuahua',now())::date >= timezone('America/Chihuahua',s.effective_at)::date - 6,
    'commission_bps',coalesce((select commission_bps from private.commission_policy_at_v1(s.effective_at)),1500),
    'rfc_provided',coalesce((select f.rfc_provided from public.driver_fiscal_profiles f where f.driver_id=target),false),
    'rfc_isr_reference_bps',s.rfc_isr_reference_bps,
    'no_rfc_isr_reference_bps',s.no_rfc_isr_reference_bps,
    'rfc_vat_fraction_bps',s.rfc_vat_fraction_bps,
    'no_rfc_vat_fraction_bps',s.no_rfc_vat_fraction_bps,
    'state_reference_bps',s.state_reference_bps
  )
  from private.driver_liquidation_policy_settings s
  left join private.driver_liquidation_policy_acceptances a
    on a.driver_id=target and a.policy_version=s.policy_version
  where s.id
$$;
revoke all on function private.driver_liquidation_policy_status_v1(uuid) from public, anon, authenticated;

create or replace function private.driver_permission_status_v1(target uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.drivers; p public.profiles; policy private.driver_liquidation_policy_settings;
begin
  select * into p from public.profiles where id=target;
  select * into d from public.drivers where id=target;
  if not found or p.role<>'driver' then
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
  if policy.id and now()>=policy.effective_at and not exists(
    select 1 from private.driver_liquidation_policy_acceptances a where a.driver_id=target and a.policy_version=policy.policy_version
  ) then
    return jsonb_build_object('allowed',false,'code','liquidation_terms','label','Acepta el esquema semanal','message','Lee y acepta en Mi perfil el desglose y los conceptos del corte semanal antes de conectarte.');
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

create or replace function private.accept_driver_liquidation_terms_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.profiles; policy private.driver_liquidation_policy_settings;
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
  insert into private.driver_liquidation_policy_acceptances(driver_id,policy_version,terms_snapshot)
  values(uid,policy.policy_version,jsonb_build_object(
    'effective_at',policy.effective_at,'commission_bps',coalesce((select commission_bps from private.commission_policy_at_v1(policy.effective_at)),1500),
    'rfc_isr_reference_bps',policy.rfc_isr_reference_bps,'no_rfc_isr_reference_bps',policy.no_rfc_isr_reference_bps,
    'rfc_vat_fraction_bps',policy.rfc_vat_fraction_bps,'no_rfc_vat_fraction_bps',policy.no_rfc_vat_fraction_bps,
    'state_reference_bps',policy.state_reference_bps,'settlement_day','Monday'))
  on conflict(driver_id,policy_version) do nothing;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'driver_weekly_liquidation_terms_accepted',uid,jsonb_build_object('version',policy.policy_version,'effective_at',policy.effective_at));
  return jsonb_build_object('ok',true,'policy',private.driver_liquidation_policy_status_v1(uid));
end $$;
revoke all on function private.accept_driver_liquidation_terms_v1(jsonb) from public, anon;
grant execute on function private.accept_driver_liquidation_terms_v1(jsonb) to authenticated;

create or replace function private.require_driver_liquidation_eligibility_v1()
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); policy private.driver_liquidation_policy_settings; driver_row public.drivers;
begin
  if uid is null then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  select * into policy from private.driver_liquidation_policy_settings where id;
  if policy.id and now()>=policy.effective_at and not exists(
    select 1 from private.driver_liquidation_policy_acceptances a
    where a.driver_id=uid and a.policy_version=policy.policy_version
  ) then raise exception 'Acepta el esquema de liquidación semanal en Mi perfil antes de conectarte.'; end if;
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

create or replace function private.submit_driver_settlement_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.profiles; settlement public.driver_commission_settlements; path_value text;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501'; end if;
  select * into settlement from public.driver_commission_settlements where id=(payload->>'settlement_id')::uuid and driver_id=uid for update;
  if not found or settlement.status in ('paid','waived') then raise exception 'Esta liquidación ya no admite comprobante.'; end if;
  path_value:=nullif(trim(payload->>'proof_path'),'');
  if path_value is null or not exists(select 1 from storage.objects where bucket_id='yavoi-payment-proofs' and name=path_value and (storage.foldername(name))[1]=uid::text) then
    raise exception 'Carga un comprobante válido de tu propio perfil.';
  end if;
  update public.driver_commission_settlements set proof_path=path_value,status='submitted',submitted_at=now(),updated_at=now()
    where id=settlement.id returning * into settlement;
  update public.drivers set account_active=false,online=false,
    account_access_note='Comprobante de liquidación en revisión por Operaciones.',updated_at=now()
    where id=uid;
  insert into public.driver_operating_notices(driver_id,kind,title,body)
  values(uid,'reconciliation_received','Comprobante enviado a Operaciones','Tu comprobante fue enviado para conciliación. Tu cuenta queda pausada hasta que Operaciones valide el importe y reactive el permiso.');
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'weekly_liquidation_proof_submitted',uid,jsonb_build_object('settlement_id',settlement.id,'proof_path',path_value,'settlement_due_cents',settlement.settlement_due_cents));
  return jsonb_build_object('ok',true,'settlement',to_jsonb(settlement));
end $$;
revoke all on function private.submit_driver_settlement_v1(jsonb) from public,anon;
grant execute on function private.submit_driver_settlement_v1(jsonb) to authenticated;

create or replace function private.reconcile_weekly_commission_settlements(reference_at timestamptz default now())
returns integer language plpgsql security definer set search_path='' as $$
declare commission_policy private.commission_policy_settings; liquidation_policy private.driver_liquidation_policy_settings;
  changed integer:=0; local_reference timestamp;
begin
  local_reference:=timezone('America/Chihuahua',reference_at);
  if extract(isodow from local_reference)=1 and local_reference::time<time '07:00' then return 0; end if;
  select * into commission_policy from private.commission_policy_settings where id for share;
  select * into liquidation_policy from private.driver_liquidation_policy_settings where id for share;
  with trip_facts as (
    select t.driver_id,
      date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date as week_start,
      t.completed_at,t.id,t.total_cents,t.fare_cents,
      private.trip_liquidation_components_v1(t) as parts,
      a.accepted_at as accepted_at,
      a.policy_version as accepted_version,
      coalesce(t.total_cents,t.fare_cents,0)::bigint as gross_cents
    from public.trips t
    left join private.driver_liquidation_policy_acceptances a
      on a.driver_id=t.driver_id and a.policy_version=liquidation_policy.policy_version
    where t.status='completed' and t.payment_status<>'refunded' and t.payment_method='cash' and t.billing_mode='commission'
    and t.driver_id is not null and t.completed_at>=commission_policy.effective_at
      and date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date
        < date_trunc('week',timezone('America/Chihuahua',reference_at))::date
  ), eligible as (
    select driver_id,week_start,
      sum(gross_cents)::integer as gross_cash_cents,
      sum((parts->>'commission_cents')::bigint)::integer as commission_due_cents,
      sum(case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at
        then (parts->>'isr_reference_cents')::bigint else 0 end)::integer as isr_reference_cents,
      sum(case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at
        then (parts->>'vat_reference_cents')::bigint else 0 end)::integer as vat_reference_cents,
      sum(case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at
        then (parts->>'state_contribution_cents')::bigint else 0 end)::integer as state_contribution_cents,
      count(*)::integer as trip_count,
      coalesce(max(accepted_version) filter(where accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at),'commission-only-legacy') as liquidation_policy_version,
      jsonb_agg(parts || jsonb_build_object(
        'accepted_for_new_components',accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at,
        'isr_reference_cents',case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'isr_reference_cents')::bigint else 0 end,
        'vat_reference_cents',case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'vat_reference_cents')::bigint else 0 end,
        'state_contribution_cents',case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at then (parts->>'state_contribution_cents')::bigint else 0 end,
        'settlement_due_cents',(parts->>'commission_cents')::bigint+case when accepted_at is not null and completed_at>=liquidation_policy.effective_at and completed_at>=accepted_at
          then (parts->>'isr_reference_cents')::bigint+(parts->>'vat_reference_cents')::bigint+(parts->>'state_contribution_cents')::bigint else 0 end
      ) order by completed_at,id) as liquidation_breakdown
    from trip_facts
    group by driver_id,week_start
  ), upserted as (
    insert into public.driver_commission_settlements(
      driver_id,week_start,due_at,gross_cash_cents,commission_due_cents,
      isr_reference_cents,vat_reference_cents,state_contribution_cents,
      settlement_due_cents,trip_count,liquidation_policy_version,liquidation_breakdown,status,note
    )
    select driver_id,week_start,
      (((week_start+7)::timestamp+time '23:59:59') at time zone 'America/Chihuahua'),
      gross_cash_cents,commission_due_cents,isr_reference_cents,vat_reference_cents,state_contribution_cents,
      commission_due_cents+isr_reference_cents+vat_reference_cents+state_contribution_cents,
      trip_count,liquidation_policy_version,liquidation_breakdown,'pending','Liquidación semanal Yavoi!'
    from eligible
    on conflict(driver_id,week_start) do update set
      gross_cash_cents=excluded.gross_cash_cents,
      commission_due_cents=excluded.commission_due_cents,
      isr_reference_cents=excluded.isr_reference_cents,
      vat_reference_cents=excluded.vat_reference_cents,
      state_contribution_cents=excluded.state_contribution_cents,
      settlement_due_cents=excluded.settlement_due_cents,
      trip_count=excluded.trip_count,
      liquidation_policy_version=excluded.liquidation_policy_version,
      liquidation_breakdown=excluded.liquidation_breakdown,
      due_at=excluded.due_at,updated_at=now()
    where public.driver_commission_settlements.status in ('pending','submitted','overdue')
    returning id,driver_id,due_at,week_start,commission_due_cents,isr_reference_cents,vat_reference_cents,state_contribution_cents,settlement_due_cents
  )
  insert into public.driver_settlement_notices(driver_id,settlement_id,title,body,due_at)
  select u.driver_id,u.id,'Tu liquidación semanal está lista',
    format('Operaciones registró %s viaje(s) en efectivo de la semana del %s. Comisión Yavoi!: $%s; ISR de referencia: $%s; IVA de referencia: $%s; aportación estatal de referencia 1.5%% sujeta a autorización/convenio: $%s. TOTAL A TRANSFERIR A YAVOI!: $%s. Vence el lunes %s. Los importes de referencia no acreditan retención ni pago de impuestos a la autoridad.',
      (select e.trip_count from eligible e where e.driver_id=u.driver_id and e.week_start=u.week_start),
      to_char(u.week_start,'DD/MM/YYYY'),
      to_char(u.commission_due_cents::numeric/100,'FM999999990.00'),
      to_char(u.isr_reference_cents::numeric/100,'FM999999990.00'),
      to_char(u.vat_reference_cents::numeric/100,'FM999999990.00'),
      to_char(u.state_contribution_cents::numeric/100,'FM999999990.00'),
      to_char(u.settlement_due_cents::numeric/100,'FM999999990.00'),
      to_char(timezone('America/Chihuahua',u.due_at),'DD/MM/YYYY')),
    u.due_at
  from upserted u
  on conflict(settlement_id) do update set body=excluded.body,due_at=excluded.due_at;
  get diagnostics changed=row_count;

  update public.driver_commission_settlements set status='overdue',updated_at=now()
  where status='pending' and due_at<reference_at;
  update public.drivers d set account_active=false,online=false,updated_at=now(),
    account_access_note='Liquidación semanal vencida; comprobante pendiente.'
  where d.account_active and exists(select 1 from public.driver_commission_settlements s where s.driver_id=d.id and s.status='overdue');
  -- New trips must not remain online under the legacy fixed-fee model after
  -- the accepted weekly-commission policy becomes effective.
  update public.drivers set online=false,updated_at=now(),
    account_access_note='Operaciones debe activar la modalidad de comisión semanal vigente.'
  where online and billing_mode is distinct from 'commission'
    and now()>=liquidation_policy.effective_at;
  return changed;
end $$;
revoke all on function private.reconcile_weekly_commission_settlements(timestamptz) from public,anon,authenticated;

-- Check every 15 minutes so overdue cuts suspend access promptly. The
-- function waits until Monday 07:00 Chihuahua time before creating the cut.
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    if exists(select 1 from cron.job where jobname='yavoi-weekly-liquidation') then
      perform cron.unschedule('yavoi-weekly-liquidation');
    end if;
    perform cron.schedule('yavoi-weekly-liquidation','*/15 * * * *',
      'select private.reconcile_weekly_commission_settlements(now())');
  end if;
end $$;

create or replace function private.review_weekly_commission_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); settlement public.driver_commission_settlements; received integer; note_value text;
  allow_driver boolean:=coalesce((payload->>'authorize_driver')::boolean,true); d public.drivers; p public.profiles; receipt_no text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  select * into settlement from public.driver_commission_settlements where id=(payload->>'settlement_id')::uuid for update;
  if not found then raise exception 'Liquidación no encontrada.'; end if;
  received:=coalesce((payload->>'received_cents')::integer,-1);
  note_value:=left(trim(coalesce(payload->>'note','')),500);
  if settlement.status<>'submitted' or settlement.proof_path is null then raise exception 'El conductor debe enviar el comprobante antes de conciliar.'; end if;
  if received<>settlement.settlement_due_cents then raise exception 'El importe recibido debe coincidir exactamente con el total de la liquidación.'; end if;
  if char_length(note_value)<5 then raise exception 'Registra la referencia de conciliación.'; end if;
  update public.driver_commission_settlements set status='paid',verified_by=uid,verified_at=now(),note=note_value,updated_at=now()
    where id=settlement.id returning * into settlement;
  receipt_no:=format('YV-LIQ-%s-%s',to_char(now() at time zone 'America/Chihuahua','YYYYMMDD'),upper(left(replace(settlement.id::text,'-',''),6)));
  insert into public.driver_settlement_receipts(settlement_id,driver_id,receipt_number,amount_cents,proof_path,reference,verified_by,verified_at,breakdown)
  values(settlement.id,settlement.driver_id,receipt_no,received,settlement.proof_path,note_value,uid,now(),
    jsonb_build_object('commission_cents',settlement.commission_due_cents,'isr_reference_cents',settlement.isr_reference_cents,
      'vat_reference_cents',settlement.vat_reference_cents,'state_contribution_cents',settlement.state_contribution_cents,
      'settlement_due_cents',settlement.settlement_due_cents,'policy_version',settlement.liquidation_policy_version,
      'trip_count',settlement.trip_count,'per_trip',settlement.liquidation_breakdown));
  select * into d from public.drivers where id=settlement.driver_id for update;
  select * into p from public.profiles where id=settlement.driver_id;
  if allow_driver and not p.suspended and d.approved and d.license_expires>=current_date and d.insurance_expires>=current_date then
    update public.drivers set account_active=true,account_access_authorized_at=now(),account_access_authorized_by=uid,
      account_access_note='Permiso autorizado al conciliar '||receipt_no,updated_at=now() where id=settlement.driver_id;
    insert into public.driver_operating_notices(driver_id,kind,title,body)
    values(settlement.driver_id,'permit_authorized','Permiso para conducir autorizado',format('Operaciones concilió tu liquidación semanal por $%s. Recibo %s. Tu permiso está activo.',to_char(received::numeric/100,'FM999999990.00'),receipt_no));
  else
    insert into public.driver_operating_notices(driver_id,kind,title,body)
    values(settlement.driver_id,'reconciliation_received','Liquidación conciliada',format('Operaciones confirmó tu liquidación por $%s. Recibo %s. Operaciones revisará tu permiso por separado.',to_char(received::numeric/100,'FM999999990.00'),receipt_no));
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail)
  values(uid,'weekly_liquidation_reconciled',settlement.driver_id,jsonb_build_object('settlement_id',settlement.id,'receipt_number',receipt_no,
    'received_cents',received,'commission_cents',settlement.commission_due_cents,'isr_reference_cents',settlement.isr_reference_cents,
    'vat_reference_cents',settlement.vat_reference_cents,'state_contribution_cents',settlement.state_contribution_cents,
    'settlement_due_cents',settlement.settlement_due_cents,'authorize_driver',allow_driver,'note',note_value));
  return jsonb_build_object('ok',true,'settlement',to_jsonb(settlement),'receipt_number',receipt_no,
    'driver_authorized',allow_driver and not p.suspended and d.approved and d.license_expires>=current_date and d.insurance_expires>=current_date);
end $$;
revoke all on function private.review_weekly_commission_v1(jsonb) from public,anon;
grant execute on function private.review_weekly_commission_v1(jsonb) to authenticated;

create or replace function private.driver_settlement_receipts_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'settlement_id',r.settlement_id,'receipt_number',r.receipt_number,
    'amount_cents',r.amount_cents,'reference',r.reference,'verified_at',r.verified_at,'breakdown',r.breakdown)
    order by r.verified_at desc),'[]'::jsonb)
  from public.driver_settlement_receipts r where r.driver_id=auth.uid()
$$;
revoke all on function private.driver_settlement_receipts_v1() from public,anon,authenticated;

create or replace function private.driver_weekly_settlement_messages_v1()
returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',n.id,'title','Resumen de tu liquidación semanal','category','payment','created_at',n.created_at,
    'ends_at',n.due_at,'is_read',n.read_at is not null,'due_at',n.due_at,'settlement_id',n.settlement_id,
    'amount_due_cents',s.settlement_due_cents,'trip_count',s.trip_count,'commission_due_cents',s.commission_due_cents,
    'isr_reference_cents',s.isr_reference_cents,'vat_reference_cents',s.vat_reference_cents,
    'state_contribution_cents',s.state_contribution_cents,'liquidation_breakdown',s.liquidation_breakdown,
    'body',format('Semana %s · %s viajes en efectivo. Comisión de servicio Yavoi!: $%s; ISR de referencia: $%s; IVA de referencia: $%s; aportación estatal de referencia (sujeta a autorización/convenio): $%s. TOTAL DE LIQUIDACIÓN A YAVOI!: $%s, con vencimiento el lunes %s. Los montos de referencia no son retenciones ni comprobantes de pago al SAT o al Estado.',
      to_char(s.week_start,'DD/MM/YYYY'),s.trip_count,to_char(s.commission_due_cents::numeric/100,'FM999999990.00'),
      to_char(s.isr_reference_cents::numeric/100,'FM999999990.00'),to_char(s.vat_reference_cents::numeric/100,'FM999999990.00'),
      to_char(s.state_contribution_cents::numeric/100,'FM999999990.00'),to_char(s.settlement_due_cents::numeric/100,'FM999999990.00'),
      to_char(timezone('America/Chihuahua',s.due_at),'DD/MM/YYYY'))
  ) order by n.created_at desc),'[]'::jsonb)
  from public.driver_settlement_notices n
  join public.driver_commission_settlements s on s.id=n.settlement_id
  where n.driver_id=auth.uid() and s.status in ('pending','submitted','overdue')
$$;
revoke all on function private.driver_weekly_settlement_messages_v1() from public,anon;
grant execute on function private.driver_weekly_settlement_messages_v1() to authenticated;

create or replace function private.weekly_commission_dashboard_v3(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; period_value text:=coalesce(payload->>'period','week'); anchor date:=coalesce(nullif(payload->>'anchor','')::date,timezone('America/Chihuahua',now())::date);
  start_day date; end_day date; tax_summary jsonb; settlements_value jsonb;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501'; end if;
  result:=private.weekly_commission_dashboard_v2(payload);
  start_day:=(result->>'start_day')::date; end_day:=(result->>'end_day')::date;
  select jsonb_build_object(
    'isr_reference_cents',coalesce(sum((parts->>'isr_reference_cents')::bigint),0),
    'vat_reference_cents',coalesce(sum((parts->>'vat_reference_cents')::bigint),0),
    'state_contribution_cents',coalesce(sum((parts->>'state_contribution_cents')::bigint),0),
    'cash_liquidation_component_cents',coalesce(sum(case when a.accepted_at is not null and t.completed_at>=lp.effective_at and t.completed_at>=a.accepted_at then
      (parts->>'isr_reference_cents')::bigint+(parts->>'vat_reference_cents')::bigint+(parts->>'state_contribution_cents')::bigint else 0 end),0),
    'isr_liquidation_reference_cents',coalesce(sum(case when a.accepted_at is not null and t.completed_at>=lp.effective_at and t.completed_at>=a.accepted_at then (parts->>'isr_reference_cents')::bigint else 0 end),0),
    'vat_liquidation_reference_cents',coalesce(sum(case when a.accepted_at is not null and t.completed_at>=lp.effective_at and t.completed_at>=a.accepted_at then (parts->>'vat_reference_cents')::bigint else 0 end),0),
    'state_liquidation_reference_cents',coalesce(sum(case when a.accepted_at is not null and t.completed_at>=lp.effective_at and t.completed_at>=a.accepted_at then (parts->>'state_contribution_cents')::bigint else 0 end),0),
    'pending_liquidation_cents',coalesce((select sum(s.settlement_due_cents) from public.driver_commission_settlements s
      where s.status in ('pending','submitted','overdue') and s.week_start>=start_day and s.week_start<end_day),0),
    'paid_liquidation_cents',coalesce((select sum(s.settlement_due_cents) from public.driver_commission_settlements s
      where s.status='paid' and coalesce(s.verified_at,s.updated_at)>=start_day::timestamp at time zone 'America/Chihuahua'
        and coalesce(s.verified_at,s.updated_at)<end_day::timestamp at time zone 'America/Chihuahua'),0)
  ) into tax_summary
  from public.trips t
  cross join lateral private.trip_liquidation_components_v1(t) parts
  left join private.driver_liquidation_policy_settings lp on lp.id
  left join private.driver_liquidation_policy_acceptances a on a.driver_id=t.driver_id and a.policy_version=lp.policy_version
  where t.status='completed' and t.payment_status<>'refunded' and t.payment_method='cash'
    and t.billing_mode='commission'
    and timezone('America/Chihuahua',t.completed_at)::date>=start_day
    and timezone('America/Chihuahua',t.completed_at)::date<end_day;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'driver_id',s.driver_id,'driver_name',p.full_name,'week_start',s.week_start,'due_at',s.due_at,
    'gross_cash_cents',s.gross_cash_cents,'commission_due_cents',s.commission_due_cents,
    'isr_reference_cents',s.isr_reference_cents,'vat_reference_cents',s.vat_reference_cents,
    'state_contribution_cents',s.state_contribution_cents,'settlement_due_cents',s.settlement_due_cents,
    'trip_count',s.trip_count,'liquidation_policy_version',s.liquidation_policy_version,
    'liquidation_breakdown',s.liquidation_breakdown,'status',s.status,'note',s.note,'proof_path',s.proof_path,
    'submitted_at',s.submitted_at,'account_active',d.account_active
  ) order by s.due_at asc),'[]'::jsonb) into settlements_value
  from public.driver_commission_settlements s join public.profiles p on p.id=s.driver_id join public.drivers d on d.id=s.driver_id;
  result:=jsonb_set(result,'{summary}',coalesce(result->'summary','{}'::jsonb)||tax_summary,true);
  return jsonb_set(result,'{settlements}',settlements_value,true);
end $$;
revoke all on function private.weekly_commission_dashboard_v3(jsonb) from public,anon;
grant execute on function private.weekly_commission_dashboard_v3(jsonb) to authenticated;

create or replace function private.bootstrap_v9(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; uid uuid:=auth.uid(); role_value text;
begin
  result:=private.bootstrap_v8(payload);
  select role into role_value from public.profiles where id=uid;
  if role_value='driver' then
    result:=result||jsonb_build_object(
      'liquidation_terms',private.driver_liquidation_policy_status_v1(uid),
      'driver_permission',private.driver_permission_status_v1(uid),
      'commission_settlements',(select coalesce(jsonb_agg(jsonb_build_object(
        'id',s.id,'driver_id',s.driver_id,'week_start',s.week_start,'due_at',s.due_at,
        'gross_cash_cents',s.gross_cash_cents,'commission_due_cents',s.commission_due_cents,
        'isr_reference_cents',s.isr_reference_cents,'vat_reference_cents',s.vat_reference_cents,
        'state_contribution_cents',s.state_contribution_cents,'settlement_due_cents',s.settlement_due_cents,
        'trip_count',s.trip_count,'liquidation_policy_version',s.liquidation_policy_version,
        'liquidation_breakdown',s.liquidation_breakdown,'status',s.status,'note',s.note,
        'proof_path',s.proof_path,'submitted_at',s.submitted_at
      ) order by s.week_start desc),'[]'::jsonb) from public.driver_commission_settlements s where s.driver_id=uid)
    );
  end if;
  return result;
end $$;
revoke all on function private.bootstrap_v9(jsonb) from public,anon;
grant execute on function private.bootstrap_v9(jsonb) to authenticated;

do $$ begin
  if to_regprocedure('private.yavoi_before_weekly_liquidation(text,jsonb)') is null then
    if to_regprocedure('public.yavoi_before_weekly_liquidation(text,jsonb)') is null
      and to_regprocedure('public.yavoi(text,jsonb)') is not null then
      alter function public.yavoi(text,jsonb) rename to yavoi_before_weekly_liquidation;
    end if;
    if to_regprocedure('public.yavoi_before_weekly_liquidation(text,jsonb)') is not null then
      alter function public.yavoi_before_weekly_liquidation(text,jsonb) set schema private;
    end if;
  end if;
end $$;
revoke all on function private.yavoi_before_weekly_liquidation(text,jsonb) from public,anon;
grant execute on function private.yavoi_before_weekly_liquidation(text,jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if command='accept_driver_liquidation_terms' then return private.accept_driver_liquidation_terms_v1(payload); end if;
  if command='bootstrap' then return private.bootstrap_v9(payload); end if;
  if command='weekly_commission_dashboard' then return private.weekly_commission_dashboard_v3(payload); end if;
  if command='finance_report' then return private.finance_report_v1(payload); end if;
  if command='availability' and coalesce((payload->>'online')::boolean,false) then
    perform private.require_driver_liquidation_eligibility_v1();
  end if;
  if command='submit_driver_settlement' then return private.submit_driver_settlement_v1(payload); end if;
  if command='review_weekly_commission' then return private.review_weekly_commission_v1(payload); end if;
  if command='set_driver_access' then return private.set_driver_access_v3(payload); end if;
  return private.yavoi_before_weekly_liquidation(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

-- Finance keeps received settlements separate from ride revenue. The driver
-- transfer includes commercial commission and accepted tax-reference items;
-- only the official company tax/payment records satisfy the tax liabilities.
do $$ begin
  if to_regprocedure('private.finance_report_before_weekly_liquidation(jsonb)') is null
    and to_regprocedure('private.finance_report_v1(jsonb)') is not null then
    alter function private.finance_report_v1(jsonb) rename to finance_report_before_weekly_liquidation;
  end if;
end $$;

create or replace function private.finance_report_v1(payload jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; meta jsonb; starts_at timestamptz; ends_at timestamptz; target uuid;
  received jsonb; pending jsonb;
begin
  result:=private.finance_report_before_weekly_liquidation(payload);
  meta:=result->'meta';
  starts_at:=(meta->>'starts_on')::date::timestamp at time zone 'America/Chihuahua';
  ends_at:=(meta->>'ends_on')::date::timestamp at time zone 'America/Chihuahua';
  target:=nullif(payload->>'driver_id','')::uuid;
  select jsonb_build_object(
    'received_cents',coalesce(sum(r.amount_cents),0),
    'commission_cents',coalesce(sum(coalesce(nullif(r.breakdown->>'commission_cents','')::bigint,0)),0),
    'isr_reference_cents',coalesce(sum(coalesce(nullif(r.breakdown->>'isr_reference_cents','')::bigint,0)),0),
    'vat_reference_cents',coalesce(sum(coalesce(nullif(r.breakdown->>'vat_reference_cents','')::bigint,0)),0),
    'state_reference_cents',coalesce(sum(coalesce(nullif(r.breakdown->>'state_contribution_cents','')::bigint,0)),0),
    'receipt_count',count(*)
  ) into received
  from public.driver_settlement_receipts r
  where r.verified_at>=starts_at and r.verified_at<ends_at and (target is null or r.driver_id=target);
  select jsonb_build_object(
    'due_cents',coalesce(sum(s.settlement_due_cents),0),'cut_count',count(*)
  ) into pending
  from public.driver_commission_settlements s
  where s.status in ('pending','submitted','overdue') and s.due_at>=starts_at and s.due_at<ends_at
    and (target is null or s.driver_id=target);
  result:=result||jsonb_build_object('weekly_liquidation',coalesce(received,'{}'::jsonb)||coalesce(pending,'{}'::jsonb));
  return result;
end $$;
revoke all on function private.finance_report_v1(jsonb) from public,anon;
grant execute on function private.finance_report_v1(jsonb) to authenticated;
