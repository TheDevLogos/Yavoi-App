-- A commercial percentage is a prospective tariff rule.  Each completed trip
-- keeps its stored commission, so a policy change never rewrites a live week.
create table if not exists private.commission_policy_revisions (
  effective_at timestamptz primary key,
  commission_bps integer not null check (commission_bps in (500,1000,1500,2000,2500,3000)),
  settlement_days integer not null default 2 check (settlement_days between 1 and 7),
  note text not null check (char_length(note) between 5 and 500),
  scheduled_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
revoke all on private.commission_policy_revisions from public, anon, authenticated;

insert into private.commission_policy_revisions(effective_at,commission_bps,settlement_days,note)
select effective_at,commission_bps,settlement_days,'Configuración inicial de comisión semanal.'
from private.commission_policy_settings where id
on conflict (effective_at) do nothing;

create or replace function private.next_weekly_cutoff_v1()
returns timestamptz language sql stable set search_path='' as $$
  select ((date_trunc('week', timezone('America/Chihuahua', now()))::date + 7)::timestamp
    at time zone 'America/Chihuahua')
$$;
revoke all on function private.next_weekly_cutoff_v1() from public,anon,authenticated;

create or replace function private.commission_policy_at_v1(at_time timestamptz default now())
returns private.commission_policy_revisions language sql stable security definer set search_path='' as $$
  select * from private.commission_policy_revisions
  where effective_at <= at_time
  order by effective_at desc limit 1
$$;
revoke all on function private.commission_policy_at_v1(timestamptz) from public,anon,authenticated;

create or replace function private.driver_commission_bps(target_driver uuid,method text)
returns integer language sql stable security definer set search_path='' as $$
  select case
    when d.billing_mode='commission' then coalesce((select commission_bps from private.commission_policy_at_v1(now())),1500)
    when method='cash' then d.cash_commission_bps
    else d.card_commission_bps
  end
  from public.drivers d where d.id=target_driver
$$;
revoke all on function private.driver_commission_bps(uuid,text) from public,anon,authenticated;

create or replace function private.reconcile_weekly_commission_settlements(reference_at timestamptz default now())
returns integer language plpgsql security definer set search_path='' as $$
declare policy private.commission_policy_revisions;
declare changed integer:=0;
begin
  select * into policy from private.commission_policy_at_v1(reference_at);
  if not found then raise exception 'No existe una política comercial activa.'; end if;
  with eligible as (
    select t.driver_id,
      date_trunc('week', timezone('America/Chihuahua', t.completed_at))::date as week_start,
      sum(coalesce(t.total_cents,t.fare_cents,0))::integer as gross_cash_cents,
      sum(coalesce(t.commission_cents,0))::integer as commission_due_cents
    from public.trips t
    where t.status='completed' and t.payment_method='cash' and t.billing_mode='commission'
      and t.driver_id is not null
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
      gross_cash_cents=excluded.gross_cash_cents,commission_due_cents=excluded.commission_due_cents,
      due_at=excluded.due_at,updated_at=now()
    where public.driver_commission_settlements.status in ('pending','submitted','overdue')
    returning id,driver_id,due_at,commission_due_cents,week_start
  )
  insert into public.driver_settlement_notices(driver_id,settlement_id,title,body,due_at)
  select u.driver_id,u.id,'Tu corte semanal está listo',
    format('Operaciones registró tu corte del %s. Comisión comercial pendiente: $%s. Liquida a más tardar el %s para mantener tu autorización de conducción.',
      to_char(u.week_start,'DD/MM/YYYY'),to_char(u.commission_due_cents::numeric/100,'FM999999990.00'),
      to_char(timezone('America/Chihuahua',u.due_at),'DD/MM/YYYY HH24:MI')),u.due_at
  from upserted u on conflict (settlement_id) do update set body=excluded.body,due_at=excluded.due_at;
  get diagnostics changed = row_count;
  update public.driver_commission_settlements set status='overdue',updated_at=now()
  where status in ('pending','submitted') and due_at < reference_at;
  update public.drivers d set account_active=false,online=false,updated_at=now(),
    account_access_note='Acceso suspendido por corte semanal vencido.'
  where d.account_active and exists(select 1 from public.driver_commission_settlements s where s.driver_id=d.id and s.status='overdue');
  return changed;
end $$;
revoke all on function private.reconcile_weekly_commission_settlements(timestamptz) from public,anon;

create or replace function private.set_weekly_commission_policy_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); rate integer:=nullif(payload->>'commission_bps','')::integer;
  reason text:=left(trim(coalesce(payload->>'note','')),500); starts_at timestamptz:=private.next_weekly_cutoff_v1();
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos para programar la comisión.' using errcode='42501';
  end if;
  if rate not in (500,1000,1500,2000,2500,3000) then raise exception 'Selecciona 5, 10, 15, 20, 25 o 30 por ciento.'; end if;
  if char_length(reason)<5 then raise exception 'Registra el motivo del cambio.'; end if;
  insert into private.commission_policy_revisions(effective_at,commission_bps,settlement_days,note,scheduled_by)
  values(starts_at,rate,2,reason,uid)
  on conflict (effective_at) do update set commission_bps=excluded.commission_bps,note=excluded.note,scheduled_by=excluded.scheduled_by,created_at=now();
  insert into public.audit_log(actor_id,action,detail) values
    (uid,'weekly_commission_policy_scheduled',jsonb_build_object('commission_bps',rate,'effective_at',starts_at,'note',reason));
  return jsonb_build_object('ok',true,'commission_bps',rate,'effective_at',starts_at);
end $$;
revoke all on function private.set_weekly_commission_policy_v1(jsonb) from public,anon;
grant execute on function private.set_weekly_commission_policy_v1(jsonb) to authenticated;

create or replace function private.weekly_commission_dashboard_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare period text:=coalesce(payload->>'period','week'); anchor date:=coalesce(nullif(payload->>'anchor','')::date,timezone('America/Chihuahua',now())::date);
  start_day date; end_day date; policy private.commission_policy_revisions; upcoming private.commission_policy_revisions;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'Acceso de Operaciones requerido.' using errcode='42501'; end if;
  if period not in ('day','week','month') then raise exception 'Periodo inválido.'; end if;
  start_day:=case period when 'day' then anchor when 'week' then date_trunc('week',anchor)::date else date_trunc('month',anchor)::date end;
  end_day:=case period when 'day' then start_day+1 when 'week' then start_day+7 else (start_day+interval '1 month')::date end;
  select * into policy from private.commission_policy_at_v1(now());
  select * into upcoming from private.commission_policy_revisions where effective_at>now() order by effective_at limit 1;
  perform private.reconcile_weekly_commission_settlements(now());
  return jsonb_build_object(
    'period',period,'start_day',start_day,'end_day',end_day,
    'policy',jsonb_build_object('commission_bps',policy.commission_bps,'effective_at',policy.effective_at,'settlement_days',policy.settlement_days,
      'pending_commission_bps',upcoming.commission_bps,'pending_effective_at',upcoming.effective_at),
    'summary',(select jsonb_build_object(
      'trips',count(*),'gross_cash_cents',coalesce(sum(coalesce(t.total_cents,t.fare_cents,0)),0),
      'commission_due_cents',coalesce(sum(coalesce(t.commission_cents,0)),0),
      'commission_base_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'commission_base_cents','')::bigint,0)),0),
      'commission_vat_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'commission_vat_cents','')::bigint,0)),0),
      'taxable_base_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'taxable_base_cents','')::bigint,0)),0),
      'fare_vat_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'fare_vat_cents','')::bigint,0)),0),
      'isr_reference_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'isr_withheld_cents','')::bigint,0)),0),
      'vat_reference_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'vat_withheld_cents','')::bigint,0)),0),
      'state_contribution_cents',coalesce(sum(coalesce(nullif(t.financial_breakdown->>'state_contribution_cents','')::bigint,0)),0))
      from public.trips t where t.status='completed' and t.payment_method='cash' and t.completed_at>=start_day and t.completed_at<end_day),
    'series',(select coalesce(jsonb_agg(to_jsonb(a) order by a.day),'[]'::jsonb) from (
      select g.day::date as day,coalesce(sum(t.commission_cents),0)::bigint as commission_due_cents
      from generate_series(start_day::timestamp,(end_day-1)::timestamp,interval '1 day') g(day)
      left join public.trips t on timezone('America/Chihuahua',t.completed_at)::date=g.day::date and t.status='completed' and t.payment_method='cash'
      group by g.day) a),
    'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.commission_due_cents desc),'[]'::jsonb) from (
      select d.id,d.account_active,p.full_name,count(t.id)::integer trips,
        coalesce(sum(coalesce(t.total_cents,t.fare_cents,0)),0)::bigint gross_cash_cents,coalesce(sum(t.commission_cents),0)::bigint commission_due_cents,
        coalesce(sum(nullif(t.financial_breakdown->>'taxable_base_cents','')::bigint),0)::bigint taxable_base_cents,
        coalesce(sum(nullif(t.financial_breakdown->>'fare_vat_cents','')::bigint),0)::bigint fare_vat_cents,
        coalesce(sum(nullif(t.financial_breakdown->>'commission_vat_cents','')::bigint),0)::bigint commission_vat_cents,
        coalesce(sum(nullif(t.financial_breakdown->>'isr_withheld_cents','')::bigint),0)::bigint isr_reference_cents,
        coalesce(sum(nullif(t.financial_breakdown->>'vat_withheld_cents','')::bigint),0)::bigint vat_reference_cents,
        coalesce(sum(nullif(t.financial_breakdown->>'state_contribution_cents','')::bigint),0)::bigint state_contribution_cents
      from public.drivers d join public.profiles p on p.id=d.id
      left join public.trips t on t.driver_id=d.id and t.status='completed' and t.payment_method='cash' and t.completed_at>=start_day and t.completed_at<end_day
      group by d.id,d.account_active,p.full_name) x),
    'settlements',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'driver_id',s.driver_id,'driver_name',p.full_name,'week_start',s.week_start,'due_at',s.due_at,'gross_cash_cents',s.gross_cash_cents,'commission_due_cents',s.commission_due_cents,'status',s.status,'note',s.note,'account_active',d.account_active) order by s.due_at),'[]'::jsonb)
      from public.driver_commission_settlements s join public.profiles p on p.id=s.driver_id join public.drivers d on d.id=s.driver_id)
  );
end $$;
revoke all on function private.weekly_commission_dashboard_v1(jsonb) from public,anon;
grant execute on function private.weekly_commission_dashboard_v1(jsonb) to authenticated;

alter function public.yavoi(text,jsonb) rename to yavoi_before_scheduled_commission_policy;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  case command
    when 'weekly_commission_dashboard' then return private.weekly_commission_dashboard_v1(payload);
    when 'set_weekly_commission_policy' then return private.set_weekly_commission_policy_v1(payload);
    else return public.yavoi_before_scheduled_commission_policy(command,payload);
  end case;
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
