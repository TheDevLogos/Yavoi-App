-- Long-pickup pricing: the first 3 km to the passenger are included. Only the
-- excess is charged, at 65% of the selected category's per-km rate.
alter table public.quotes add column pickup_surcharge_cents integer not null default 0
 check(pickup_surcharge_cents between 0 and 100000);
alter table public.trips add column pickup_surcharge_cents integer not null default 0
 check(pickup_surcharge_cents between 0 and 100000);

create function private.apply_long_pickup_pricing() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.categories;pickup_fee integer:=0;
begin
 select * into c from public.categories where id=new.category;
 if not found then raise exception 'Categoría no disponible.';end if;
 if new.pickup_distance_km>3 then
   pickup_fee:=ceil((new.pickup_distance_km-3)*c.km_cents*0.65)::integer;
 end if;
 new.pickup_surcharge_cents:=pickup_fee;
 new.fare_cents:=new.fare_cents+pickup_fee;
 new.commission_cents:=round(new.fare_cents*c.commission_bps/10000.0);
 return new;
end $$;
revoke all on function private.apply_long_pickup_pricing() from public,anon,authenticated;
create trigger apply_long_pickup_pricing before insert on public.quotes
 for each row execute function private.apply_long_pickup_pricing();

create function private.copy_pickup_surcharge() returns trigger language plpgsql security definer set search_path='' as $$
begin
 select pickup_surcharge_cents into new.pickup_surcharge_cents
 from public.quotes where id=new.quote_id and passenger_id=new.passenger_id;
 if not found then raise exception 'Cotización inválida.';end if;
 return new;
end $$;
revoke all on function private.copy_pickup_surcharge() from public,anon,authenticated;
create trigger copy_pickup_surcharge before insert on public.trips
 for each row execute function private.copy_pickup_surcharge();
