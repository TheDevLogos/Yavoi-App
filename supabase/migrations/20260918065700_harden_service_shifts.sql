-- Allow signed-in clients to read the public service schedule while keeping
-- all writes behind the MFA-protected administration RPC.
grant select on table public.service_shifts to authenticated;

create policy service_shifts_authenticated_read
on public.service_shifts
for select
to authenticated
using (true);

-- Cover the driver-to-shift foreign key used by availability and dispatch.
create index drivers_service_shift_code
on public.drivers(service_shift_code);
