-- Align Operations shifts with the current coverage plan and add an unrestricted shift.

do $$
declare constraint_name text;
begin
  select conname into constraint_name
  from pg_constraint
  where conrelid = 'public.service_shifts'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%start_time%end_time%';

  if constraint_name is not null then
    execute format('alter table public.service_shifts drop constraint %I', constraint_name);
  end if;
end $$;

alter table public.service_shifts
  add constraint service_shifts_valid_time_range
  check (code = 'all_day' or start_time <> end_time);

update public.service_shifts
set name = case code
      when 'midday' then 'Mediodía'
      when 'evening' then 'Vespertino'
      when 'night' then 'Nocturno'
      else name
    end,
    start_time = case code
      when 'midday' then time '10:00'
      when 'evening' then time '16:00'
      when 'night' then time '21:00'
      else start_time
    end,
    end_time = case code
      when 'midday' then time '16:00'
      when 'evening' then time '21:00'
      when 'night' then time '05:00'
      else end_time
    end,
    updated_at = now()
where code in ('midday', 'evening', 'night');

insert into public.service_shifts (code, name, start_time, end_time, active, sort_order)
values ('all_day', 'Todo el día disponible', time '00:00', time '00:00', true, 50)
on conflict (code) do update set
  name = excluded.name,
  start_time = excluded.start_time,
  end_time = excluded.end_time,
  sort_order = excluded.sort_order,
  updated_at = now();

create or replace function private.shift_active_v1(shift_code_value text, at_value timestamptz default now()) returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((
    select s.active and case
      when s.code = 'all_day' then true
      when s.start_time < s.end_time then (at_value at time zone 'America/Chihuahua')::time >= s.start_time
        and (at_value at time zone 'America/Chihuahua')::time < s.end_time
      else (at_value at time zone 'America/Chihuahua')::time >= s.start_time
        or (at_value at time zone 'America/Chihuahua')::time < s.end_time
    end
    from public.service_shifts s where s.code = shift_code_value
  ), false)
$$;
revoke all on function private.shift_active_v1(text, timestamptz) from public, anon, authenticated;

create or replace function private.upsert_service_shift_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target text := left(trim(coalesce(payload->>'code','')), 30); item public.service_shifts;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1') <> 'aal2' then
    raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';
  end if;
  if target not in ('morning', 'midday', 'evening', 'night', 'all_day') then
    raise exception 'Turno inválido.';
  end if;

  if target = 'all_day' then
    update public.service_shifts set
      name = 'Todo el día disponible',
      start_time = time '00:00',
      end_time = time '00:00',
      active = coalesce((payload->>'active')::boolean, false),
      updated_at = now()
    where code = target returning * into item;
  else
    update public.service_shifts set
      name = left(trim(payload->>'name'), 40),
      start_time = (payload->>'start_time')::time,
      end_time = (payload->>'end_time')::time,
      active = coalesce((payload->>'active')::boolean, false),
      updated_at = now()
    where code = target returning * into item;
  end if;

  if not found then raise exception 'Turno no encontrado.'; end if;
  insert into public.audit_log(actor_id, action, target_id, detail)
  values (auth.uid(), 'service_shift_updated', auth.uid(), to_jsonb(item));
  return to_jsonb(item);
end $$;
revoke all on function private.upsert_service_shift_v1(jsonb) from public, anon;
grant execute on function private.upsert_service_shift_v1(jsonb) to authenticated;
