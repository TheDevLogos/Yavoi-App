-- Weekly driver notices keep the commercial retention separate from taxes.
-- Company taxes are provisions for Yavoi! and are never added to a driver's
-- amount due unless Operations later creates a lawful, signed tax mandate.
alter table private.commission_policy_settings
  add column if not exists transfer_bank text,
  add column if not exists transfer_clabe text check (transfer_clabe is null or transfer_clabe ~ '^[0-9]{18}$');

create or replace function private.driver_weekly_settlement_messages_v1()
returns jsonb language sql security definer set search_path='' as $$
  with notices as (
    select n.id,n.driver_id,n.settlement_id,n.due_at,n.created_at,n.read_at,
      s.week_start,s.gross_cash_cents,s.commission_due_cents,s.status,
      p.transfer_bank,p.transfer_clabe
    from public.driver_settlement_notices n
    join public.driver_commission_settlements s on s.id=n.settlement_id
    cross join private.commission_policy_settings p
    where n.driver_id=auth.uid()
      and s.status in ('pending','submitted','overdue')
  ), totals as (
    select n.id,
      count(t.id)::integer as trip_count,
      coalesce(sum(coalesce(t.total_cents,t.fare_cents,0)),0)::bigint as gross_cents,
      coalesce(sum(coalesce(nullif(t.financial_breakdown->>'fare_vat_cents','')::bigint,0)),0)::bigint as fare_vat_cents,
      coalesce(sum(coalesce(nullif(t.financial_breakdown->>'isr_withheld_cents','')::bigint,0)),0)::bigint as isr_reference_cents,
      coalesce(sum(coalesce(nullif(t.financial_breakdown->>'vat_withheld_cents','')::bigint,0)),0)::bigint as vat_reference_cents,
      coalesce(sum(coalesce(nullif(t.financial_breakdown->>'state_contribution_cents','')::bigint,0)),0)::bigint as state_contribution_cents
    from notices n
    left join public.trips t on t.driver_id=n.driver_id
      and t.status='completed' and t.payment_method='cash'
      and date_trunc('week',timezone('America/Chihuahua',t.completed_at))::date=n.week_start
    group by n.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',n.id,
    'title','Resumen semanal y aviso de pago',
    'category','payment',
    'created_at',n.created_at,
    'ends_at',n.due_at,
    'is_read',n.read_at is not null,
    'due_at',n.due_at,
    'settlement_id',n.settlement_id,
    'amount_due_cents',n.commission_due_cents,
    'trip_count',coalesce(t.trip_count,0),
    'average_trip_cents',case when coalesce(t.trip_count,0)>0 then round(t.gross_cents::numeric/t.trip_count)::bigint else 0 end,
    'fare_vat_cents',coalesce(t.fare_vat_cents,0),
    'isr_reference_cents',coalesce(t.isr_reference_cents,0),
    'vat_reference_cents',coalesce(t.vat_reference_cents,0),
    'state_contribution_cents',coalesce(t.state_contribution_cents,0),
    'body',format(
      'Semana %s: %s viaje(s) en efectivo por $%s; promedio $%s por viaje.\n\nIVA incluido en las tarifas: $%s. ISR de referencia: $%s. IVA de referencia: $%s. Aportación estatal Yavoi! 1.5%%: $%s.\n\nIMPORTE ÚNICO A LIQUIDAR: retención comercial Yavoi! 15%% $%s. Los conceptos fiscales se muestran para transparencia y no se suman a tu pago semanal.\n\nTransferencia: %s. CLABE: %s. Vence %s.',
      to_char(n.week_start,'DD/MM/YYYY'),coalesce(t.trip_count,0),to_char(n.gross_cash_cents::numeric/100,'FM999999990.00'),
      to_char((case when coalesce(t.trip_count,0)>0 then round(t.gross_cents::numeric/t.trip_count)::bigint else 0 end)::numeric/100,'FM999999990.00'),
      to_char(coalesce(t.fare_vat_cents,0)::numeric/100,'FM999999990.00'),
      to_char(coalesce(t.isr_reference_cents,0)::numeric/100,'FM999999990.00'),
      to_char(coalesce(t.vat_reference_cents,0)::numeric/100,'FM999999990.00'),
      to_char(coalesce(t.state_contribution_cents,0)::numeric/100,'FM999999990.00'),
      to_char(n.commission_due_cents::numeric/100,'FM999999990.00'),
      coalesce(nullif(n.transfer_bank,''),'Banco pendiente de registrar por Operaciones'),
      coalesce(nullif(n.transfer_clabe,''),'Pendiente de registrar por Operaciones'),
      to_char(timezone('America/Chihuahua',n.due_at),'DD/MM/YYYY HH24:MI')
    )
  ) order by n.created_at desc),'[]'::jsonb)
  from notices n join totals t on t.id=n.id
$$;
revoke all on function private.driver_weekly_settlement_messages_v1() from public,anon;
grant execute on function private.driver_weekly_settlement_messages_v1() to authenticated;

create or replace function private.driver_commission_notices_v1()
returns jsonb language sql security definer set search_path='' as $$
  select private.driver_weekly_settlement_messages_v1()
$$;
revoke all on function private.driver_commission_notices_v1() from public,anon;
grant execute on function private.driver_commission_notices_v1() to authenticated;

create or replace function private.driver_weekly_settlement_message_read_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare notice_id uuid:=nullif(payload->>'announcement_id','')::uuid;
begin
  if auth.uid() is null or notice_id is null then raise exception 'Mensaje no disponible.' using errcode='42501'; end if;
  update public.driver_settlement_notices
  set read_at=coalesce(read_at,now())
  where id=notice_id and driver_id=auth.uid();
  if not found then raise exception 'El mensaje no está dirigido a tu perfil.' using errcode='42501'; end if;
  return jsonb_build_object('ok',true,'announcement_id',notice_id);
end $$;
revoke all on function private.driver_weekly_settlement_message_read_v1(jsonb) from public,anon;
grant execute on function private.driver_weekly_settlement_message_read_v1(jsonb) to authenticated;

alter function public.yavoi_inbox(text,jsonb) rename to yavoi_inbox_before_weekly_settlement_messages;
create function public.yavoi_inbox(command text,payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; role_value text;
begin
  if command='read' and exists(select 1 from public.driver_settlement_notices n where n.id=nullif(payload->>'announcement_id','')::uuid) then
    return private.driver_weekly_settlement_message_read_v1(payload);
  end if;
  result:=public.yavoi_inbox_before_weekly_settlement_messages(command,payload);
  if command='list' and auth.uid() is not null then
    select role into role_value from public.profiles where id=auth.uid();
    if role_value='driver' then
      result:=result||jsonb_build_object(
        'messages',coalesce(result->'messages','[]'::jsonb)||private.driver_weekly_settlement_messages_v1()
      );
    end if;
  end if;
  return result;
end $$;
revoke all on function public.yavoi_inbox(text,jsonb) from public,anon;
grant execute on function public.yavoi_inbox(text,jsonb) to authenticated;
