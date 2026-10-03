-- Dynamic pricing is evaluated on each quote.  It is not a permanent surcharge:
-- it only applies in recurring high-demand zones and the two local peak windows.
alter table public.finance_settings
  add column dynamic_schedule_enabled boolean not null default true,
  add column dynamic_history_days integer not null default 28 check(dynamic_history_days between 7 and 90),
  add column dynamic_zone_min_requests integer not null default 5 check(dynamic_zone_min_requests between 1 and 100),
  add column dynamic_peak_windows jsonb not null default '[{"start":"05:00","end":"08:30"},{"start":"17:00","end":"19:00"}]'::jsonb;

update public.finance_settings
set dynamic_enabled=true,dynamic_schedule_enabled=true,dynamic_max_bps=15000,updated_at=now()
where id=true;

create function private.dynamic_quote_policy_v1(p_lat double precision, p_lng double precision)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare settings public.finance_settings; local_time time; in_peak boolean:=false; target_lat integer:=floor(p_lat*100)::integer; target_lng integer:=floor(p_lng*100)::integer;
  historical integer:=0; zone_rank integer:=0; zone_count integer:=0; active_demand integer:=0; active_supply integer:=0; multiplier integer:=10000; eligible boolean:=false;
begin
  select * into settings from public.finance_settings where id;
  local_time:=timezone('America/Chihuahua',now())::time;
  select exists(select 1 from jsonb_array_elements(settings.dynamic_peak_windows) w
    where local_time >= (w->>'start')::time and local_time < (w->>'end')::time) into in_peak;
  with zones as (
    select floor(t.origin_lat*100)::integer lat_cell,floor(t.origin_lng*100)::integer lng_cell,count(*)::integer requests
    from public.trips t where t.created_at>=now()-(settings.dynamic_history_days||' days')::interval
    group by 1,2
  ), ranked as (
    select *,row_number() over(order by requests desc,lat_cell,lng_cell)::integer rank,count(*) over()::integer all_zones from zones
  ) select coalesce(requests,0),coalesce(rank,0),coalesce(all_zones,0) into historical,zone_rank,zone_count
    from ranked where lat_cell=target_lat and lng_cell=target_lng;
  select count(*)::integer into active_demand from public.trips t
    where t.status='requested' and t.driver_id is null and t.created_at>=now()-interval '10 minutes'
      and private.haversine_km(p_lat,p_lng,t.origin_lat,t.origin_lng)<=1.25;
  select count(*)::integer into active_supply from public.drivers d join public.driver_presence p on p.driver_id=d.id
    where d.online and d.approved and d.account_active and p.heartbeat_at>now()-interval '1 minute'
      and private.haversine_km(p_lat,p_lng,p.lat,p.lng)<=1.25;
  eligible:=settings.dynamic_enabled and settings.dynamic_schedule_enabled and in_peak
    and historical>=settings.dynamic_zone_min_requests and zone_rank between 1 and greatest(1,ceil(zone_count*.25)::integer)
    and active_demand>active_supply;
  if eligible then
    multiplier:=least(settings.dynamic_max_bps,case
      when active_demand>=greatest(active_supply,1)*3 then 15000
      when active_demand>=greatest(active_supply,1)*2 then 12500
      else 11500 end);
  end if;
  return jsonb_build_object('eligible',eligible,'multiplier_bps',multiplier,'zone_id',target_lat||':'||target_lng,
    'historical_requests',historical,'zone_rank',zone_rank,'zone_count',zone_count,'active_demand',active_demand,'active_supply',active_supply,
    'peak_window',case when in_peak then 'horario de mayor demanda' else 'fuera de horario de mayor demanda' end,
    'policy_version','delicias-zone-peak-2026-10');
end $$;
revoke all on function private.dynamic_quote_policy_v1(double precision,double precision) from public,anon;

create or replace function private.finance_quote_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; q public.quotes; settings public.finance_settings; policy jsonb; mult integer:=10000; extra integer:=0; parts jsonb;
begin
 result:=private.quote_v5(payload); select * into q from public.quotes where id=(result->>'id')::uuid;
 select * into settings from public.finance_settings where id;
 policy:=private.dynamic_quote_policy_v1(q.origin_lat,q.origin_lng);
 mult:=coalesce((policy->>'multiplier_bps')::integer,10000);
 extra:=round(q.fare_cents*(mult-10000)/10000.0);
 parts:=jsonb_build_object('version',settings.version,'tariff_version',settings.tariff_version,'vat_included',true,'vat_bps',1600,'state_bps',150,
 'base_cents',q.fare_cents-q.distance_charge_cents-q.time_charge_cents-q.minimum_adjustment_cents-q.zone_surcharge_cents-q.accessibility_surcharge_cents-q.pickup_surcharge_cents,
 'distance_cents',q.distance_charge_cents,'time_cents',q.time_charge_cents,'minimum_cents',q.minimum_adjustment_cents,
 'zone_cents',q.zone_surcharge_cents,'accessibility_cents',q.accessibility_surcharge_cents,'pickup_cents',q.pickup_surcharge_cents,
 'dynamic_bps',mult,'dynamic_cents',extra,'dynamic_policy',policy,'tolls_cents',0,'waiting_cents',0,'price_mode','upfront',
 'level_discounts',settings.level_discounts);
 update public.quotes set fare_cents=fare_cents+extra,pricing_version=settings.tariff_version,financial_terms=parts where id=q.id returning * into q;
 return to_jsonb(q)||jsonb_build_object('fare_base_without_vat_cents',round(q.fare_cents/1.16),'fare_vat_cents',q.fare_cents-round(q.fare_cents/1.16));
end $$;

create or replace function private.finance_settings_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare levels jsonb:=coalesce(payload->'level_discounts','{}'); v jsonb;
begin
 perform private.finance_admin();
 if length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Registra el motivo del cambio.'; end if;
 if coalesce((payload->>'dynamic_max_bps')::integer,15000) not between 10000 and 15000 or jsonb_typeof(levels)<>'object' then raise exception 'Configuración inválida.'; end if;
 for v in select value from jsonb_each(levels) loop if v::text::integer not between 0 and 5000 then raise exception 'Beneficio por nivel fuera de rango.'; end if; end loop;
 update public.finance_settings set dynamic_enabled=coalesce((payload->>'dynamic_enabled')::boolean,false),dynamic_max_bps=coalesce((payload->>'dynamic_max_bps')::integer,15000),level_discounts=levels,
 payouts_enabled=coalesce((payload->>'payouts_enabled')::boolean,false),updated_at=now() where id;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'finance_settings_changed',payload||jsonb_build_object('dynamic_schedule','automatic_zone_peak','peak_windows','05:00-08:30,17:00-19:00'));
 return jsonb_build_object('ok',true);
end $$;
