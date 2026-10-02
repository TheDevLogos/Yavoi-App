-- This internal audit table is read through controlled functions only.
drop policy if exists tariff_versions_rpc_only on public.tariff_versions;
create policy tariff_versions_rpc_only on public.tariff_versions
  for all to public using (false) with check (false);
