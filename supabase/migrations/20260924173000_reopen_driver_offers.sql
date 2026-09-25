-- A driver can be offered the same requested trip again after the cooldown.
-- trip_offers intentionally has one row per trip/driver, so reopen that row
-- instead of attempting a duplicate insert.
create or replace function private.auto_assign_trip_v2(target_trip uuid, preferred uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare t public.trips; chosen uuid; reopened uuid;
begin
  select * into t from public.trips where id=target_trip for update;
  if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id; end if;

  update public.trip_offers
     set status='expired', responded_at=now(), response_reason='Tiempo de respuesta agotado'
   where trip_id=t.id and status='offered' and expires_at<=now();

  select driver_id into chosen from public.trip_offers
   where trip_id=t.id and status='offered' and expires_at>now();
  if chosen is not null then return chosen; end if;

  select d.id into chosen
    from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where private.driver_candidate_eligible_v2(d.id,t.women_only,t.accessible)
     and not exists(select 1 from public.trip_offers prior where prior.trip_id=t.id and prior.driver_id=d.id)
   order by case when d.id=preferred then 0 else 1 end,
     private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng), dp.heartbeat_at desc
   for update of d skip locked limit 1;

  if chosen is null then
    select d.id into chosen
      from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
     where private.driver_candidate_eligible_v2(d.id,t.women_only,t.accessible)
       and coalesce((select max(prior.offered_at) from public.trip_offers prior
                       where prior.trip_id=t.id and prior.driver_id=d.id), '-infinity'::timestamptz)
           <= now()-interval '90 seconds'
     order by coalesce((select max(prior.offered_at) from public.trip_offers prior
                         where prior.trip_id=t.id and prior.driver_id=d.id), '-infinity'::timestamptz),
       private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)
     for update of d skip locked limit 1;
  end if;

  if chosen is not null then
    update public.trip_offers
       set status='offered', offered_at=now(), expires_at=now()+interval '8 seconds',
           responded_at=null, response_reason=''
     where trip_id=t.id and driver_id=chosen and status in ('expired','rejected','cancelled')
     returning id into reopened;
    if reopened is null then
      insert into public.trip_offers(trip_id,driver_id,expires_at)
      values(t.id,chosen,now()+interval '8 seconds')
      on conflict(trip_id,driver_id) do update
        set status='offered', offered_at=now(), expires_at=now()+interval '8 seconds',
            responded_at=null, response_reason=''
      returning id into reopened;
    end if;
    insert into public.trip_events(trip_id,actor_id,event,detail)
    values(t.id,chosen,'offer_sent',jsonb_build_object(
      'preferred',chosen=preferred,'expires_in_seconds',8,'retry_after_seconds',90,
      'progressive_search',true,'offer_reopened',reopened is not null));
  end if;
  return chosen;
end $$;
revoke all on function private.auto_assign_trip_v2(uuid,uuid) from public,anon,authenticated;
