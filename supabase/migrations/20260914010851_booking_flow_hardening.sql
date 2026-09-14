-- Keep the fast, one-time booking path independent from optional recurrence fields.
-- Persist the advanced scheduling controls so a restored draft behaves exactly as saved.

create or replace function private.save_ride_draft_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid();
  p public.profiles;
  clean jsonb;
  party integer;
  lat1 float8;
  lng1 float8;
  lat2 float8;
  lng2 float8;
  scheduled_value text:=nullif(payload->>'scheduled_at','');
  cadence_value text:=coalesce(nullif(payload->>'recurrence',''),'once');
  count_value integer:=coalesce(nullif(payload->>'recurrence_count','')::integer,1);
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended or p.role<>'passenger' then
    raise exception 'Acceso de pasajero requerido.' using errcode='42501';
  end if;
  party:=coalesce((payload->>'party_size')::integer,1);
  if party not between 1 and 8 or char_length(coalesce(payload->>'service_notes',''))>500 then
    raise exception 'Borrador inválido.';
  end if;
  if cadence_value not in ('once','daily','weekly','monthly') then
    raise exception 'Frecuencia de programación inválida.';
  end if;
  if scheduled_value is null then
    cadence_value:='once';
    count_value:=1;
  elsif cadence_value='once' then
    count_value:=1;
  elsif count_value<2 or count_value>(case when cadence_value='daily' then 31 else 12 end) then
    raise exception 'Revisa el número de recorridos a programar.';
  end if;
  lat1:=nullif(payload->>'origin_lat','')::float8;
  lng1:=nullif(payload->>'origin_lng','')::float8;
  lat2:=nullif(payload->>'dest_lat','')::float8;
  lng2:=nullif(payload->>'dest_lng','')::float8;
  if (lat1 is not null and not(lat1 between 28.0 and 28.4 and lng1 between -105.7 and -105.2)) or
     (lat2 is not null and not(lat2 between 28.0 and 28.4 and lng2 between -105.7 and -105.2)) then
    raise exception 'Borrador fuera de cobertura.';
  end if;
  clean:=jsonb_strip_nulls(jsonb_build_object(
    'origin',left(coalesce(payload->>'origin',''),200),'origin_lat',lat1,'origin_lng',lng1,
    'destination',left(coalesce(payload->>'destination',''),200),'dest_lat',lat2,'dest_lng',lng2,
    'category',left(coalesce(payload->>'category','basic'),30),'party_size',party,
    'service_notes',left(coalesce(payload->>'service_notes',''),500),
    'women_only',coalesce((payload->>'women_only')::boolean,false),
    'accessible',coalesce((payload->>'accessible')::boolean,false),
    'scheduled_at',scheduled_value,'recurrence',cadence_value,'recurrence_count',count_value
  ));
  insert into public.ride_drafts(passenger_id,payload) values(uid,clean)
  on conflict(passenger_id) do update set payload=excluded.payload,updated_at=now();
  return jsonb_build_object('ok',true,'updated_at',now());
end $$;
revoke all on function private.save_ride_draft_v1(jsonb) from public,anon;
grant execute on function private.save_ride_draft_v1(jsonb) to authenticated;

create or replace function private.request_trip_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  result jsonb;
  t public.trips;
  source_quote public.quotes;
  child_quote public.quotes;
  series public.scheduled_trip_series;
  cadence_value text:=coalesce(nullif(payload->>'recurrence',''),'once');
  count_value integer:=coalesce(nullif(payload->>'recurrence_count','')::integer,1);
  idx integer;
  child public.trips;
  payment_status_value text;
  child_scheduled_at timestamptz;
begin
  if cadence_value not in ('once','daily','weekly','monthly') then
    raise exception 'Frecuencia de programación inválida.';
  end if;
  if cadence_value='once' then
    count_value:=1;
  elsif count_value<2 or count_value>(case when cadence_value='daily' then 31 else 12 end) then
    raise exception 'Revisa el número de recorridos a programar.';
  end if;
  result:=private.request_trip_v7(payload);
  select * into t from public.trips where id=(result->>'id')::uuid for update;
  if not found then return result;end if;
  select * into source_quote from public.quotes where id=t.quote_id;
  perform private.capture_trip_route_v1(t.id,payload->'planned_route');
  if cadence_value='once' then return result||jsonb_build_object('scheduled_count',1);end if;
  if t.scheduled_at is null then raise exception 'Elige fecha y hora para repetir un viaje.';end if;
  insert into public.scheduled_trip_series(passenger_id,cadence,occurrence_count)
    values(t.passenger_id,cadence_value,count_value) returning * into series;
  update public.trips set schedule_series_id=series.id,schedule_sequence=1,schedule_total=count_value,updated_at=now() where id=t.id;
  for idx in 2..count_value loop
    child_scheduled_at:=case cadence_value
      when 'daily' then t.scheduled_at+make_interval(days=>idx-1)
      when 'weekly' then t.scheduled_at+make_interval(weeks=>idx-1)
      else t.scheduled_at+make_interval(months=>idx-1)
    end;
    insert into public.quotes(
      passenger_id,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,distance_km,
      fare_cents,commission_cents,women_only,accessible,scheduled_at,direct_distance_km,pickup_distance_km,
      pickup_eta_minutes,trip_eta_minutes,service_zone,route_factor,zone_surcharge_cents,booking_fee_cents,
      accessibility_surcharge_cents,estimate_source,pricing_version,pickup_surcharge_cents,preferred_driver_id,
      distance_charge_cents,time_charge_cents,minimum_adjustment_cents,party_size,service_notes
    ) values(
      source_quote.passenger_id,source_quote.origin,source_quote.destination,source_quote.origin_lat,source_quote.origin_lng,
      source_quote.dest_lat,source_quote.dest_lng,source_quote.category,source_quote.distance_km,
      source_quote.fare_cents-source_quote.pickup_surcharge_cents,
      round((source_quote.fare_cents-source_quote.pickup_surcharge_cents)*source_quote.commission_cents/nullif(source_quote.fare_cents,0)::numeric)::integer,
      source_quote.women_only,source_quote.accessible,
      child_scheduled_at,source_quote.direct_distance_km,source_quote.pickup_distance_km,source_quote.pickup_eta_minutes,
      source_quote.trip_eta_minutes,source_quote.service_zone,source_quote.route_factor,source_quote.zone_surcharge_cents,0,
      source_quote.accessibility_surcharge_cents,source_quote.estimate_source,source_quote.pricing_version,0,
      source_quote.preferred_driver_id,source_quote.distance_charge_cents,source_quote.time_charge_cents,
      source_quote.minimum_adjustment_cents,source_quote.party_size,source_quote.service_notes
    ) returning * into child_quote;
    insert into public.trips(
      passenger_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,
      fare_cents,commission_cents,payment_method,cash_tender_cents,payment_status,women_only,accessible,scheduled_at,
      tip_cents,total_cents,preferred_driver_id,party_size,service_notes,planned_route,planned_route_distance_km,
      planned_route_duration_minutes,planned_route_provider,planned_route_created_at,schedule_series_id,schedule_sequence,schedule_total
    ) values(
      t.passenger_id,child_quote.id,gen_random_uuid(),case when t.payment_method='card' then 'payment_pending' else 'scheduled' end,
      t.origin,t.destination,t.origin_lat,t.origin_lng,t.dest_lat,t.dest_lng,t.category,child_quote.fare_cents,child_quote.commission_cents,
      t.payment_method,case when t.payment_method='cash' then child_quote.fare_cents else null end,'pending',t.women_only,t.accessible,
      child_scheduled_at,
      0,child_quote.fare_cents,null,t.party_size,t.service_notes,t.planned_route,t.planned_route_distance_km,t.planned_route_duration_minutes,
      t.planned_route_provider,t.planned_route_created_at,series.id,idx,count_value
    ) returning * into child;
    insert into private.trip_secrets(trip_id,pin)
      values(child.id,lpad((((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,4))::bit(16)::int % 9000)+1000))::text,4,'0'));
    payment_status_value:=case when child.payment_method='card' then 'created' else 'pending' end;
    insert into public.payments(trip_id,payer_id,kind,provider,idempotency_key,amount_cents,status)
      values(child.id,child.passenger_id,'ride',case when child.payment_method='card' then 'mercado_pago' else 'cash' end,gen_random_uuid(),child.total_cents,payment_status_value);
    insert into public.trip_events(trip_id,actor_id,event,detail)
      values(child.id,t.passenger_id,'scheduled_series_created',jsonb_build_object('series_id',series.id,'sequence',idx,'cadence',cadence_value));
  end loop;
  insert into public.audit_log(actor_id,action,target_id,detail)
    values(t.passenger_id,'scheduled_trip_series_created',series.id,jsonb_build_object('cadence',cadence_value,'occurrence_count',count_value,'first_trip_id',t.id));
  return result||jsonb_build_object('scheduled_count',count_value,'schedule_series_id',series.id,'recurrence',cadence_value);
end $$;
revoke all on function private.request_trip_v8(jsonb) from public,anon;
grant execute on function private.request_trip_v8(jsonb) to authenticated;
