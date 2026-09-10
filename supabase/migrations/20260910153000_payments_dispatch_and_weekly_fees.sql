-- Provider-ready payments, automatic dispatch, live route history and driver fees.
alter table public.drivers
  add column account_active boolean not null default true,
  add column vehicle_make text not null default '',
  add column vehicle_model text not null default '',
  add column vehicle_year integer check(vehicle_year between 1990 and 2100),
  add column vehicle_color text not null default '';

alter table public.trips drop constraint trips_status_check;
alter table public.trips add constraint trips_status_check
  check(status in ('payment_pending','scheduled','requested','accepted','arrived','in_progress','completed','cancelled'));
alter table public.trips drop constraint trips_payment_status_check;
alter table public.trips add constraint trips_payment_status_check
  check(payment_status in ('pending','paid','refund_pending','refunded','failed'));
alter table public.trips
  add column tip_cents integer not null default 0 check(tip_cents between 0 and 100000),
  add column total_cents integer not null default 0 check(total_cents between 0 and 300000),
  add column preferred_driver_id uuid references public.drivers(id);
update public.trips set total_cents=fare_cents where total_cents=0;
create index trips_preferred_driver on public.trips(preferred_driver_id) where preferred_driver_id is not null;

alter table public.locations add column heading double precision check(heading between 0 and 360),
  add column speed double precision check(speed between 0 and 100);
alter table public.driver_presence add column heading double precision check(heading between 0 and 360),
  add column speed double precision check(speed between 0 and 100);

alter table public.ledger drop constraint ledger_kind_check;
alter table public.ledger add constraint ledger_kind_check
  check(kind in ('fare','commission','cash_tip','card_tip'));

create table public.payments (
 id uuid primary key default gen_random_uuid(),
 trip_id uuid references public.trips(id) on delete restrict,
 payer_id uuid not null references public.profiles(id) on delete restrict,
 driver_id uuid references public.drivers(id) on delete restrict,
 kind text not null check(kind in ('ride','tip','weekly_fee')),
 provider text not null check(provider in ('cash','mercado_pago','manual')),
 provider_payment_id text unique,
 idempotency_key uuid not null unique default gen_random_uuid(),
 amount_cents integer not null check(amount_cents between 1 and 300000),
 currency text not null default 'MXN' check(currency='MXN'),
 status text not null default 'created' check(status in ('created','pending','in_process','approved','rejected','cancelled','refund_pending','refunded')),
 status_detail text not null default '',
 payment_method_type text not null default '',
 payment_method_id text not null default '',
 installments integer check(installments between 1 and 48),
 processing_fee_cents integer not null default 0,
 net_received_cents integer not null default 0,
 live_mode boolean,
 provider_created_at timestamptz,
 provider_approved_at timestamptz,
 refund_idempotency_key uuid not null default gen_random_uuid() unique,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check((kind='weekly_fee' and driver_id is not null) or kind<>'weekly_fee'),
 check((kind in ('ride','tip') and trip_id is not null) or kind='weekly_fee')
);
create index payments_trip on public.payments(trip_id,created_at desc);
create index payments_driver on public.payments(driver_id,created_at desc);
create index payments_payer on public.payments(payer_id,created_at desc);
create index payments_status on public.payments(status,created_at desc);

create table public.weekly_fees (
 id uuid primary key default gen_random_uuid(),
 driver_id uuid not null references public.drivers(id) on delete cascade,
 week_start date not null,
 due_at timestamptz not null,
 amount_cents integer not null default 50000 check(amount_cents between 0 and 100000),
 status text not null default 'pending' check(status in ('pending','submitted','paid','overdue','waived')),
 payment_id uuid unique references public.payments(id),
 proof_path text,
 submitted_at timestamptz,
 verified_by uuid references public.profiles(id),
 verified_at timestamptz,
 note text not null default '' check(char_length(note)<=1000),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(driver_id,week_start)
);
create index weekly_fees_driver on public.weekly_fees(driver_id,week_start desc);
create index weekly_fees_due on public.weekly_fees(status,due_at);
create index weekly_fees_verified_by on public.weekly_fees(verified_by) where verified_by is not null;

create table public.payment_events (
 id bigint generated always as identity primary key,
 payment_id uuid not null references public.payments(id) on delete cascade,
 provider text not null,
 event_key text not null,
 event_type text not null,
 status text not null,
 detail jsonb not null default '{}',
 created_at timestamptz not null default now(),
 unique(provider,event_key)
);
create index payment_events_payment on public.payment_events(payment_id,created_at desc);

create table public.location_history (
 id bigint generated always as identity primary key,
 trip_id uuid not null references public.trips(id) on delete cascade,
 driver_id uuid not null references public.drivers(id) on delete cascade,
 lat double precision not null check(lat between -90 and 90),
 lng double precision not null check(lng between -180 and 180),
 accuracy double precision not null check(accuracy between 0 and 10000),
 heading double precision check(heading between 0 and 360),
 speed double precision check(speed between 0 and 100),
 captured_at timestamptz not null default now()
);
create index location_history_trip on public.location_history(trip_id,captured_at desc);
create index location_history_driver on public.location_history(driver_id,captured_at desc);

create table private.app_settings (
 id boolean primary key default true check(id),
 mercado_pago_enabled boolean not null default false,
 mercado_pago_public_key text not null default '',
 weekly_fee_cents integer not null default 50000 check(weekly_fee_cents between 0 and 100000),
 updated_at timestamptz not null default now()
);
insert into private.app_settings(id) values(true);
revoke all on private.app_settings from public,anon,authenticated;

create table private.map_cache (
 cache_key text primary key,
 payload jsonb not null,
 expires_at timestamptz not null,
 created_at timestamptz not null default now()
);
revoke all on private.map_cache from public,anon,authenticated;
create table private.map_requests (
 user_id uuid primary key,
 last_request_at timestamptz not null default now()
);
revoke all on private.map_requests from public,anon,authenticated;

alter table public.payments enable row level security;
alter table public.weekly_fees enable row level security;
alter table public.payment_events enable row level security;
alter table public.location_history enable row level security;
revoke all on public.payments,public.weekly_fees,public.payment_events,public.location_history from anon,authenticated;
grant select on public.payments,public.weekly_fees,public.payment_events,public.location_history to authenticated;
create policy payments_read on public.payments for select to authenticated using(
 payer_id=(select auth.uid()) or driver_id=(select auth.uid()) or (select private.is_admin())
);
create policy weekly_fees_read on public.weekly_fees for select to authenticated using(
 driver_id=(select auth.uid()) or (select private.is_admin())
);
create policy payment_events_read on public.payment_events for select to authenticated using(
 exists(select 1 from public.payments p where p.id=payment_id and
   (p.payer_id=(select auth.uid()) or p.driver_id=(select auth.uid()) or (select private.is_admin())))
);
create policy location_history_read on public.location_history for select to authenticated using(
 exists(select 1 from public.trips t where t.id=trip_id and
   (t.passenger_id=(select auth.uid()) or t.driver_id=(select auth.uid()) or (select private.is_admin())))
);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('yavoi-payment-proofs','yavoi-payment-proofs',false,5242880,array['application/pdf','image/jpeg','image/png'])
 on conflict(id) do nothing;
create policy payment_proofs_insert on storage.objects for insert to authenticated with check(
 bucket_id='yavoi-payment-proofs' and (storage.foldername(name))[1]=(select auth.uid())::text
 and exists(select 1 from public.drivers where id=(select auth.uid()))
);
create policy payment_proofs_read on storage.objects for select to authenticated using(
 bucket_id='yavoi-payment-proofs' and ((storage.foldername(name))[1]=(select auth.uid())::text or (select private.is_admin()))
);

create function private.capture_location_history() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.location_history(trip_id,driver_id,lat,lng,accuracy,heading,speed,captured_at)
 values(new.trip_id,new.driver_id,new.lat,new.lng,new.accuracy,new.heading,new.speed,new.updated_at);
 return new;
end $$;
revoke all on function private.capture_location_history() from public,anon,authenticated;
create trigger capture_trip_location after insert or update on public.locations for each row execute function private.capture_location_history();

create function private.ensure_weekly_fee(target_driver uuid) returns public.weekly_fees language plpgsql security definer set search_path='' as $$
declare result public.weekly_fees;start_day date:=date_trunc('week',current_date)::date;fee integer;
begin
 select weekly_fee_cents into fee from private.app_settings where id;
 insert into public.weekly_fees(driver_id,week_start,due_at,amount_cents)
 values(target_driver,start_day,(start_day+7)::timestamp at time zone 'America/Chihuahua',fee)
 on conflict(driver_id,week_start) do update set updated_at=public.weekly_fees.updated_at
 returning * into result;
 return result;
end $$;
revoke all on function private.ensure_weekly_fee(uuid) from public,anon,authenticated;

create function private.open_fee_after_driver_approval() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.approved and not old.approved then perform private.ensure_weekly_fee(new.id);end if;
 return new;
end $$;
revoke all on function private.open_fee_after_driver_approval() from public,anon,authenticated;
create trigger open_fee_after_driver_approval after update of approved on public.drivers
 for each row execute function private.open_fee_after_driver_approval();

create function private.auto_assign_trip(target_trip uuid,preferred uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare t public.trips;chosen uuid;
begin
 select * into t from public.trips where id=target_trip for update;
 if not found or t.driver_id is not null or t.status<>'requested' then return t.driver_id;end if;
 select d.id into chosen from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
 where d.online and d.approved and d.account_active and d.category=t.category
   and dp.updated_at>now()-interval '10 minutes'
   and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
   and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
   and not exists(select 1 from public.trips busy where busy.driver_id=d.id and busy.status not in ('completed','cancelled'))
 order by case when d.id=preferred then 0 else 1 end,
   private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng),dp.updated_at desc
 for update of d skip locked limit 1;
 if chosen is not null then
   update public.trips set driver_id=chosen,status='accepted',updated_at=now() where id=t.id;
   insert into public.trip_events(trip_id,actor_id,event,detail)
   values(t.id,chosen,'auto_assigned',jsonb_build_object('preferred',chosen=preferred));
 end if;
 return chosen;
end $$;
revoke all on function private.auto_assign_trip(uuid,uuid) from public,anon,authenticated;

create function private.dispatch_waiting_trips() returns trigger language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
 for waiting in
   select id,preferred_driver_id from public.trips
   where driver_id is null and (status='requested' or (status='scheduled' and scheduled_at<=now()+interval '15 minutes'))
   order by case when status='scheduled' then scheduled_at else created_at end limit 25
 loop
   update public.trips set status='requested',updated_at=now() where id=waiting.id and status='scheduled';
   perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
 end loop;
 return new;
end $$;
revoke all on function private.dispatch_waiting_trips() from public,anon,authenticated;
create trigger dispatch_waiting_after_presence after insert or update on public.driver_presence
 for each statement execute function private.dispatch_waiting_trips();

create function private.available_units_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;lat_value float8;lng_value float8;category_value text;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 lat_value:=(payload->>'lat')::float8;lng_value:=(payload->>'lng')::float8;category_value:=payload->>'category';
 if not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) then raise exception 'Ubicación fuera de cobertura.';end if;
 return (select coalesce(jsonb_agg(to_jsonb(x) order by x.pickup_km),'[]') from (
   select d.id as unit_id,d.category,round(dp.lat::numeric,4)::float8 as lat,round(dp.lng::numeric,4)::float8 as lng,
     round((private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22)::numeric,2) as pickup_km,
     greatest(3,ceil(private.haversine_km(dp.lat,dp.lng,lat_value,lng_value)*1.22/26*60)::integer+2) as pickup_minutes,
     d.female_verified,d.accessible_verified
   from public.drivers d join public.driver_presence dp on dp.driver_id=d.id
   where d.online and d.approved and d.account_active and d.category=category_value
     and dp.updated_at>now()-interval '10 minutes'
     and coalesce(d.license_expires>=current_date,false) and coalesce(d.insurance_expires>=current_date,false)
     and (not coalesce((payload->>'women_only')::boolean,false) or d.female_verified)
     and (not coalesce((payload->>'accessible')::boolean,false) or d.accessible_verified)
     and not exists(select 1 from public.trips t where t.driver_id=d.id and t.status not in ('completed','cancelled'))
   order by pickup_km limit 20
 )x);
end $$;
revoke all on function private.available_units_v3(jsonb) from public,anon;
grant execute on function private.available_units_v3(jsonb) to authenticated;

create function private.request_trip_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;q public.quotes;t public.trips;method text;tip integer;total integer;tender integer;pinvalue text;payment_id uuid;assigned uuid;preferred uuid;enabled boolean;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended or p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
 if not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Verifica tu correo para continuar.' using errcode='42501';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 perform 1 from public.profiles where id=uid for update;
 select * into t from public.trips where passenger_id=uid and request_key=(payload->>'request_key')::uuid;
 if found then return to_jsonb(t)||jsonb_build_object('payment_id',(select id from public.payments where trip_id=t.id and kind='ride' order by created_at limit 1));end if;
 select * into q from public.quotes where id=(payload->>'quote_id')::uuid and passenger_id=uid for update;
 if not found or q.expires_at<now() then raise exception 'La cotización venció. Calcula una nueva tarifa.';end if;
 method:=payload->>'payment_method';if method not in ('cash','card') or method is null then raise exception 'Selecciona un método de pago.';end if;
 tip:=coalesce((payload->>'tip_cents')::integer,0);if tip<0 or tip>100000 then raise exception 'La propina debe estar entre $0 y $1,000.';end if;
 total:=q.fare_cents+tip;if total>300000 then raise exception 'El total supera el límite permitido.';end if;
 if exists(select 1 from public.trips where passenger_id=uid and status not in ('completed','cancelled','scheduled')) then raise exception 'Ya tienes un viaje activo.';end if;
 if (select count(*) from public.trips where passenger_id=uid and created_at>now()-interval '1 hour')>=10 then raise exception 'Límite de solicitudes alcanzado. Intenta más tarde.';end if;
 preferred:=nullif(payload->>'preferred_driver_id','')::uuid;
 if preferred is not null and not exists(select 1 from public.drivers d join public.driver_presence dp on dp.driver_id=d.id where d.id=preferred and d.online and d.approved and d.account_active and d.category=q.category and dp.updated_at>now()-interval '10 minutes' and (not q.women_only or d.female_verified) and (not q.accessible or d.accessible_verified)) then preferred:=null;end if;
 if method='card' then
   select mercado_pago_enabled into enabled from private.app_settings where id;
   if not enabled then raise exception 'El pago con tarjeta está listo para configurarse, pero aún no está activado por Operaciones.';end if;
   tender:=null;
 else
   tender:=coalesce((payload->>'cash_tender_cents')::integer,total);
   if tender<total or tender>300000 then raise exception 'Indica un monto de efectivo válido, hasta $3,000.';end if;
 end if;
 insert into public.trips(passenger_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,fare_cents,commission_cents,payment_method,cash_tender_cents,payment_status,women_only,accessible,scheduled_at,tip_cents,total_cents,preferred_driver_id)
 values(uid,q.id,(payload->>'request_key')::uuid,case when method='card' then 'payment_pending' when q.scheduled_at is null then 'requested' else 'scheduled' end,q.origin,q.destination,q.origin_lat,q.origin_lng,q.dest_lat,q.dest_lng,q.category,q.fare_cents,q.commission_cents,method,tender,'pending',q.women_only,q.accessible,q.scheduled_at,tip,total,preferred) returning * into t;
 pinvalue:=lpad((((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,4))::bit(16)::int % 9000)+1000))::text,4,'0');
 insert into private.trip_secrets(trip_id,pin) values(t.id,pinvalue);
 insert into public.payments(trip_id,payer_id,kind,provider,idempotency_key,amount_cents,status)
 values(t.id,uid,'ride',case when method='card' then 'mercado_pago' else 'cash' end,(payload->>'request_key')::uuid,total,case when method='card' then 'created' else 'pending' end) returning id into payment_id;
 insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,t.status,jsonb_build_object('payment_method',method,'tip_cents',tip));
 if t.status='requested' then assigned:=private.auto_assign_trip(t.id,preferred);end if;
 select * into t from public.trips where id=t.id;
 return to_jsonb(t)||jsonb_build_object('payment_id',payment_id,'assigned_driver_id',assigned);
end $$;
revoke all on function private.request_trip_v3(jsonb) from public,anon;
grant execute on function private.request_trip_v3(jsonb) to authenticated;

create function private.bootstrap_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare base jsonb;enabled boolean;public_key text;
begin
 base:=private.dispatch('bootstrap',payload);
 select mercado_pago_enabled,mercado_pago_public_key into enabled,public_key from private.app_settings where id;
 return base||jsonb_build_object('card_enabled',enabled and public_key<>'','mercado_pago_public_key',case when enabled then public_key else '' end);
end $$;
revoke all on function private.bootstrap_v3(jsonb) from public,anon;
grant execute on function private.bootstrap_v3(jsonb) to authenticated;

create function private.dashboard_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;
begin
 select * into p from public.profiles where id=uid;
 base:=private.dispatch('dashboard',payload);
 if p.role='driver' then perform private.ensure_weekly_fee(uid);end if;
 if p.role='admin' then
   update public.weekly_fees set status='overdue',updated_at=now() where status in ('pending','submitted') and due_at<now();
   update public.drivers d set account_active=false,online=false,updated_at=now()
   where exists(select 1 from public.weekly_fees f where f.driver_id=d.id and f.status='overdue');
 end if;
 return base||jsonb_build_object(
  'payments',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
    select pay.*,t.origin,t.destination,pr.full_name as payer_name,drp.full_name as driver_name
    from public.payments pay left join public.trips t on t.id=pay.trip_id
    join public.profiles pr on pr.id=pay.payer_id left join public.profiles drp on drp.id=pay.driver_id
    where pay.payer_id=uid or pay.driver_id=uid or p.role='admin' order by pay.created_at desc limit 500)x),
  'weekly_fees',(select coalesce(jsonb_agg(to_jsonb(x) order by x.week_start desc),'[]') from (
    select f.*,pr.full_name as driver_name,d.account_active from public.weekly_fees f
    join public.profiles pr on pr.id=f.driver_id join public.drivers d on d.id=f.driver_id
    where f.driver_id=uid or p.role='admin' order by f.week_start desc limit 500)x)
 );
end $$;
revoke all on function private.dashboard_v3(jsonb) from public,anon;
grant execute on function private.dashboard_v3(jsonb) to authenticated;

create function private.trip_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();t public.trips;base jsonb;
begin
 select * into t from public.trips where id=(payload->>'trip_id')::uuid;
 if not found then raise exception 'Viaje no encontrado.';end if;
 base:=private.dispatch('trip',payload);
 return base||jsonb_build_object(
  'driver',(select jsonb_build_object('name',pr.full_name,'avatar_path',pr.avatar_path,'vehicle',dr.vehicle,'vehicle_make',dr.vehicle_make,'vehicle_model',dr.vehicle_model,'vehicle_year',dr.vehicle_year,'vehicle_color',dr.vehicle_color,'plate',dr.plate,'rating',(select round(avg(stars),2) from public.ratings where recipient_id=dr.id)) from public.drivers dr join public.profiles pr on pr.id=dr.id where dr.id=t.driver_id),
  'route_history',(select coalesce(jsonb_agg(to_jsonb(x) order by x.captured_at),'[]') from (select lat,lng,accuracy,heading,speed,captured_at from public.location_history where trip_id=t.id order by captured_at desc limit 500)x),
  'payments',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') from public.payments x where trip_id=t.id)
 );
end $$;
revoke all on function private.trip_v3(jsonb) from public,anon;
grant execute on function private.trip_v3(jsonb) to authenticated;

create function private.driver_profile_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;make_value text;model_value text;year_value integer;color_value text;combined text;
begin
 select * into p from public.profiles where id=uid;
 if not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
 if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de editar el expediente.';end if;
 make_value:=trim(coalesce(payload->>'vehicle_make',''));model_value:=trim(coalesce(payload->>'vehicle_model',''));year_value:=(payload->>'vehicle_year')::integer;color_value:=trim(coalesce(payload->>'vehicle_color',''));
 if length(make_value)<2 or length(model_value)<1 or year_value not between 1990 and extract(year from current_date)::integer+1 or length(color_value)<3 or length(trim(coalesce(payload->>'plate','')))<5 then raise exception 'Completa marca, modelo, año, color y placas.';end if;
 if payload->>'license_path' is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=payload->>'license_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'Licencia inválida.';end if;
 if payload->>'insurance_path' is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=payload->>'insurance_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'Póliza inválida.';end if;
 combined:=left(make_value||' '||model_value||' '||year_value::text,100);
 update public.drivers set vehicle=combined,vehicle_make=left(make_value,50),vehicle_model=left(model_value,50),vehicle_year=year_value,vehicle_color=left(color_value,40),plate=upper(left(trim(payload->>'plate'),20)),category=payload->>'category',license_number=left(coalesce(payload->>'license_number',''),50),license_expires=nullif(payload->>'license_expires','')::date,insurance_expires=nullif(payload->>'insurance_expires','')::date,license_path=coalesce(payload->>'license_path',license_path),insurance_path=coalesce(payload->>'insurance_path',insurance_path),advertising_interest=coalesce((payload->>'advertising_interest')::boolean,false),approved=false,online=false,updated_at=now() where id=uid;
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.driver_profile_v3(jsonb) from public,anon;
grant execute on function private.driver_profile_v3(jsonb) to authenticated;

create function private.availability_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;d public.drivers;going_online boolean;fee public.weekly_fees;
begin
 select * into p from public.profiles where id=uid;select * into d from public.drivers where id=uid for update;
 if not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
 going_online:=coalesce((payload->>'online')::boolean,false);
 fee:=private.ensure_weekly_fee(uid);
 if exists(select 1 from public.weekly_fees where driver_id=uid and status in ('pending','submitted','overdue') and due_at<now()) then
   update public.weekly_fees set status='overdue',updated_at=now() where driver_id=uid and status in ('pending','submitted') and due_at<now();
   update public.drivers set account_active=false,online=false where id=uid;d.account_active:=false;
 end if;
 if going_online and (not d.approved or not d.account_active or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then raise exception 'Tu expediente debe estar aprobado; el acceso semanal y los documentos deben estar activos y vigentes.';end if;
 if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de cambiar tu disponibilidad.';end if;
 update public.drivers set online=going_online,updated_at=now() where id=uid;
 return jsonb_build_object('ok',true,'weekly_fee',to_jsonb(fee));
end $$;
revoke all on function private.availability_v3(jsonb) from public,anon;
grant execute on function private.availability_v3(jsonb) to authenticated;

create function private.location_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();t public.trips;lat_value float8;lng_value float8;accuracy_value float8;heading_value float8;speed_value float8;
begin
 select * into t from public.trips where id=(payload->>'trip_id')::uuid;
 if not found or t.driver_id is distinct from uid or t.status not in ('accepted','arrived','in_progress') then raise exception 'Ubicación no permitida.' using errcode='42501';end if;
 lat_value:=(payload->>'lat')::float8;lng_value:=(payload->>'lng')::float8;accuracy_value:=(payload->>'accuracy')::float8;heading_value:=nullif(payload->>'heading','')::float8;speed_value:=nullif(payload->>'speed','')::float8;
 if not(lat_value between 28.0 and 28.4 and lng_value between -105.7 and -105.2) or not(accuracy_value between 0 and 5000) then raise exception 'Ubicación fuera de cobertura o sin precisión suficiente.';end if;
 if exists(select 1 from public.locations where trip_id=t.id and updated_at>now()-interval '4 seconds') then return jsonb_build_object('ok',true,'throttled',true);end if;
 insert into public.locations(trip_id,driver_id,lat,lng,accuracy,heading,speed) values(t.id,uid,lat_value,lng_value,accuracy_value,heading_value,speed_value)
 on conflict(trip_id) do update set lat=excluded.lat,lng=excluded.lng,accuracy=excluded.accuracy,heading=excluded.heading,speed=excluded.speed,updated_at=now();
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.location_v3(jsonb) from public,anon;
grant execute on function private.location_v3(jsonb) to authenticated;

create function private.transition_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;t public.trips;newstate text;pay public.payments;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended then raise exception 'Tu cuenta no está habilitada.' using errcode='42501';end if;
 if p.role='admin' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';end if;
 select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
 if not found or (t.passenger_id is distinct from uid and t.driver_id is distinct from uid and p.role<>'admin') then raise exception 'No tienes acceso a este viaje.' using errcode='42501';end if;
 newstate:=payload->>'status';
 if newstate='cancelled' then
   if t.status in ('completed','cancelled') then raise exception 'El viaje ya finalizó.';end if;
   if t.status='in_progress' and p.role<>'admin' then raise exception 'Durante el recorrido solicita apoyo a Operaciones.';end if;
   if length(trim(coalesce(payload->>'reason','')))<5 then raise exception 'Escribe el motivo de cancelación.';end if;
 else
   if t.driver_id is distinct from uid or p.role<>'driver' then raise exception 'Sólo el conductor asignado puede avanzar el viaje.' using errcode='42501';end if;
   if not exists(select 1 from public.drivers where id=uid and approved and account_active) then raise exception 'Tu autorización de conductor no está vigente.';end if;
   if not ((t.status='accepted' and newstate='arrived')or(t.status='arrived' and newstate='in_progress')or(t.status='in_progress' and newstate='completed')) then raise exception 'Cambio de estado no permitido.';end if;
   if newstate='in_progress' then
     if (select attempts from private.trip_secrets where trip_id=t.id)>=5 then return jsonb_build_object('error','PIN bloqueado. Solicita ayuda a Operaciones.');end if;
     if (select pin from private.trip_secrets where trip_id=t.id) is distinct from payload->>'pin' then update private.trip_secrets set attempts=attempts+1 where trip_id=t.id;return jsonb_build_object('error','PIN incorrecto. Solicítalo al pasajero.');end if;
   end if;
   if newstate='completed' and t.payment_method='cash' and coalesce((payload->>'cash_received')::boolean,false)<>true then raise exception 'Confirma que recibiste el efectivo y entregaste el cambio.';end if;
   if newstate='completed' and t.payment_method='card' and t.payment_status<>'paid' then raise exception 'El pago con tarjeta aún no está confirmado.';end if;
 end if;
 update public.trips set status=newstate,cancel_reason=case when newstate='cancelled' then left(payload->>'reason',500) else null end,
   payment_status=case when newstate='completed' and payment_method='cash' then 'paid' when newstate='cancelled' and payment_method='card' and payment_status='paid' then 'refund_pending' else payment_status end,
   completed_at=case when newstate='completed' then now() else null end,updated_at=now() where id=t.id returning * into t;
 if newstate='completed' then
   insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,'fare',t.fare_cents),(t.id,t.driver_id,'commission',-t.commission_cents) on conflict do nothing;
   if t.tip_cents>0 then insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,case when t.payment_method='card' then 'card_tip' else 'cash_tip' end,t.tip_cents) on conflict do nothing;end if;
   insert into public.reward_entries(user_id,trip_id,points) values(t.passenger_id,t.id,10),(t.driver_id,t.id,10) on conflict do nothing;
   if t.payment_method='cash' then update public.payments set status='approved',status_detail='cash_received',updated_at=now(),provider_approved_at=now() where trip_id=t.id and kind='ride';end if;
 elsif newstate='cancelled' and t.payment_method='card' and t.payment_status='refund_pending' then
   update public.payments set status='refund_pending',updated_at=now() where trip_id=t.id and kind='ride' and status='approved' returning * into pay;
 end if;
 insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,newstate,jsonb_build_object('reason',t.cancel_reason));
 if p.role='admin' then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'cancel_trip',t.id,jsonb_build_object('reason',t.cancel_reason));end if;
 return to_jsonb(t)||jsonb_build_object('refund_payment_id',pay.id);
end $$;
revoke all on function private.transition_v3(jsonb) from public,anon;
grant execute on function private.transition_v3(jsonb) to authenticated;

create function private.payment_checkout_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;pay public.payments;email_value text;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 select * into pay from public.payments where id=(payload->>'payment_id')::uuid for update;
 if not found or pay.payer_id<>uid or pay.provider<>'mercado_pago' or pay.status not in ('created','pending','in_process')
   or (pay.kind='ride' and not exists(select 1 from public.trips where id=pay.trip_id and status='payment_pending'))
   then raise exception 'Pago no disponible.' using errcode='42501';end if;
 select email into email_value from auth.users where id=uid;
 return jsonb_build_object('payment_id',pay.id,'amount_cents',pay.amount_cents,'currency',pay.currency,'idempotency_key',pay.idempotency_key,'kind',pay.kind,'trip_id',pay.trip_id,'payer_email',email_value,'description',case pay.kind when 'ride' then 'Viaje Yavoi!' when 'tip' then 'Propina Yavoi!' else 'Cuota semanal Yavoi!' end);
end $$;
revoke all on function private.payment_checkout_v1(jsonb) from public,anon;
grant execute on function private.payment_checkout_v1(jsonb) to authenticated;

create function private.refund_checkout_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;pay public.payments;
begin
 select * into p from public.profiles where id=uid;
 select * into pay from public.payments where id=(payload->>'payment_id')::uuid for update;
 if uid is null or not found or p.suspended or not found or (pay.payer_id<>uid and p.role<>'admin') or pay.status<>'refund_pending' or pay.provider_payment_id is null then raise exception 'Reembolso no disponible.' using errcode='42501';end if;
 if p.role='admin' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';end if;
 return jsonb_build_object('payment_id',pay.id,'provider_payment_id',pay.provider_payment_id,'refund_idempotency_key',pay.refund_idempotency_key,'amount_cents',pay.amount_cents);
end $$;
revoke all on function private.refund_checkout_v1(jsonb) from public,anon;
grant execute on function private.refund_checkout_v1(jsonb) to authenticated;

create function private.post_trip_tip_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();t public.trips;amount integer;method text;pay public.payments;
begin
 select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
 if uid is null or not found or t.passenger_id<>uid or t.status<>'completed' or t.driver_id is null then raise exception 'La propina sólo está disponible para un viaje completado.' using errcode='42501';end if;
 if t.tip_cents>0 then raise exception 'Este viaje ya incluye una propina.';end if;
 amount:=(payload->>'amount_cents')::integer;method:=payload->>'payment_method';
 if amount<100 or amount>100000 then raise exception 'La propina debe estar entre $1 y $1,000.';end if;
 if method='cash' then
   return jsonb_build_object('ok',true,'cash_confirmation_required',true);
 elsif method<>'card' then raise exception 'Selecciona un método de propina.';end if;
 if not (select mercado_pago_enabled from private.app_settings where id) then raise exception 'El pago con tarjeta aún no está activado.';end if;
 if exists(select 1 from public.payments where trip_id=t.id and kind='tip' and status in ('created','pending','in_process','approved')) then raise exception 'Ya existe una propina electrónica para este viaje.';end if;
 insert into public.payments(trip_id,payer_id,driver_id,kind,provider,amount_cents,status)
 values(t.id,uid,t.driver_id,'tip','mercado_pago',amount,'created') returning * into pay;
 return jsonb_build_object('payment_id',pay.id,'amount_cents',pay.amount_cents);
end $$;
revoke all on function private.post_trip_tip_v1(jsonb) from public,anon;
grant execute on function private.post_trip_tip_v1(jsonb) to authenticated;

create function private.submit_weekly_fee_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;fee public.weekly_fees;path_value text;
begin
 select * into p from public.profiles where id=uid;if not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
 select * into fee from public.weekly_fees where id=(payload->>'fee_id')::uuid and driver_id=uid for update;
 if not found or fee.status in ('paid','waived') then raise exception 'Cuota no disponible.';end if;
 path_value:=payload->>'proof_path';
 if not exists(select 1 from storage.objects where bucket_id='yavoi-payment-proofs' and name=path_value and (storage.foldername(name))[1]=uid::text) then raise exception 'Comprobante inválido.';end if;
 update public.weekly_fees set proof_path=path_value,status='submitted',submitted_at=now(),updated_at=now() where id=fee.id returning * into fee;
 return to_jsonb(fee);
end $$;
revoke all on function private.submit_weekly_fee_v1(jsonb) from public,anon;
grant execute on function private.submit_weekly_fee_v1(jsonb) to authenticated;

create function private.review_weekly_fee_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();fee public.weekly_fees;pay_id uuid;approved boolean;
begin
 if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501';end if;
 select * into fee from public.weekly_fees where id=(payload->>'fee_id')::uuid for update;if not found then raise exception 'Cuota no encontrada.';end if;
 approved:=coalesce((payload->>'approved')::boolean,false);
 if approved and fee.proof_path is null then raise exception 'El conductor no ha enviado comprobante.';end if;
 if approved then
   insert into public.payments(payer_id,driver_id,kind,provider,amount_cents,status,status_detail,provider_approved_at)
   values(fee.driver_id,fee.driver_id,'weekly_fee','manual',fee.amount_cents,'approved','proof_verified',now()) returning id into pay_id;
   update public.weekly_fees set status='paid',payment_id=pay_id,verified_by=uid,verified_at=now(),note=left(coalesce(payload->>'note',''),1000),updated_at=now() where id=fee.id;
   update public.drivers set account_active=true,updated_at=now() where id=fee.driver_id;
 else
   update public.weekly_fees set status='pending',proof_path=null,submitted_at=null,verified_by=uid,verified_at=now(),note=left(coalesce(payload->>'note',''),1000),updated_at=now() where id=fee.id;
 end if;
 insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'review_weekly_fee',fee.id,payload-'proof_path');
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.review_weekly_fee_v1(jsonb) from public,anon;
grant execute on function private.review_weekly_fee_v1(jsonb) to authenticated;

create function private.set_driver_access_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;active_value boolean;
begin
 if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501';end if;
 target:=(payload->>'driver_id')::uuid;active_value:=coalesce((payload->>'active')::boolean,false);
 update public.drivers set account_active=active_value,online=case when active_value then online else false end,updated_at=now() where id=target;
 if not found then raise exception 'Conductor no encontrado.';end if;
 insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'set_driver_access',target,jsonb_build_object('active',active_value,'note',left(coalesce(payload->>'note',''),500)));
 return jsonb_build_object('ok',true);
end $$;
revoke all on function private.set_driver_access_v1(jsonb) from public,anon;
grant execute on function private.set_driver_access_v1(jsonb) to authenticated;

create function public.yavoi_payment_event(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare pay public.payments;provider_status text;amount integer;event_key_value text;chosen uuid;
begin
 select * into pay from public.payments where id=(payload->>'external_reference')::uuid for update;
 if not found or pay.provider<>'mercado_pago' then raise exception 'Referencia de pago inválida.';end if;
 amount:=(payload->>'amount_cents')::integer;if amount<>pay.amount_cents then raise exception 'El importe recibido no coincide.';end if;
 provider_status:=payload->>'status';if provider_status not in ('pending','in_process','approved','rejected','cancelled','refunded') then provider_status:='pending';end if;
 if pay.provider_payment_id is not null and pay.provider_payment_id<>payload->>'provider_payment_id' then raise exception 'El identificador del proveedor no coincide.';end if;
 event_key_value:=left(coalesce(payload->>'event_key',(payload->>'provider_payment_id')||':'||provider_status),200);
 insert into public.payment_events(payment_id,provider,event_key,event_type,status,detail)
 values(pay.id,'mercado_pago',event_key_value,left(coalesce(payload->>'event_type','payment'),50),provider_status,jsonb_build_object('status_detail',left(coalesce(payload->>'status_detail',''),100))) on conflict do nothing;
 update public.payments set provider_payment_id=payload->>'provider_payment_id',status=provider_status,status_detail=left(coalesce(payload->>'status_detail',''),100),payment_method_type=left(coalesce(payload->>'payment_method_type',''),50),payment_method_id=left(coalesce(payload->>'payment_method_id',''),50),installments=nullif(payload->>'installments','')::integer,processing_fee_cents=coalesce((payload->>'processing_fee_cents')::integer,0),net_received_cents=coalesce((payload->>'net_received_cents')::integer,0),live_mode=nullif(payload->>'live_mode','')::boolean,provider_created_at=nullif(payload->>'provider_created_at','')::timestamptz,provider_approved_at=nullif(payload->>'provider_approved_at','')::timestamptz,updated_at=now() where id=pay.id returning * into pay;
 if pay.kind='ride' then
   if provider_status='approved' then
     if exists(select 1 from public.trips where id=pay.trip_id and status='cancelled') then
       update public.trips set payment_status='refund_pending',updated_at=now() where id=pay.trip_id;
       update public.payments set status='refund_pending',updated_at=now() where id=pay.id;
     else
       update public.trips set payment_status='paid',status=case when status='payment_pending' then case when scheduled_at is null then 'requested' else 'scheduled' end else status end,updated_at=now() where id=pay.trip_id;
       if exists(select 1 from public.trips where id=pay.trip_id and status='requested') then chosen:=private.auto_assign_trip(pay.trip_id,(select preferred_driver_id from public.trips where id=pay.trip_id));end if;
     end if;
   elsif provider_status in ('rejected','cancelled') then update public.trips set payment_status='failed',status=case when status='payment_pending' then 'cancelled' else status end,cancel_reason='Pago con tarjeta no aprobado.',updated_at=now() where id=pay.trip_id;
   elsif provider_status='refunded' then update public.trips set payment_status='refunded',updated_at=now() where id=pay.trip_id;
   end if;
 elsif pay.kind='tip' and provider_status='approved' then
   insert into public.ledger(trip_id,user_id,kind,amount_cents) values(pay.trip_id,pay.driver_id,'card_tip',pay.amount_cents) on conflict do nothing;
 elsif pay.kind='weekly_fee' and provider_status='approved' then
   update public.weekly_fees set status='paid',payment_id=pay.id,verified_at=now(),updated_at=now() where driver_id=pay.driver_id and payment_id is null and amount_cents=pay.amount_cents;
   update public.drivers set account_active=true,updated_at=now() where id=pay.driver_id;
 end if;
 return jsonb_build_object('ok',true,'status',provider_status,'assigned_driver_id',chosen);
end $$;
revoke all on function public.yavoi_payment_event(jsonb) from public,anon,authenticated;
grant execute on function public.yavoi_payment_event(jsonb) to service_role;

create function public.yavoi_map_cache_get(key_value text) returns jsonb language sql security definer set search_path='' as $$
 select payload from private.map_cache where cache_key=key_value and expires_at>now()
$$;
revoke all on function public.yavoi_map_cache_get(text) from public,anon,authenticated;
grant execute on function public.yavoi_map_cache_get(text) to service_role;

create function public.yavoi_map_cache_put(key_value text,payload_value jsonb,ttl_seconds integer) returns void language plpgsql security definer set search_path='' as $$
begin
 if char_length(key_value)>300 or octet_length(payload_value::text)>100000 or ttl_seconds not between 60 and 2592000 then raise exception 'Entrada de caché inválida.';end if;
 insert into private.map_cache(cache_key,payload,expires_at) values(key_value,payload_value,now()+make_interval(secs=>ttl_seconds))
 on conflict(cache_key) do update set payload=excluded.payload,expires_at=excluded.expires_at,created_at=now();
 delete from private.map_cache where expires_at<now()-interval '1 day';
end $$;
revoke all on function public.yavoi_map_cache_put(text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.yavoi_map_cache_put(text,jsonb,integer) to service_role;

create function public.yavoi_map_rate_limit(target_user uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare allowed boolean:=false;
begin
 insert into private.map_requests(user_id,last_request_at) values(target_user,now())
 on conflict(user_id) do update set last_request_at=now()
 where private.map_requests.last_request_at<now()-interval '1 second'
 returning true into allowed;
 return coalesce(allowed,false);
end $$;
revoke all on function public.yavoi_map_rate_limit(uuid) from public,anon,authenticated;
grant execute on function public.yavoi_map_rate_limit(uuid) to service_role;

create function private.offers_v3(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();d public.drivers;dp public.driver_presence;
begin
 select * into d from public.drivers where id=uid;
 if uid is null or not found or not d.approved or not d.online or not d.account_active or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then return '[]'::jsonb;end if;
 if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then return '[]'::jsonb;end if;
 select * into dp from public.driver_presence where driver_id=uid and updated_at>now()-interval '10 minutes';
 return (select coalesce(jsonb_agg(to_jsonb(x) order by x.pickup_from_driver_km nulls last,x.created_at),'[]') from (
   select t.id,t.origin,t.destination,t.fare_cents,t.fare_cents-t.commission_cents as net_cents,t.cash_tender_cents,t.category,
          t.women_only,t.accessible,t.scheduled_at,t.distance_km,t.trip_eta_minutes,t.pickup_eta_minutes,t.service_zone,t.created_at,
          t.payment_method,t.payment_status,t.tip_cents,t.total_cents,
          case when dp.driver_id is null then null else round(private.haversine_km(dp.lat,dp.lng,t.origin_lat,t.origin_lng)*1.22,2) end as pickup_from_driver_km
   from public.trips t where t.driver_id is null and (t.status='requested' or (t.status='scheduled' and t.scheduled_at<=now()+interval '15 minutes'))
   and t.category=d.category and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
   and (t.payment_method='cash' or t.payment_status='paid')
   order by pickup_from_driver_km nulls last,t.created_at limit 20
 )x);
end $$;
revoke all on function private.offers_v3(jsonb) from public,anon;
grant execute on function private.offers_v3(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v3(payload)
   when 'quote' then private.quote_v2(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v3(payload)
   when 'trip' then private.trip_v3(payload)
   when 'driver_profile' then private.driver_profile_v3(payload)
   when 'availability' then private.availability_v3(payload)
   when 'presence' then private.presence_v2(payload)
   when 'location' then private.location_v3(payload)
   when 'transition' then private.transition_v3(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v1(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'offers' then private.offers_v3(payload)
   when 'category' then private.category_v2(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;

alter publication supabase_realtime add table public.payments,public.weekly_fees,public.location_history;
