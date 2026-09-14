create index trips_schedule_series on public.trips(schedule_series_id)
where schedule_series_id is not null;
