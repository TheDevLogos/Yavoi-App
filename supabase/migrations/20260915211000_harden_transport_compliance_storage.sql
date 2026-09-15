-- Make the direct-access denial explicit and cover every new foreign key.
-- Application access remains limited to the security-definer RPC functions.

create index if not exists transport_compliance_settings_updated_by
  on private.transport_compliance_settings(updated_by)
  where updated_by is not null;

create index if not exists trip_regulatory_records_passenger
  on public.trip_regulatory_records(passenger_id);

create index if not exists trip_regulatory_records_driver
  on public.trip_regulatory_records(driver_id)
  where driver_id is not null;

create policy transport_compliance_settings_deny_direct_access
  on private.transport_compliance_settings
  for all to public
  using (false)
  with check (false);

create policy trip_receipt_outbox_deny_direct_access
  on private.trip_receipt_outbox
  for all to public
  using (false)
  with check (false);

create policy trip_regulatory_records_deny_direct_access
  on public.trip_regulatory_records
  for all to public
  using (false)
  with check (false);
