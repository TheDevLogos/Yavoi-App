-- Keep selected-unit quote lookups efficient as trip volume grows.
create index quotes_preferred_driver on public.quotes(preferred_driver_id)
where preferred_driver_id is not null;
