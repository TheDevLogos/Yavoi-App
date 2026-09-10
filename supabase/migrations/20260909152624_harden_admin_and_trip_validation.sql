create or replace function private.dispatch(command text,payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;d public.drivers;t public.trips;q public.quotes;c public.categories;target uuid;result jsonb;lat1 float8;lng1 float8;lat2 float8;lng2 float8;km numeric;amount integer;newstate text;pinvalue text;rolevalue text;ts timestamptz;
begin
 if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
 select * into p from public.profiles where id=uid;
 if not found or p.suspended then raise exception 'Tu cuenta no está habilitada. Contacta a soporte.' using errcode='42501';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
 if not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Verifica tu correo para continuar.' using errcode='42501';end if;
 if p.role='admin' and command<>'bootstrap' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501';end if;
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
  'drivers',case when p.role='admin' then (select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('full_name',pr.full_name,'phone',pr.phone,'avatar_path',pr.avatar_path)),'[]') from public.drivers x join public.profiles pr on pr.id=x.id) else '[]'::jsonb end,
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
  pinvalue:=lpad((((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,4))::bit(16)::int % 9000)+1000))::text,4,'0');insert into private.trip_secrets(trip_id,pin) values(t.id,pinvalue);
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
   update private.trip_secrets set attempts=0,pin=lpad((((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,4))::bit(16)::int % 9000)+1000))::text,4,'0') where trip_id=target;
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,command,target,payload);return jsonb_build_object('ok',true);
 end if;
 raise exception 'Operación no disponible.';
end $$;

create or replace function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and coalesce(auth.jwt()->>'aal','aal1')='aal2' and exists(select 1 from public.profiles where id=auth.uid() and role='admin' and not suspended) $$;
create policy no_direct_secret_access on private.trip_secrets for all to authenticated using(false) with check(false);
create policy no_direct_enrollment_access on private.admin_enrollment for all to authenticated using(false) with check(false);
alter table public.categories add constraint bounded_pilot_rates check(base_cents between 0 and 100000 and km_cents between 0 and 10000);
