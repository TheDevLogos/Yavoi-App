-- Cover foreign keys used by dispatch, history and audit queries.
create index drivers_category on public.drivers(category);
create index quotes_category on public.quotes(category);
create index ratings_author on public.ratings(author_id);
create index events_actor on public.trip_events(actor_id);
create index trips_category on public.trips(category);
