-- Show passengers the closest non-empty 1 km search ring without exposing driver identity.
create or replace function private.available_units_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;lat_value float8;lng_value float8;category_value text;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended or p.role<>'passenger' then
    raise exception 'Acceso de pasajero requerido.' using errcode='42501';
  end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>4000 then
    raise exception 'Consulta de unidades inválida.';
  end if;
  lat_value:=(payload->>'lat')::float8;
  lng_value:=(payload->>'lng')::float8;
  category_value:=payload->>'category';
  if not exists(select 1 from public.categories where id=category_value and active) then
    raise exception 'Categoría no disponible.';
  end if;
  if not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) then
    raise exception 'Ubicación fuera de cobertura.';
  end if;
  return (
    with eligible_base as materialized (
      select d.id as unit_id,d.category,round(dp.lat::numeric,4)::float8 as lat,
        round(dp.lng::numeric,4)::float8 as lng,
        private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22 as pickup_km
      from public.drivers d
      join public.driver_presence dp on dp.driver_id=d.id
      where d.online and d.approved and d.account_active and d.category=category_value
        and dp.heartbeat_at>now()-interval '90 seconds'
        and coalesce(d.license_expires>=current_date,false)
        and coalesce(d.insurance_expires>=current_date,false)
        and (not coalesce((payload->>'women_only')::boolean,false) or d.female_verified)
        and (not coalesce((payload->>'accessible')::boolean,false) or d.accessible_verified)
        and not exists(
          select 1 from public.trips t
          where t.driver_id=d.id and t.status not in ('completed','cancelled')
        )
        and not exists(
          select 1 from public.trip_offers o
          where o.driver_id=d.id and o.status='offered' and o.expires_at>now()
        )
    ), eligible as (
      select unit_id,category,lat,lng,round(pickup_km::numeric,2)::float8 as pickup_km,
        greatest(3,ceil(pickup_km/26*60)::integer+2) as pickup_minutes
      from eligible_base
    ), nearest_ring as (
      select greatest(1,ceil(min(pickup_km)))::integer as radius_km from eligible
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'unit_id',e.unit_id,
      'category',e.category,
      'lat',e.lat,
      'lng',e.lng,
      'pickup_km',e.pickup_km,
      'pickup_minutes',e.pickup_minutes,
      'search_radius_km',r.radius_km
    ) order by e.pickup_km,e.unit_id),'[]'::jsonb)
    from eligible e cross join nearest_ring r
    where e.pickup_km<=r.radius_km
  );
end $$;
revoke all on function private.available_units_v3(jsonb) from public,anon;
grant execute on function private.available_units_v3(jsonb) to authenticated;

