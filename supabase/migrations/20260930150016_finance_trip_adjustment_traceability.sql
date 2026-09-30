-- A wallet adjustment is a correction to a completed service, never a new
-- passenger charge. Link it to the service and retain its documentary basis.
alter function private.finance_funding_v1(jsonb) rename to finance_funding_before_trip_adjustment;

create function private.finance_funding_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  target uuid:=(payload->>'driver_id')::uuid;
  amount bigint:=(payload->>'amount_cents')::bigint;
  key_value uuid:=(payload->>'request_key')::uuid;
  kind_value text:=payload->>'kind';
  note_value text:=trim(coalesce(payload->>'note',''));
  reference_value text:=trim(coalesce(payload->>'reference',''));
  trip_value public.trips;
  entry_value public.driver_wallet_entries;
begin
  if kind_value<>'adjustment' then
    return private.finance_funding_before_trip_adjustment(payload);
  end if;

  perform private.finance_admin();
  if amount<1 or amount>100000000 or key_value is null or length(note_value)<5 or length(reference_value)<5 then
    raise exception 'Indica importe, referencia comprobable y motivo.';
  end if;
  select * into entry_value from public.driver_wallet_entries where entry_key='adjustment:'||key_value;
  if found then return jsonb_build_object('ok',true,'entry',to_jsonb(entry_value)); end if;
  perform 1 from public.drivers where id=target for update;
  if not found then raise exception 'Conductor no encontrado.'; end if;
  select * into trip_value from public.trips
  where id=nullif(payload->>'trip_id','')::uuid and driver_id=target and status in ('completed','cancelled')
  for update;
  if not found then
    raise exception 'El ajuste debe corresponder a un viaje finalizado de este conductor.';
  end if;
  if exists(select 1 from public.driver_wallet_entries where driver_id=target and kind='adjustment' and detail->>'reference'=reference_value) then
    raise exception 'Ya existe un ajuste con esta referencia para el conductor.';
  end if;

  perform private.finance_post(target,trip_value.id,null,'adjustment:'||key_value,'adjustment',amount,
    jsonb_build_object('reference',reference_value,'note',note_value,'trip_status',trip_value.status,'recorded_by',auth.uid()));
  select * into entry_value from public.driver_wallet_entries where entry_key='adjustment:'||key_value;
  insert into public.audit_log(actor_id,action,target_id,detail) values(
    auth.uid(),'wallet_trip_adjustment_recorded',trip_value.id,
    jsonb_build_object('driver_id',target,'amount_cents',amount,'reference',reference_value,'note',note_value,'entry_id',entry_value.id)
  );
  return jsonb_build_object('ok',true,'entry',to_jsonb(entry_value));
end $$;

revoke all on function private.finance_funding_before_trip_adjustment(jsonb),private.finance_funding_v1(jsonb) from public,anon,authenticated;
grant execute on function private.finance_funding_v1(jsonb) to authenticated;

-- Statements retain the reason alongside the immutable reference and trip.
create or replace function private.finance_statement_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid:=coalesce(nullif(payload->>'driver_id','')::uuid,auth.uid()); month_value date:=date_trunc('month',coalesce(nullif(payload->>'month','')::date,timezone('America/Chihuahua',now())::date))::date;
begin
  if auth.uid() is null or not (private.is_admin() or (target=auth.uid() and exists(select 1 from public.profiles where id=target and role='driver' and not suspended))) then raise exception 'Acceso de titular u Operaciones requerido.' using errcode='42501'; end if;
  return jsonb_build_object('month',month_value,'driver_id',target,'entries',coalesce((select jsonb_agg(jsonb_build_object(
    'date',e.created_at,'kind',e.kind,'amount_cents',e.amount_cents,'trip_id',e.trip_id,
    'reference',e.detail->>'reference','note',e.detail->>'note'
  ) order by e.created_at) from public.driver_wallet_entries e where e.driver_id=target and e.created_at>=month_value::timestamp at time zone 'America/Chihuahua' and e.created_at<(month_value+interval '1 month') at time zone 'America/Chihuahua'),'[]'));
end $$;
revoke all on function private.finance_statement_v1(jsonb) from public,anon;
grant execute on function private.finance_statement_v1(jsonb) to authenticated;
