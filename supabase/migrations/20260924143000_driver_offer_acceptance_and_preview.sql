-- The offered row itself must not make its driver ineligible to accept it.
-- Include only the route coordinates required to preview a directed request.

create or replace function private.offers_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); d public.drivers; waiting record;
begin
  select * into d from public.drivers where id=uid for update;
  if uid is null or not found or not d.online or not d.approved or not d.account_active or not private.driver_shift_active_v1(uid) then return '[]'::jsonb; end if;
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip_v2(waiting.id,waiting.preferred_driver_id);
  end loop;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.expires_at),'[]') from (
    select o.id offer_id,o.expires_at,t.id,t.origin,t.destination,t.origin_lat,t.origin_lng,t.dest_lat,t.dest_lng,t.planned_route,
      t.fare_cents,t.fare_cents-round(t.fare_cents*private.driver_commission_bps(uid,t.payment_method)/10000.0)::integer+t.tip_cents net_cents,
      t.category,t.party_size,t.payment_method,t.distance_km,t.trip_eta_minutes,t.pickup_eta_minutes,t.service_notes,
      pr.full_name passenger_name,pr.avatar_path passenger_avatar_path,
      round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) pickup_from_driver_km
    from public.trip_offers o join public.trips t on t.id=o.trip_id join public.profiles pr on pr.id=t.passenger_id
      join public.driver_presence dp on dp.driver_id=o.driver_id
    where o.driver_id=uid and o.status='offered' and o.expires_at>now() and t.status='requested' and t.driver_id is null
  ) x);
end $$;
revoke all on function private.offers_v8(jsonb) from public,anon;
grant execute on function private.offers_v8(jsonb) to authenticated;

create or replace function private.accept_offer_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); o public.trip_offers; t public.trips; d public.drivers; bps integer; commission_value integer; active_trip uuid;
begin
  select * into o from public.trip_offers where id=(payload->>'offer_id')::uuid and driver_id=uid for update;
  if uid is null or not found or o.status<>'offered' or o.expires_at<=now() then raise exception 'La solicitud ya no está disponible.' using errcode='42501'; end if;
  select * into d from public.drivers where id=uid for update;
  select * into t from public.trips where id=o.trip_id for update;
  if not d.online or not d.approved or not d.account_active or not private.driver_shift_active_v1(uid)
    or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)
    or (t.women_only and not d.female_verified) or (t.accessible and not d.accessible_verified)
    or t.status<>'requested' or t.driver_id is not null then raise exception 'La solicitud ya no está disponible.'; end if;
  if exists(select 1 from public.trips busy where busy.driver_id=uid and busy.status in ('accepted','arrived'))
    or (select count(*) from public.trips busy where busy.driver_id=uid and busy.status='in_progress') > 1 then raise exception 'Ya tienes un viaje pendiente de recoger.'; end if;
  select id into active_trip from public.trips where driver_id=uid and status='in_progress' order by updated_at desc limit 1;
  bps:=private.driver_commission_bps(uid,t.payment_method); commission_value:=round(t.fare_cents*bps/10000.0)::integer;
  update public.trip_offers set status='accepted',responded_at=now() where id=o.id;
  update public.trip_offers set status='expired',responded_at=now(),response_reason='Solicitud tomada por otra unidad'
    where trip_id=t.id and id<>o.id and status='offered';
  update public.trips set driver_id=uid,status='accepted',billing_mode=d.billing_mode,commission_bps_applied=bps,commission_cents=commission_value,updated_at=now() where id=t.id returning * into t;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,case when active_trip is null then 'accepted' else 'accepted_as_next_trip' end,jsonb_build_object('offer_id',o.id,'after_trip_id',active_trip));
  return to_jsonb(t)||jsonb_build_object('queued_after_trip_id',active_trip);
end $$;
revoke all on function private.accept_offer_v4(jsonb) from public,anon;
grant execute on function private.accept_offer_v4(jsonb) to authenticated;
