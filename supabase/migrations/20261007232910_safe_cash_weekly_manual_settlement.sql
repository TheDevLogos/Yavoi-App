-- Launch guard: cash-only rides, no driver-initiated withdrawals, and manual
-- weekly positive-balance transfers recorded by Operations.
update private.app_settings
set mercado_pago_enabled = false, updated_at = now()
where id = true;

update public.finance_settings
set payouts_enabled = false, payout_provider = 'manual', updated_at = now()
where id = true;

update public.driver_fiscal_profiles
set weekly_auto = false, updated_at = now()
where weekly_auto;

-- The driver balance stays an internal accounting ledger. Only weekly income
-- summaries and the driver's own payout details are returned to that driver.
create or replace function private.finance_wallet_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare data jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='driver' and not suspended) then
   raise exception 'Acceso de conductor requerido.' using errcode='42501';
 end if;
 data:=private.finance_wallet_data(auth.uid(),nullif(payload->>'week_start','')::date);
 return jsonb_build_object(
   'week_start',data->'week_start',
   'days',data->'days',
   'week_net_cents',data->'week_net_cents',
   'week_cash_cents',data->'week_cash_cents',
   'profile',coalesce(data->'profile','{}'::jsonb)
 );
end $$;

-- The dashboard also embeds a wallet payload. Route it through the same
-- sanitized RPC so the internal balance cannot leak through this path.
create or replace function private.finance_dashboard_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb:=private.dashboard_v18(payload);
begin
 if exists(select 1 from public.profiles where id=auth.uid() and role='driver') then
   result:=result||jsonb_build_object('finance_wallet',private.finance_wallet_v1('{}'::jsonb));
 end if;
 return result;
end $$;

-- Hard server-side stop for self-service withdrawals, including calls made
-- directly to the RPC instead of through the application interface.
create or replace function private.finance_withdraw_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='driver' and not suspended) then
   raise exception 'Acceso de conductor requerido.' using errcode='42501';
 end if;
 raise exception 'Las solicitudes de retiro están pausadas. Operaciones concilia semanalmente los importes.';
end $$;

-- Keep other finance settings editable, but do not permit Operations to
-- switch self-service or automated payouts back on through the regular UI.
create or replace function private.finance_settings_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare levels jsonb:=coalesce(payload->'level_discounts','{}'); v jsonb;
begin
 perform private.finance_admin();
 if length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Registra el motivo del cambio.'; end if;
 if coalesce((payload->>'dynamic_max_bps')::integer,15000) not between 10000 and 15000 or jsonb_typeof(levels)<>'object' then raise exception 'Configuración inválida.'; end if;
 for v in select value from jsonb_each(levels) loop
   if v::text::integer not between 0 and 5000 then raise exception 'Beneficio por nivel fuera de rango.'; end if;
 end loop;
 update public.finance_settings
 set dynamic_enabled=coalesce((payload->>'dynamic_enabled')::boolean,false),
     dynamic_max_bps=coalesce((payload->>'dynamic_max_bps')::integer,15000),
     level_discounts=levels,payouts_enabled=false,updated_at=now()
 where id;
 insert into public.audit_log(actor_id,action,detail)
 values(auth.uid(),'finance_settings_changed',payload||jsonb_build_object('payouts_enabled',false,'payout_provider','manual'));
 return jsonb_build_object('ok',true,'payouts_enabled',false,'payout_provider','manual');
end $$;

create table public.driver_manual_settlements (
 id uuid primary key default gen_random_uuid(),
 driver_id uuid not null references public.drivers(id),
 week_start date not null,
 amount_cents bigint not null check(amount_cents > 0),
 destination jsonb not null,
 transfer_reference text not null,
 note text not null,
 settled_by uuid not null references auth.users(id),
 settled_at timestamptz not null default now(),
 created_at timestamptz not null default now(),
 unique(driver_id,week_start),
 unique(transfer_reference)
);
alter table public.driver_manual_settlements enable row level security;
revoke all on public.driver_manual_settlements from public,anon,authenticated;

create function public.finance_manual_settlement(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 target uuid:=(payload->>'driver_id')::uuid;
 period date:=(payload->>'week_start')::date;
 amount bigint:=(payload->>'amount_cents')::bigint;
 reference_value text:=trim(coalesce(payload->>'transfer_reference',''));
 note_value text:=trim(coalesce(payload->>'note',''));
 profile public.driver_fiscal_profiles;
 entry public.driver_manual_settlements;
 available bigint;
 detail jsonb;
begin
 if auth.uid() is null then raise exception 'Inicio de sesión requerido.' using errcode='42501'; end if;
 perform private.finance_admin();
 if target is null or period is null or amount is null or amount<100 or length(reference_value)<5 or length(reference_value)>160 or length(note_value)<5 or length(note_value)>1000 then
   raise exception 'Indica conductor, semana, importe, referencia bancaria y nota de conciliación válidos.';
 end if;
 perform 1 from public.drivers where id=target for update;
 if not found then raise exception 'Conductor no encontrado.'; end if;
 select * into profile from public.driver_fiscal_profiles where driver_id=target for update;
 if not found or profile.payout_verified_at is null or length(coalesce(profile.payout_destination,''))=0 then
   raise exception 'La cuenta bancaria del conductor debe estar verificada por Operaciones antes de pagar.';
 end if;
 detail:=private.finance_wallet_data(target);
 available:=coalesce((detail->>'available_cents')::bigint,0);
 if amount>available then raise exception 'El importe supera los ingresos conciliados disponibles para liquidar.'; end if;
 insert into public.driver_manual_settlements(driver_id,week_start,amount_cents,destination,transfer_reference,note,settled_by)
 values(target,period,amount,jsonb_build_object('kind',profile.payout_kind,'destination',profile.payout_destination,'holder',profile.payout_holder),reference_value,note_value,auth.uid())
 returning * into entry;
 perform private.finance_post(target,null,null,'manual-settlement:'||entry.id,'withdrawal',-amount,
   jsonb_build_object('manual_settlement_id',entry.id,'week_start',period,'reference',reference_value,'note',note_value));
 insert into public.audit_log(actor_id,action,target_id,detail)
 values(auth.uid(),'driver_manual_weekly_settlement',entry.id,jsonb_build_object('driver_id',target,'week_start',period,'amount_cents',amount,'reference',reference_value,'destination',entry.destination,'note',note_value));
 return to_jsonb(entry);
end $$;
revoke all on function public.finance_manual_settlement(jsonb) from public,anon;
grant execute on function public.finance_manual_settlement(jsonb) to authenticated;

create function public.finance_manual_settlements()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Inicio de sesión requerido.' using errcode='42501'; end if;
 perform private.finance_admin();
 return coalesce((
   select jsonb_agg(to_jsonb(x) order by x.settled_at desc)
   from (
     select s.*,p.full_name driver_name
     from public.driver_manual_settlements s
     join public.profiles p on p.id=s.driver_id
     order by s.settled_at desc limit 100
   ) x
 ),'[]'::jsonb);
end $$;
revoke all on function public.finance_manual_settlements() from public,anon;
grant execute on function public.finance_manual_settlements() to authenticated;
