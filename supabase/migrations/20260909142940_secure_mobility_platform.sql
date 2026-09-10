-- All writes use checked transactions. Public tables are SELECT-only with RLS.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 role text not null default 'passenger' check(role in ('passenger','driver','admin')),
 full_name text not null default '' check(char_length(full_name)<=100),
 phone text not null default '' check(char_length(phone)<=25), avatar_path text,
 emergency_name text not null default '', emergency_phone text not null default '',
 onboarding_complete boolean not null default false, suspended boolean not null default false,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.categories (
 id text primary key, name text not null, seats integer not null, base_cents integer not null check(base_cents>=0),
 km_cents integer not null check(km_cents>=0), commission_bps integer not null default 2000 check(commission_bps between 0 and 5000),active boolean not null default true
);
insert into public.categories values ('basic','Básico',4,3500,900,2000,true),('large','Grande',6,5000,1200,2000,true),('commercial','Comercial',2,6500,1400,2000,true),('plus','Plus',4,5500,1300,2000,true),('pickup','Pickup',2,8000,1700,2000,true);
create table public.drivers (
 id uuid primary key references public.profiles(id) on delete cascade,
 approved boolean not null default false, online boolean not null default false,
 vehicle text not null default '', plate text not null default '', category text not null default 'basic' references public.categories(id),
 license_number text not null default '', license_expires date, insurance_expires date,
 license_path text, insurance_path text, female_verified boolean not null default false,
 accessible_verified boolean not null default false, advertising_interest boolean not null default false,
 review_note text not null default '', updated_at timestamptz not null default now()
);
create unique index unique_vehicle_plate on public.drivers(lower(plate)) where plate<>'';
create table public.quotes (
 id uuid primary key default gen_random_uuid(), passenger_id uuid not null references public.profiles(id),
 origin text not null, destination text not null, origin_lat double precision not null,origin_lng double precision not null,
 dest_lat double precision not null,dest_lng double precision not null,category text not null references public.categories(id),
 distance_km numeric not null, fare_cents integer not null check(fare_cents>0), commission_cents integer not null,
 women_only boolean not null default false, accessible boolean not null default false, scheduled_at timestamptz,
 expires_at timestamptz not null default now()+interval '5 minutes',created_at timestamptz not null default now()
);
create index quotes_owner on public.quotes(passenger_id,created_at desc);
create table public.trips (
 id uuid primary key default gen_random_uuid(), passenger_id uuid not null references public.profiles(id),
 driver_id uuid references public.drivers(id), quote_id uuid not null unique references public.quotes(id),
 request_key uuid not null, status text not null default 'requested' check(status in ('scheduled','requested','accepted','arrived','in_progress','completed','cancelled')),
 origin text not null,destination text not null,origin_lat double precision not null,origin_lng double precision not null,dest_lat double precision not null,dest_lng double precision not null,
 category text not null references public.categories(id),fare_cents integer not null check(fare_cents>0),commission_cents integer not null,
 payment_method text not null check(payment_method in ('cash','card')),
 cash_tender_cents integer check(cash_tender_cents>=0),payment_status text not null default 'pending' check(payment_status in ('pending','paid','refunded','failed')),
 women_only boolean not null default false,accessible boolean not null default false,
 scheduled_at timestamptz,cancel_reason text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),completed_at timestamptz,
 unique(passenger_id,request_key)
);
create unique index one_active_trip_per_passenger on public.trips(passenger_id) where status not in ('completed','cancelled','scheduled');
create unique index one_active_trip_per_driver on public.trips(driver_id) where driver_id is not null and status not in ('completed','cancelled');
create index trips_driver_date on public.trips(driver_id,created_at desc);
create index trips_passenger_date on public.trips(passenger_id,created_at desc);
create index dispatch_queue on public.trips(status,category,scheduled_at);
create table private.trip_secrets(trip_id uuid primary key references public.trips(id) on delete cascade,pin text not null,attempts integer not null default 0);
create table public.trip_events(id bigint generated always as identity primary key,trip_id uuid not null references public.trips(id),actor_id uuid references public.profiles(id),event text not null,detail jsonb not null default '{}',created_at timestamptz not null default now());
create index events_trip on public.trip_events(trip_id,created_at);
create table public.locations(trip_id uuid primary key references public.trips(id),driver_id uuid not null references public.drivers(id),lat double precision not null check(lat between -90 and 90),lng double precision not null check(lng between -180 and 180),accuracy double precision not null check(accuracy between 0 and 10000),updated_at timestamptz not null default now());
create index locations_driver on public.locations(driver_id);
create table public.messages(id bigint generated always as identity primary key,trip_id uuid not null references public.trips(id),sender_id uuid not null references public.profiles(id),body text not null check(char_length(body) between 1 and 1000),created_at timestamptz not null default now());
create index messages_trip on public.messages(trip_id,created_at);
create index messages_sender on public.messages(sender_id,created_at desc);
create table public.ratings(id uuid primary key default gen_random_uuid(),trip_id uuid not null references public.trips(id),author_id uuid not null references public.profiles(id),recipient_id uuid not null references public.profiles(id),stars integer not null check(stars between 1 and 5),comment text not null default '' check(char_length(comment)<=1000),comfort integer check(comfort between 1 and 5),safety integer check(safety between 1 and 5),created_at timestamptz not null default now(),unique(trip_id,author_id));
create index ratings_recipient on public.ratings(recipient_id);
create table public.complaints(id uuid primary key default gen_random_uuid(),owner_id uuid not null references public.profiles(id),trip_id uuid references public.trips(id),subject text not null,body text not null check(char_length(body) between 10 and 2000),status text not null default 'open' check(status in ('open','reviewing','resolved')),response text not null default '',created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index complaints_owner on public.complaints(owner_id,created_at desc);
create index complaints_trip on public.complaints(trip_id);
create table public.ledger(id uuid primary key default gen_random_uuid(),trip_id uuid not null references public.trips(id),user_id uuid not null references public.profiles(id),kind text not null check(kind in ('fare','commission','cash_tip')),amount_cents integer not null,created_at timestamptz not null default now(),unique(trip_id,user_id,kind));
create index ledger_user on public.ledger(user_id,created_at desc);
create table public.reward_entries(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles(id),trip_id uuid not null references public.trips(id),points integer not null,created_at timestamptz not null default now(),unique(user_id,trip_id));
create index rewards_trip on public.reward_entries(trip_id);
create table public.audit_log(id bigint generated always as identity primary key,actor_id uuid not null references public.profiles(id),action text not null,target_id uuid,detail jsonb not null default '{}',created_at timestamptz not null default now());
create index audit_actor on public.audit_log(actor_id,created_at desc);
create or replace function private.new_user() returns trigger language plpgsql security definer set search_path='' as $$ begin insert into public.profiles(id) values(new.id);return new;end $$;
revoke all on function private.new_user() from public,anon,authenticated;
create trigger yavoi_new_user after insert on auth.users for each row execute function private.new_user();
-- Backfill identity only, never a role from user-editable metadata.
insert into public.profiles(id) select id from auth.users on conflict do nothing;
create function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.profiles where id=auth.uid() and role='admin' and not suspended) $$;
revoke all on function private.is_admin() from public,anon;
grant execute on function private.is_admin() to authenticated;
create function private.is_participant(tid uuid) returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.trips t join public.profiles p on p.id=auth.uid() where t.id=tid and not p.suspended and (t.passenger_id=p.id or t.driver_id=p.id)) $$;
revoke all on function private.is_participant(uuid) from public,anon;
grant execute on function private.is_participant(uuid) to authenticated;
do $$ declare t text;begin foreach t in array array['profiles','categories','drivers','quotes','trips','trip_events','locations','messages','ratings','complaints','ledger','reward_entries','audit_log'] loop execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon, authenticated',t);execute format('grant select on public.%I to authenticated',t);end loop;end $$;
alter table private.trip_secrets enable row level security;
revoke all on private.trip_secrets from public,anon,authenticated;
create policy profile_own on public.profiles for select to authenticated using (id=(select auth.uid()) or (select private.is_admin()));
create policy category_read on public.categories for select to authenticated using(true);
create policy driver_own on public.drivers for select to authenticated using(id=(select auth.uid()) or (select private.is_admin()));
create policy quote_own on public.quotes for select to authenticated using(passenger_id=(select auth.uid()) or (select private.is_admin()));
create policy trip_own on public.trips for select to authenticated using(private.is_participant(id) or (select private.is_admin()));
create policy events_own on public.trip_events for select to authenticated using(private.is_participant(trip_id) or (select private.is_admin()));
create policy location_own on public.locations for select to authenticated using(private.is_participant(trip_id) or (select private.is_admin()));
create policy messages_own on public.messages for select to authenticated using(private.is_participant(trip_id) or (select private.is_admin()));
create policy ratings_own on public.ratings for select to authenticated using(author_id=(select auth.uid()) or recipient_id=(select auth.uid()) or (select private.is_admin()));
create policy complaints_own on public.complaints for select to authenticated using(owner_id=(select auth.uid()) or (select private.is_admin()));
create policy ledger_own on public.ledger for select to authenticated using(user_id=(select auth.uid()) or (select private.is_admin()));
create policy rewards_own on public.reward_entries for select to authenticated using(user_id=(select auth.uid()) or (select private.is_admin()));
create policy audit_admin on public.audit_log for select to authenticated using((select private.is_admin()));
-- Private uploads; no identity documents in public buckets.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values ('yavoi-documents','yavoi-documents',false,5242880,array['application/pdf','image/jpeg','image/png']),('yavoi-avatars','yavoi-avatars',false,2097152,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy yavoi_upload on storage.objects for insert to authenticated with check(bucket_id in ('yavoi-documents','yavoi-avatars') and (storage.foldername(name))[1]=(select auth.uid())::text and exists(select 1 from public.profiles where id=(select auth.uid()) and not suspended));
create policy yavoi_read_files on storage.objects for select to authenticated using(bucket_id in ('yavoi-documents','yavoi-avatars') and ((storage.foldername(name))[1]=(select auth.uid())::text or (select private.is_admin()) or (bucket_id='yavoi-avatars' and exists(select 1 from public.trips t where private.is_participant(t.id) and ((t.driver_id)::text=(storage.foldername(name))[1] or (t.passenger_id)::text=(storage.foldername(name))[1])))));
-- Dispatcher is non-exposed. Its public wrapper is invoker-only. Every command checks fresh DB permissions.
create function private.dispatch(command text,payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;d public.drivers;t public.trips;q public.quotes;c public.categories;target uuid;result jsonb;lat1 float8;lng1 float8;lat2 float8;lng2 float8;km numeric;amount integer;newstate text;pinvalue text;rolevalue text;ts timestamptz;
begin
 if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 select * into p from public.profiles where id=uid;
 if not found or p.suspended then raise exception 'Tu cuenta no está habilitada. Contacta a soporte.' using errcode='42501';end if;
 if jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 if command='bootstrap' then
  return jsonb_build_object('profile',to_jsonb(p),'driver',(select to_jsonb(x) from public.drivers x where id=uid),'categories',(select jsonb_agg(x order by base_cents) from public.categories x),'card_enabled',false);
 elsif command='onboard' then
  perform 1 from public.profiles where id=uid for update;
  if (select onboarding_complete from public.profiles where id=uid) then raise exception 'El perfil ya está registrado.';end if;
  rolevalue:=payload->>'role';if rolevalue not in ('passenger','driver') or rolevalue is null then raise exception 'Selecciona pasajero o conductor.';end if;
  if length(trim(coalesce(payload->>'name','')))<2 or length(trim(coalesce(payload->>'phone','')))<10 then raise exception 'Completa tu nombre y teléfono.';end if;
  update public.profiles set role=rolevalue,full_name=left(trim(payload->>'name'),100),phone=left(payload->>'phone',25),onboarding_complete=true,updated_at=now() where id=uid;
  if rolevalue='driver' then insert into public.drivers(id) values(uid);end if;
  return jsonb_build_object('ok',true);
 elsif command='profile' then
  if length(trim(coalesce(payload->>'name','')))<2 or length(coalesce(payload->>'phone',''))<10 then raise exception 'Completa nombre y teléfono.';end if;
  if payload->>'avatar_path' is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-avatars' and name=payload->>'avatar_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'La fotografía no pertenece a tu cuenta.';end if;
  update public.profiles set full_name=left(trim(payload->>'name'),100),phone=left(payload->>'phone',25),emergency_name=left(coalesce(payload->>'emergency_name',''),100),emergency_phone=left(coalesce(payload->>'emergency_phone',''),25),avatar_path=coalesce(payload->>'avatar_path',avatar_path),updated_at=now() where id=uid;
  return jsonb_build_object('ok',true);
 end if;
 if not p.onboarding_complete then raise exception 'Completa tu perfil para continuar.';end if;
 if command='dashboard' then
  return jsonb_build_object('trips',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (select * from public.trips where passenger_id=uid or driver_id=uid or p.role='admin' order by created_at desc limit 200) x),
  'complaints',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (select * from public.complaints where owner_id=uid or p.role='admin' order by created_at desc limit 100)x),
  'ledger',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (select * from public.ledger where user_id=uid or p.role='admin' order by created_at desc limit 500)x),
  'points',(select coalesce(sum(points),0) from public.reward_entries where user_id=uid),
  'rating',(select round(avg(stars),2) from public.ratings where recipient_id=uid),
  'drivers',case when p.role='admin' then (select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('full_name',pr.full_name,'phone',pr.phone)),'[]') from public.drivers x join public.profiles pr on pr.id=x.id) else '[]'::jsonb end,
  'audit',case when p.role='admin' then (select coalesce(jsonb_agg(x),'[]') from (select * from public.audit_log order by created_at desc limit 100)x) else '[]'::jsonb end);
 elsif command='driver_profile' then
  if p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de editar el expediente.';end if;
  if length(trim(coalesce(payload->>'vehicle','')))<3 or length(trim(coalesce(payload->>'plate','')))<5 then raise exception 'Completa modelo y placas.';end if;
  if payload->>'license_path' is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=payload->>'license_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'Licencia inválida.';end if;
  if payload->>'insurance_path' is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=payload->>'insurance_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'Póliza inválida.';end if;
  update public.drivers set vehicle=left(payload->>'vehicle',100),plate=upper(left(trim(payload->>'plate'),20)),category=payload->>'category',license_number=left(coalesce(payload->>'license_number',''),50),license_expires=nullif(payload->>'license_expires','')::date,insurance_expires=nullif(payload->>'insurance_expires','')::date,license_path=coalesce(payload->>'license_path',license_path),insurance_path=coalesce(payload->>'insurance_path',insurance_path),advertising_interest=coalesce((payload->>'advertising_interest')::boolean,false),approved=false,online=false,updated_at=now() where id=uid;
  return jsonb_build_object('ok',true);
 elsif command='availability' then
  select * into d from public.drivers where id=uid for update;
  if p.role<>'driver' or not found then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
  if coalesce((payload->>'online')::boolean,false) and (not d.approved or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then raise exception 'Tu expediente debe estar aprobado y vigente.';end if;
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de desconectarte.';end if;
  update public.drivers set online=coalesce((payload->>'online')::boolean,false),updated_at=now() where id=uid;return jsonb_build_object('ok',true);
 elsif command='quote' then
  if p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
  if (select count(*) from public.quotes where passenger_id=uid and created_at>now()-interval '1 minute')>=15 then raise exception 'Espera un minuto antes de volver a cotizar.';end if;
  lat1:=(payload->>'origin_lat')::float8;lng1:=(payload->>'origin_lng')::float8;lat2:=(payload->>'dest_lat')::float8;lng2:=(payload->>'dest_lng')::float8;
  if lat1 is null or lng1 is null or lat2 is null or lng2 is null or not(lat1 between 28.0 and 28.4 and lat2 between 28.0 and 28.4 and lng1 between -105.7 and -105.2 and lng2 between -105.7 and -105.2) then raise exception 'Selecciona puntos dentro de la cobertura de Delicias y Meoqui.';end if;
  if length(trim(coalesce(payload->>'origin','')))<3 or length(trim(coalesce(payload->>'destination','')))<3 then raise exception 'Indica las direcciones.';end if;
  select * into c from public.categories where id=payload->>'category' and active;
  if not found then raise exception 'Categoría no disponible.';end if;
  km:=round((6371*2*asin(sqrt(least(1,power(sin(radians(lat2-lat1)/2),2)+cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2)))))::numeric,2);
  if km<0.1 then raise exception 'El destino debe estar al menos a 100 metros.';end if;
  amount:=c.base_cents+ceil(km*c.km_cents)::integer;
  ts:=nullif(payload->>'scheduled_at','')::timestamptz;if ts is not null and (ts<now()+interval '15 minutes' or ts>now()+interval '30 days') then raise exception 'Programa entre 15 minutos y 30 días de anticipación.';end if;
  insert into public.quotes(passenger_id,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,distance_km,fare_cents,commission_cents,women_only,accessible,scheduled_at) values(uid,left(payload->>'origin',200),left(payload->>'destination',200),lat1,lng1,lat2,lng2,c.id,km,amount,round(amount*c.commission_bps/10000.0),coalesce((payload->>'women_only')::boolean,false),coalesce((payload->>'accessible')::boolean,false),ts) returning * into q;
  return to_jsonb(q);
 elsif command='request_trip' then
  if p.role<>'passenger' then raise exception 'Acceso de pasajero requerido.' using errcode='42501';end if;
  perform 1 from public.profiles where id=uid for update;
  select * into t from public.trips where passenger_id=uid and request_key=(payload->>'request_key')::uuid;
  if found then return to_jsonb(t);end if;
  select * into q from public.quotes where id=(payload->>'quote_id')::uuid and passenger_id=uid for update;
  if not found or q.expires_at<now() then raise exception 'La cotización venció. Calcula una nueva tarifa.';end if;
  if payload->>'payment_method'<>'cash' or payload->>'payment_method' is null then raise exception 'Tarjeta aún no disponible. Selecciona efectivo.';end if;
  amount:=coalesce((payload->>'cash_tender_cents')::integer,q.fare_cents);
  if amount<q.fare_cents or amount>100000 then raise exception 'Indica un monto de efectivo válido, hasta $1,000.';end if;
  if exists(select 1 from public.trips where passenger_id=uid and status not in ('completed','cancelled','scheduled')) then raise exception 'Ya tienes un viaje activo.';end if;
  if (select count(*) from public.trips where passenger_id=uid and created_at>now()-interval '1 hour')>=10 then raise exception 'Límite de solicitudes alcanzado. Intenta más tarde.';end if;
  insert into public.trips(passenger_id,quote_id,request_key,status,origin,destination,origin_lat,origin_lng,dest_lat,dest_lng,category,fare_cents,commission_cents,payment_method,cash_tender_cents,women_only,accessible,scheduled_at) values(uid,q.id,(payload->>'request_key')::uuid,case when q.scheduled_at is null then 'requested' else 'scheduled' end,q.origin,q.destination,q.origin_lat,q.origin_lng,q.dest_lat,q.dest_lng,q.category,q.fare_cents,q.commission_cents,'cash',amount,q.women_only,q.accessible,q.scheduled_at) returning * into t;
  pinvalue:=lpad((floor(random()*9000)+1000)::text,4,'0');insert into private.trip_secrets(trip_id,pin) values(t.id,pinvalue);
  insert into public.trip_events(trip_id,actor_id,event) values(t.id,uid,t.status);return to_jsonb(t);
 elsif command='offers' then
  select * into d from public.drivers where id=uid;
  if p.role<>'driver' or not d.approved or not d.online or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then return '[]'::jsonb;end if;
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then return '[]'::jsonb;end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'origin',x.origin,'destination',x.destination,'fare_cents',x.fare_cents,'net_cents',x.fare_cents-x.commission_cents,'cash_tender_cents',x.cash_tender_cents,'category',x.category,'women_only',x.women_only,'accessible',x.accessible,'scheduled_at',x.scheduled_at)),'[]') from (select * from public.trips where driver_id is null and (status='requested' or (status='scheduled' and scheduled_at<=now()+interval '15 minutes')) and category=d.category and (not women_only or d.female_verified) and (not accessible or d.accessible_verified) order by created_at limit 20)x);
 elsif command='accept' then
  select * into d from public.drivers where id=uid for update;
  if p.role<>'driver' or not found or not d.approved or not d.online or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) then raise exception 'Conductor no disponible o expediente vencido.' using errcode='42501';end if;
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Ya tienes un viaje asignado.';end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
  if not found or t.driver_id is not null or not(t.status='requested' or (t.status='scheduled' and t.scheduled_at<=now()+interval '15 minutes')) then raise exception 'La solicitud ya no está disponible.';end if;
  if t.category<>d.category or(t.women_only and not d.female_verified)or(t.accessible and not d.accessible_verified) then raise exception 'La unidad no cumple los requisitos.';end if;
  perform 1 from public.profiles where id=t.passenger_id for update;
  if exists(select 1 from public.trips where passenger_id=t.passenger_id and id<>t.id and status not in ('scheduled','completed','cancelled')) then raise exception 'El pasajero tiene otro viaje activo.';end if;
  update public.trips set driver_id=uid,status='accepted',updated_at=now() where id=t.id returning * into t;
  insert into public.trip_events(trip_id,actor_id,event) values(t.id,uid,'accepted');return to_jsonb(t);
 elsif command in ('trip','transition','message','location','rating','tip') then
  select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
  if not found or not(t.passenger_id=uid or t.driver_id=uid or p.role='admin') then raise exception 'No tienes acceso a este viaje.' using errcode='42501';end if;
  if command='trip' then
   return jsonb_build_object('trip',to_jsonb(t),'pin',case when t.passenger_id=uid and t.status not in ('completed','cancelled') then (select pin from private.trip_secrets where trip_id=t.id) else null end,
   'passenger',(select jsonb_build_object('name',full_name,'avatar_path',avatar_path) from public.profiles where id=t.passenger_id),
   'driver',(select jsonb_build_object('name',pr.full_name,'avatar_path',pr.avatar_path,'vehicle',dr.vehicle,'plate',dr.plate,'rating',(select round(avg(stars),2) from public.ratings where recipient_id=dr.id)) from public.drivers dr join public.profiles pr on pr.id=dr.id where dr.id=t.driver_id),
   'location',(select to_jsonb(x) from public.locations x where trip_id=t.id),
   'messages',(select coalesce(jsonb_agg(x order by created_at),'[]') from (select * from public.messages where trip_id=t.id order by created_at desc limit 100)x),
   'events',(select coalesce(jsonb_agg(x order by created_at),'[]') from public.trip_events x where trip_id=t.id),
   'my_rating',(select to_jsonb(x) from public.ratings x where trip_id=t.id and author_id=uid));
  elsif command='transition' then
   newstate:=payload->>'status';
   if newstate='cancelled' then
    if t.status in ('completed','cancelled') then raise exception 'El viaje ya finalizó.';end if;
    if t.status='in_progress' and p.role<>'admin' then raise exception 'Durante el recorrido solicita apoyo a Operaciones.';end if;
    if length(trim(coalesce(payload->>'reason','')))<5 then raise exception 'Escribe el motivo de cancelación.';end if;
   else
    if t.driver_id is distinct from uid or p.role<>'driver' then raise exception 'Sólo el conductor asignado puede avanzar el viaje.' using errcode='42501';end if;
    if not exists(select 1 from public.drivers where id=uid and approved) then raise exception 'Tu autorización de conductor no está vigente.';end if;
    if not ((t.status='accepted' and newstate='arrived')or(t.status='arrived' and newstate='in_progress')or(t.status='in_progress' and newstate='completed')) then raise exception 'Cambio de estado no permitido.';end if;
    if newstate='in_progress' then
     if (select attempts from private.trip_secrets where trip_id=t.id)>=5 then return jsonb_build_object('error','PIN bloqueado. Solicita ayuda a Operaciones.');end if;
     if (select pin from private.trip_secrets where trip_id=t.id) is distinct from payload->>'pin' then update private.trip_secrets set attempts=attempts+1 where trip_id=t.id;return jsonb_build_object('error','PIN incorrecto. Solicítalo al pasajero.');end if;
    end if;
    if newstate='completed' and coalesce((payload->>'cash_received')::boolean,false)<>true then raise exception 'Confirma que recibiste el efectivo y entregaste el cambio.';end if;
   end if;
   update public.trips set status=newstate,cancel_reason=case when newstate='cancelled' then left(payload->>'reason',500) else null end,payment_status=case when newstate='completed' then 'paid' else payment_status end,completed_at=case when newstate='completed' then now() else null end,updated_at=now() where id=t.id returning * into t;
   if newstate='completed' then
    insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,t.driver_id,'fare',t.fare_cents),(t.id,t.driver_id,'commission',-t.commission_cents) on conflict do nothing;
    insert into public.reward_entries(user_id,trip_id,points) values(t.passenger_id,t.id,10),(t.driver_id,t.id,10) on conflict do nothing;
   end if;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,uid,newstate,jsonb_build_object('reason',t.cancel_reason));
   if p.role='admin' then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'cancel_trip',t.id,jsonb_build_object('reason',t.cancel_reason));end if;
   return to_jsonb(t);
  elsif command='message' then
   if uid not in (t.passenger_id,t.driver_id) or t.driver_id is null or t.status in ('completed','cancelled') then raise exception 'El chat sólo está disponible durante un viaje asignado.';end if;
   if length(trim(coalesce(payload->>'body','')))<1 or length(payload->>'body')>1000 then raise exception 'Escribe un mensaje de hasta 1,000 caracteres.';end if;
   if (select count(*) from public.messages where sender_id=uid and created_at>now()-interval '1 minute')>=20 then raise exception 'Espera antes de enviar más mensajes.';end if;
   insert into public.messages(trip_id,sender_id,body) values(t.id,uid,trim(payload->>'body'));return jsonb_build_object('ok',true);
  elsif command='location' then
   if t.driver_id is distinct from uid or t.status not in ('accepted','arrived','in_progress') then raise exception 'Ubicación no permitida.' using errcode='42501';end if;
   if exists(select 1 from public.locations where trip_id=t.id and updated_at>now()-interval '4 seconds') then return jsonb_build_object('ok',true);end if;
   insert into public.locations(trip_id,driver_id,lat,lng,accuracy) values(t.id,uid,(payload->>'lat')::float8,(payload->>'lng')::float8,(payload->>'accuracy')::float8) on conflict(trip_id) do update set lat=excluded.lat,lng=excluded.lng,accuracy=excluded.accuracy,updated_at=now();return jsonb_build_object('ok',true);
  elsif command='rating' then
   if t.status<>'completed' or uid not in(t.passenger_id,t.driver_id) then raise exception 'Sólo los participantes pueden evaluar un viaje completado.';end if;
   insert into public.ratings(trip_id,author_id,recipient_id,stars,comment,comfort,safety) values(t.id,uid,case when uid=t.passenger_id then t.driver_id else t.passenger_id end,(payload->>'stars')::integer,left(coalesce(payload->>'comment',''),1000),nullif(payload->>'comfort','')::integer,nullif(payload->>'safety','')::integer) on conflict(trip_id,author_id) do nothing;return jsonb_build_object('ok',true);
  elsif command='tip' then
   if t.driver_id is distinct from uid or t.status<>'completed' then raise exception 'Sólo el conductor registra propinas recibidas en efectivo.';end if;
   amount:=(payload->>'amount_cents')::integer;if amount is null or amount<100 or amount>100000 then raise exception 'Propina inválida.';end if;
   insert into public.ledger(trip_id,user_id,kind,amount_cents) values(t.id,uid,'cash_tip',amount) on conflict(trip_id,user_id,kind) do nothing;return jsonb_build_object('ok',true);
  end if;
 elsif command='complaint' then
  target:=nullif(payload->>'trip_id','')::uuid;if target is not null and not private.is_participant(target) then raise exception 'Viaje no disponible.' using errcode='42501';end if;
  if (select count(*) from public.complaints where owner_id=uid and created_at>now()-interval '1 hour')>=5 then raise exception 'Límite de reportes alcanzado. Intenta más tarde.';end if;
  insert into public.complaints(owner_id,trip_id,subject,body) values(uid,target,left(coalesce(payload->>'subject','General'),100),payload->>'body') returning id into target;return jsonb_build_object('id',target);
 elsif command in ('review_driver','resolve_complaint','category','reset_pin') then
  if p.role<>'admin' then raise exception 'Sólo Operaciones puede realizar esta acción.' using errcode='42501';end if;
  if command='review_driver' then
   target:=(payload->>'driver_id')::uuid;select * into d from public.drivers where id=target for update;if not found then raise exception 'Conductor no encontrado.';end if;
   if length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Registra el resultado de tu revisión.';end if;
   if coalesce((payload->>'approved')::boolean,false) and (d.vehicle='' or d.plate='' or d.license_number='' or d.license_path is null or d.insurance_path is null or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true) or not exists(select 1 from public.profiles where id=target and avatar_path is not null)) then raise exception 'Faltan fotografía, documentos o vigencias en el expediente.';end if;
   if exists(select 1 from public.trips where driver_id=target and status not in ('completed','cancelled')) then raise exception 'Resuelve el viaje activo antes de cambiar la autorización.';end if;
   update public.drivers set approved=coalesce((payload->>'approved')::boolean,false),online=false,female_verified=coalesce((payload->>'female_verified')::boolean,false),accessible_verified=coalesce((payload->>'accessible_verified')::boolean,false),review_note=left(payload->>'note',1000),updated_at=now() where id=target;
  elsif command='resolve_complaint' then
   target:=(payload->>'id')::uuid;if length(trim(coalesce(payload->>'response','')))<5 then raise exception 'Escribe una respuesta.';end if;
   update public.complaints set status=payload->>'status',response=left(payload->>'response',2000),updated_at=now() where id=target;if not found then raise exception 'Reporte no encontrado.';end if;
  elsif command='category' then
   update public.categories set base_cents=(payload->>'base_cents')::integer,km_cents=(payload->>'km_cents')::integer,commission_bps=(payload->>'commission_bps')::integer,active=(payload->>'active')::boolean where id=payload->>'id';if not found then raise exception 'Categoría no encontrada.';end if;
  elsif command='reset_pin' then
   target:=(payload->>'trip_id')::uuid;if not exists(select 1 from public.trips where id=target and status='arrived') then raise exception 'El viaje no está esperando el PIN.';end if;
   update private.trip_secrets set attempts=0,pin=lpad((floor(random()*9000)+1000)::text,4,'0') where trip_id=target;
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,command,target,payload);return jsonb_build_object('ok',true);
 end if;
 raise exception 'Operación no disponible.';
end $$;
revoke all on function private.dispatch(text,jsonb) from public,anon;
grant execute on function private.dispatch(text,jsonb) to authenticated;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$ select private.dispatch(command,payload) $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
-- Realtime emits only rows allowed by each subscriber's RLS.
alter publication supabase_realtime add table public.trips,public.locations,public.messages,public.complaints;
-- One-time administrator enrollment bound to a verified mailbox chosen by the owner.
create table private.admin_enrollment(email text primary key,claimed_by uuid unique references auth.users(id),claimed_at timestamptz);
alter table private.admin_enrollment enable row level security;
revoke all on private.admin_enrollment from public,anon,authenticated;
insert into private.admin_enrollment(email) values('administracion@yavoi.com');
create function private.enroll_admin() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.email_confirmed_at is not null then
  update private.admin_enrollment set claimed_by=new.id,claimed_at=now() where email=lower(new.email) and claimed_by is null;
  if found then
   insert into public.profiles(id,role,onboarding_complete,full_name) values(new.id,'admin',true,'Administración Yavoi!') on conflict(id) do update set role='admin',onboarding_complete=true;
   insert into public.audit_log(actor_id,action,target_id) values(new.id,'verified_initial_admin',new.id);
  end if;
 end if;return new;
end $$;
revoke all on function private.enroll_admin() from public,anon,authenticated;
create trigger zz_yavoi_admin after insert or update of email_confirmed_at,email on auth.users for each row execute function private.enroll_admin();
