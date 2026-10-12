-- The cash-only dispatch wrapper was introduced after the automatic waiting
-- calculation. Restore trip_v16 for every trip read while retaining every
-- cash-only rule in the current public dispatcher.
--
-- trip_v16 is the authoritative read model: it freezes the stopped waiting
-- charge and adds only accepted route, detour, and extra-pickup adjustments.
-- Both passenger and driver therefore receive the same final amount.
alter function public.yavoi(text,jsonb) rename to yavoi_before_restore_final_trip_totals;

create function public.yavoi(command text,payload jsonb default '{}')
returns jsonb
language plpgsql
security invoker
set search_path='' as $$
begin
  if command='trip' then
    return private.trip_v16(payload);
  end if;
  return public.yavoi_before_restore_final_trip_totals(command,payload);
end $$;

revoke all on function public.yavoi(text,jsonb) from public, anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
