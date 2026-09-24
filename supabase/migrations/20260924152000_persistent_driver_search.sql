-- Re-evaluate requested trips whenever the live fleet reports a position.
-- This keeps matching alive after expiry and allows the same eligible driver
-- to receive the request again after the cooldown when no other unit accepts.

create or replace function private.dispatch_waiting_trips_v2() returns trigger
language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  for waiting in
    select id,preferred_driver_id
    from public.trips
    where driver_id is null and status='requested'
    order by created_at
    limit 50
  loop
    perform private.auto_assign_trip_v2(waiting.id,waiting.preferred_driver_id);
  end loop;
  return null;
end $$;
revoke all on function private.dispatch_waiting_trips_v2() from public,anon,authenticated;

drop trigger if exists dispatch_waiting_after_presence on public.driver_presence;
create trigger dispatch_waiting_after_presence
after insert or update on public.driver_presence
for each statement execute function private.dispatch_waiting_trips_v2();
