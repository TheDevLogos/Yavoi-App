-- Controls supporting Title V, Chapters II-IV of the Chihuahua Transport Law.
-- Existing approved drivers remain available while Operations completes the new
-- legal dossier. Enforcement can only be enabled once the company and every
-- approved driver are ready.

alter table public.drivers
  add column birth_date date,
  add column government_id_path text,
  add column transport_card_number text not null default '',
  add column transport_card_expires date,
  add column transport_card_path text,
  add column vehicle_registration_path text,
  add column vehicle_registration_expires date,
  add column vin text not null default '',
  add column hologram_number text not null default '',
  add column hologram_expires date,
  add column vehicle_verification_path text,
  add column vehicle_verification_expires date,
  add column vehicle_verification_not_applicable boolean not null default false,
  add column mechanical_inspection_path text,
  add column mechanical_inspection_expires date,
  add column tax_compliance_path text,
  add column tax_compliance_expires date,
  add column seatbelts_all boolean not null default false,
  add column front_airbags boolean not null default false,
  add column abs_brakes boolean not null default false,
  add column first_service_tools boolean not null default false,
  add column extinguisher_abc boolean not null default false,
  add column four_doors boolean not null default false,
  add column tint_percent integer check(tint_percent between 0 and 100),
  add column air_conditioning boolean not null default false,
  add column reflective_markings boolean not null default false,
  add column affiliation_number text,
  add column affiliation_issued_at timestamptz,
  add column affiliation_expires date;

alter table public.trips
  add column regulatory_terms_version text,
  add column regulatory_terms_accepted_at timestamptz;

create unique index drivers_affiliation_number_unique on public.drivers(affiliation_number)
  where affiliation_number is not null;
create index drivers_transport_card_expiry on public.drivers(transport_card_expires)
  where transport_card_expires is not null;
create index drivers_vehicle_registration_expiry on public.drivers(vehicle_registration_expires)
  where vehicle_registration_expires is not null;

create table private.transport_compliance_settings (
  id boolean primary key default true check(id),
  legal_name text not null default '',
  rfc text not null default '',
  state_authorization_number text not null default '',
  authorization_issued_at date,
  authorization_expires date,
  collaboration_agreement_at date,
  company_policy_number text not null default '',
  company_insurer text not null default '',
  company_policy_path text,
  company_policy_starts_at date,
  company_policy_expires_at date,
  company_policy_coverage_cents bigint not null default 0 check(company_policy_coverage_cents>=0),
  company_policy_coverage_uma numeric(8,2) not null default 0 check(company_policy_coverage_uma>=0),
  mobility_fund_bps integer not null default 150 check(mobility_fund_bps between 0 and 10000),
  receipt_email_enabled boolean not null default false,
  authority_reporting_channel text not null default '',
  enforcement_mode text not null default 'monitor' check(enforcement_mode in ('monitor','enforce')),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
insert into private.transport_compliance_settings(id) values(true) on conflict do nothing;
alter table private.transport_compliance_settings enable row level security;
revoke all on private.transport_compliance_settings from public,anon,authenticated;

create table public.trip_regulatory_records (
  trip_id uuid primary key references public.trips(id) on delete restrict,
  passenger_id uuid not null references public.profiles(id),
  driver_id uuid references public.drivers(id),
  request_snapshot jsonb not null default '{}',
  assignment_snapshot jsonb not null default '{}',
  completion_snapshot jsonb not null default '{}',
  assigned_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  retention_until timestamptz not null,
  receipt_status text not null default 'not_due' check(receipt_status in ('not_due','pending','sent','failed')),
  receipt_sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index trip_regulatory_retention on public.trip_regulatory_records(retention_until);
create index trip_regulatory_receipts on public.trip_regulatory_records(receipt_status,completed_at)
  where receipt_status in ('pending','failed');
alter table public.trip_regulatory_records enable row level security;
revoke all on public.trip_regulatory_records from anon,authenticated;
-- The raw snapshots contain identity and vehicle evidence. They are never
-- exposed directly; trip_v10 returns a participant-safe projection and the
-- MFA-protected Operations functions read the complete record.

create table private.trip_receipt_outbox (
  trip_id uuid primary key references public.trips(id) on delete restrict,
  recipient_email text not null,
  payload jsonb not null,
  status text not null default 'pending' check(status in ('pending','processing','sent','failed')),
  attempts integer not null default 0 check(attempts between 0 and 20),
  last_error text not null default '',
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table private.trip_receipt_outbox enable row level security;
revoke all on private.trip_receipt_outbox from public,anon,authenticated;

alter table public.complaints
  add column suspected_crime boolean not null default false,
  add column authority_report_status text not null default 'not_required'
    check(authority_report_status in ('not_required','pending','reported')),
  add column authority_reported_at timestamptz,
  add column authority_reference text not null default '' check(char_length(authority_reference)<=500);
create index complaints_authority_queue on public.complaints(authority_report_status,created_at)
  where authority_report_status='pending';

create or replace function private.driver_legal_missing_v1(target uuid) returns text[]
language sql stable security definer set search_path='' as $$
  select coalesce(array_agg(label order by sort_order) filter(where not ok),array[]::text[])
  from public.drivers d
  cross join lateral (values
      (1,'Mayoría de edad',coalesce(d.birth_date<=current_date-interval '18 years',false)),
      (2,'Identificación oficial del propietario',d.government_id_path is not null),
      (3,'Licencia vigente',d.license_path is not null and d.license_expires>=current_date),
      (4,'Tarjetón anual',d.transport_card_path is not null and length(trim(d.transport_card_number))>=3 and d.transport_card_expires>=current_date),
      (5,'Póliza particular vigente',d.insurance_path is not null and d.insurance_expires>=current_date),
      (6,'Tarjeta de circulación vigente',d.vehicle_registration_path is not null and d.vehicle_registration_expires>=current_date),
      (7,'Número de identificación vehicular',d.vin~'^[A-HJ-NPR-Z0-9]{17}$'),
      (8,'Holograma vigente',length(trim(d.hologram_number))>=2 and d.hologram_expires>=current_date),
      (9,'Verificación vehicular',d.vehicle_verification_not_applicable or (d.vehicle_verification_path is not null and d.vehicle_verification_expires>=current_date)),
      (10,'Revisión mecánica y de seguridad',d.mechanical_inspection_path is not null and d.mechanical_inspection_expires>=current_date),
      (11,'Cumplimiento fiscal',d.tax_compliance_path is not null and d.tax_compliance_expires>=current_date),
      (12,'Antigüedad máxima de siete años',d.vehicle_year between extract(year from current_date)::integer-7 and extract(year from current_date)::integer+1),
      (13,'Cinturones para todas las plazas',d.seatbelts_all),
      (14,'Bolsas de aire frontales',d.front_airbags),
      (15,'Frenos ABS',d.abs_brakes),
      (16,'Herramientas de primer servicio',d.first_service_tools),
      (17,'Extinguidor ABC',d.extinguisher_abc),
      (18,'Unidad de al menos cuatro puertas',d.four_doors),
      (19,'Entintado o polarizado permitido',d.tint_percent is not null and d.tint_percent<=20),
      (20,'Aire acondicionado',d.air_conditioning),
      (21,'Señalamientos reflejantes',d.reflective_markings),
      (22,'Fotografía frontal y placa',d.vehicle_front_path is not null),
      (23,'Carta de políticas Yavoi! firmada',d.policy_commitment_path is not null),
      (24,'Carta de obligaciones viales firmada',d.traffic_law_commitment_path is not null)
    ) as requirement(sort_order,label,ok)
  where d.id=target
$$;
revoke all on function private.driver_legal_missing_v1(uuid) from public,anon,authenticated;

create or replace function private.driver_dossier_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.profiles p on p.id=d.id
    where d.id=target and length(trim(p.full_name))>=2 and length(trim(p.phone))>=10
      and p.avatar_path is not null and length(trim(d.vehicle_make))>=2 and length(trim(d.vehicle_model))>=1
      and length(trim(d.vehicle_color))>=3 and length(trim(d.plate))>=5
      and d.policy_commitment_path is not null and d.traffic_law_commitment_path is not null
      and cardinality(private.driver_legal_missing_v1(target))=0
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars' and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-vehicle-photos' and o.name=d.vehicle_front_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.driver_dossier_complete(uuid) from public,anon,authenticated;

create function private.company_transport_ready_v1() returns boolean
language sql stable security definer set search_path='' as $$
  select length(trim(legal_name))>=3 and length(trim(rfc))>=12
    and length(trim(state_authorization_number))>=3 and authorization_expires>=current_date
    and collaboration_agreement_at is not null and length(trim(company_policy_number))>=3
    and length(trim(company_insurer))>=3 and company_policy_path is not null
    and company_policy_starts_at<=current_date and company_policy_expires_at>=current_date
    and company_policy_coverage_cents>0 and company_policy_coverage_uma>=32
  from private.transport_compliance_settings where id
$$;
revoke all on function private.company_transport_ready_v1() from public,anon,authenticated;

create function private.driver_profile_v8(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result jsonb;path_key text;path_value text;complete_value boolean;
begin
  foreach path_key in array array['government_id_path','transport_card_path','vehicle_registration_path','vehicle_verification_path','mechanical_inspection_path','tax_compliance_path'] loop
    path_value:=nullif(payload->>path_key,'');
    if path_value is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=path_value and (storage.foldername(name))[1]=uid::text) then
      raise exception 'Documento regulatorio inválido o ajeno a tu cuenta.';
    end if;
  end loop;
  if nullif(payload->>'birth_date','')::date>current_date-interval '18 years' then raise exception 'El conductor debe ser mayor de edad.';end if;
  if nullif(payload->>'vin','') is not null and upper(trim(payload->>'vin'))!~'^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'El NIV debe contener 17 caracteres válidos.';end if;
  if nullif(payload->>'tint_percent','')::integer not between 0 and 20 then raise exception 'El entintado o polarizado no puede exceder 20%%.';end if;
  result:=private.driver_profile_v7(payload);
  update public.drivers set
    birth_date=nullif(payload->>'birth_date','')::date,
    government_id_path=coalesce(nullif(payload->>'government_id_path',''),government_id_path),
    transport_card_number=left(upper(trim(coalesce(payload->>'transport_card_number',''))),50),
    transport_card_expires=nullif(payload->>'transport_card_expires','')::date,
    transport_card_path=coalesce(nullif(payload->>'transport_card_path',''),transport_card_path),
    vehicle_registration_path=coalesce(nullif(payload->>'vehicle_registration_path',''),vehicle_registration_path),
    vehicle_registration_expires=nullif(payload->>'vehicle_registration_expires','')::date,
    vin=left(upper(trim(coalesce(payload->>'vin',''))),17),
    hologram_number=left(upper(trim(coalesce(payload->>'hologram_number',''))),50),
    hologram_expires=nullif(payload->>'hologram_expires','')::date,
    vehicle_verification_path=coalesce(nullif(payload->>'vehicle_verification_path',''),vehicle_verification_path),
    vehicle_verification_expires=nullif(payload->>'vehicle_verification_expires','')::date,
    vehicle_verification_not_applicable=coalesce((payload->>'vehicle_verification_not_applicable')::boolean,false),
    mechanical_inspection_path=coalesce(nullif(payload->>'mechanical_inspection_path',''),mechanical_inspection_path),
    mechanical_inspection_expires=nullif(payload->>'mechanical_inspection_expires','')::date,
    tax_compliance_path=coalesce(nullif(payload->>'tax_compliance_path',''),tax_compliance_path),
    tax_compliance_expires=nullif(payload->>'tax_compliance_expires','')::date,
    seatbelts_all=coalesce((payload->>'seatbelts_all')::boolean,false),front_airbags=coalesce((payload->>'front_airbags')::boolean,false),
    abs_brakes=coalesce((payload->>'abs_brakes')::boolean,false),first_service_tools=coalesce((payload->>'first_service_tools')::boolean,false),
    extinguisher_abc=coalesce((payload->>'extinguisher_abc')::boolean,false),four_doors=coalesce((payload->>'four_doors')::boolean,false),
    tint_percent=nullif(payload->>'tint_percent','')::integer,air_conditioning=coalesce((payload->>'air_conditioning')::boolean,false),
    reflective_markings=coalesce((payload->>'reflective_markings')::boolean,false),updated_at=now()
  where id=uid;
  complete_value:=private.driver_dossier_complete(uid);
  if complete_value then update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid;end if;
  return result||jsonb_build_object('complete',complete_value,'legal_missing',to_jsonb(private.driver_legal_missing_v1(uid)));
end $$;
revoke all on function private.driver_profile_v8(jsonb) from public,anon;
grant execute on function private.driver_profile_v8(jsonb) to authenticated;

create function private.review_driver_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid:=(payload->>'driver_id')::uuid;result jsonb;
begin
  if auth.uid() is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede revisar conductores.' using errcode='42501';
  end if;
  if coalesce((payload->>'approved')::boolean,false) and not private.driver_dossier_complete(target) then
    raise exception 'Faltan requisitos de identidad, licencia, tarjetón, circulación, seguro, revisión, fiscalidad o equipo de seguridad.';
  end if;
  result:=private.review_driver_v2(payload);
  if coalesce((payload->>'approved')::boolean,false) then
    update public.drivers set affiliation_number=coalesce(affiliation_number,'YV-'||upper(substr(md5(id::text),1,12))),
      affiliation_issued_at=coalesce(affiliation_issued_at,now()),affiliation_expires=license_expires,updated_at=now()
    where id=target;
  end if;
  return result||jsonb_build_object('affiliation_number',(select affiliation_number from public.drivers where id=target));
end $$;
revoke all on function private.review_driver_v3(jsonb) from public,anon;
grant execute on function private.review_driver_v3(jsonb) to authenticated;

create function private.availability_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();going_online boolean:=coalesce((payload->>'online')::boolean,false);settings private.transport_compliance_settings;
begin
  select * into settings from private.transport_compliance_settings where id;
  if going_online and settings.enforcement_mode='enforce' and (not private.company_transport_ready_v1() or not private.driver_dossier_complete(uid)) then
    raise exception 'Cumplimiento de transporte pendiente. Revisa el expediente y la póliza de la empresa con Operaciones.';
  end if;
  return private.availability_v4(payload);
end $$;
revoke all on function private.availability_v5(jsonb) from public,anon;
grant execute on function private.availability_v5(jsonb) to authenticated;

create function private.request_trip_v9(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;target uuid;series_id uuid;
begin
  if not coalesce((payload->>'confirm_transport_terms')::boolean,false)
    or coalesce(payload->>'regulatory_terms_version','')<>'YV-TRANSPORTE-2026.09.15' then
    raise exception 'Lee y acepta la información legal y de resguardo del viaje.';
  end if;
  result:=private.request_trip_v8(payload);
  target:=(result->>'id')::uuid;
  series_id:=nullif(result->>'schedule_series_id','')::uuid;
  update public.trips set regulatory_terms_version='YV-TRANSPORTE-2026.09.15',regulatory_terms_accepted_at=now(),updated_at=now()
  where id=target or (series_id is not null and schedule_series_id=series_id);
  return result||jsonb_build_object('regulatory_terms_version','YV-TRANSPORTE-2026.09.15');
end $$;
revoke all on function private.request_trip_v9(jsonb) from public,anon;
grant execute on function private.request_trip_v9(jsonb) to authenticated;

create function private.enforce_trip_transport_readiness_v1() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.driver_id is not null and new.status in ('accepted','arrived','in_progress')
    and (select enforcement_mode='enforce' from private.transport_compliance_settings where id)
    and (not private.company_transport_ready_v1() or not private.driver_dossier_complete(new.driver_id)) then
    raise exception 'La asignación requiere cumplimiento de transporte vigente.' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function private.enforce_trip_transport_readiness_v1() from public,anon,authenticated;
create trigger enforce_trip_transport_readiness before insert or update of driver_id,status on public.trips
for each row execute function private.enforce_trip_transport_readiness_v1();

create function private.sync_trip_regulatory_record_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare assigned_time timestamptz;start_time timestamptz;actual_km numeric:=0;receipt jsonb;passenger_email text;
begin
  select min(created_at) filter(where event='accepted'),min(created_at) filter(where event='in_progress')
    into assigned_time,start_time from public.trip_events where trip_id=new.id;
  if new.status='accepted' and (tg_op='INSERT' or old.status is distinct from 'accepted') then assigned_time:=now();end if;
  if new.status='in_progress' and (tg_op='INSERT' or old.status is distinct from 'in_progress') then start_time:=now();end if;
  if new.status in ('completed','cancelled') then
    select coalesce(round(sum(private.haversine_km(prev_lat,prev_lng,lat,lng))::numeric,2),0) into actual_km
    from (select lat,lng,lag(lat) over(order by captured_at) prev_lat,lag(lng) over(order by captured_at) prev_lng from public.location_history where trip_id=new.id) points
    where prev_lat is not null;
  end if;
  insert into public.trip_regulatory_records(trip_id,passenger_id,driver_id,request_snapshot,assignment_snapshot,completion_snapshot,assigned_at,started_at,completed_at,retention_until,receipt_status,updated_at)
  values(
    new.id,new.passenger_id,new.driver_id,
    jsonb_build_object('quote_id',new.quote_id,'requested_at',new.created_at,'origin',new.origin,'destination',new.destination,'origin_lat',new.origin_lat,'origin_lng',new.origin_lng,'dest_lat',new.dest_lat,'dest_lng',new.dest_lng,'category',new.category,'estimated_fare_cents',new.fare_cents,'estimated_total_cents',new.total_cents,'estimated_distance_km',new.distance_km,'estimated_minutes',new.trip_eta_minutes,'payment_method',new.payment_method,'pricing_version',new.pricing_version,'regulatory_terms_version',new.regulatory_terms_version,'regulatory_terms_accepted_at',new.regulatory_terms_accepted_at,'passenger_terms',(select jsonb_build_object('safety_version',passenger_policy_version,'safety_accepted_at',passenger_policy_accepted_at,'privacy_version',privacy_policy_version,'privacy_accepted_at',privacy_policy_accepted_at,'terms_version',terms_version,'terms_accepted_at',terms_accepted_at) from public.profiles where id=new.passenger_id)),
    case when new.driver_id is null then '{}'::jsonb else jsonb_build_object('assigned_at',coalesce(assigned_time,now()),'driver',(select jsonb_build_object('id',d.id,'name',p.full_name,'photo_path',p.avatar_path,'rating',(select round(avg(stars),2) from public.ratings where recipient_id=d.id),'license_number',d.license_number,'license_expires',d.license_expires,'affiliation_number',d.affiliation_number) from public.drivers d join public.profiles p on p.id=d.id where d.id=new.driver_id),'vehicle',(select jsonb_build_object('make',vehicle_make,'model',vehicle_model,'year',vehicle_year,'color',vehicle_color,'plate',plate,'photo_path',vehicle_front_path,'vin',vin,'transport_card_number',transport_card_number,'transport_card_expires',transport_card_expires,'insurance_expires',insurance_expires) from public.drivers where id=new.driver_id)) end,
    case when new.status not in ('completed','cancelled') then '{}'::jsonb else jsonb_build_object('status',new.status,'completed_at',coalesce(new.completed_at,new.cancelled_at),'started_at',start_time,'actual_distance_km',actual_km,'duration_minutes',case when start_time is not null then greatest(0,round(extract(epoch from (coalesce(new.completed_at,new.cancelled_at)-start_time))/60.0)::integer) end,'total_cents',new.total_cents,'payment_method',new.payment_method,'payment_status',new.payment_status,'planned_route',new.planned_route,'cancellation_reason',new.cancel_reason) end,
    assigned_time,start_time,new.completed_at,coalesce(new.completed_at,new.cancelled_at,new.created_at)+interval '5 years',case when new.status='completed' then 'pending' else 'not_due' end,now()
  )
  on conflict(trip_id) do update set driver_id=excluded.driver_id,
    request_snapshot=case when public.trip_regulatory_records.request_snapshot='{}'::jsonb then excluded.request_snapshot else public.trip_regulatory_records.request_snapshot||jsonb_strip_nulls(jsonb_build_object('regulatory_terms_version',excluded.request_snapshot->'regulatory_terms_version','regulatory_terms_accepted_at',excluded.request_snapshot->'regulatory_terms_accepted_at')) end,
    assignment_snapshot=case when public.trip_regulatory_records.assignment_snapshot='{}'::jsonb then excluded.assignment_snapshot else public.trip_regulatory_records.assignment_snapshot end,
    completion_snapshot=case when public.trip_regulatory_records.completion_snapshot='{}'::jsonb then excluded.completion_snapshot else public.trip_regulatory_records.completion_snapshot end,
    assigned_at=coalesce(public.trip_regulatory_records.assigned_at,excluded.assigned_at),started_at=coalesce(public.trip_regulatory_records.started_at,excluded.started_at),
    completed_at=coalesce(public.trip_regulatory_records.completed_at,excluded.completed_at),retention_until=greatest(public.trip_regulatory_records.retention_until,excluded.retention_until),
    receipt_status=case when excluded.receipt_status='pending' and public.trip_regulatory_records.receipt_status='not_due' then 'pending' else public.trip_regulatory_records.receipt_status end,updated_at=now();
  if new.status='completed' and (tg_op='INSERT' or old.status is distinct from 'completed') then
    select email into passenger_email from auth.users where id=new.passenger_id;
    select jsonb_build_object('trip_id',r.trip_id,'recipient_email',passenger_email,'request',r.request_snapshot,'assignment',r.assignment_snapshot,'completion',r.completion_snapshot) into receipt
    from public.trip_regulatory_records r where r.trip_id=new.id;
    if passenger_email is null then
      update public.trip_regulatory_records set receipt_status='failed',updated_at=now() where trip_id=new.id;
    else
      insert into private.trip_receipt_outbox(trip_id,recipient_email,payload) values(new.id,passenger_email,receipt)
      on conflict(trip_id) do update set payload=excluded.payload,recipient_email=excluded.recipient_email,updated_at=now()
        where private.trip_receipt_outbox.status<>'sent';
    end if;
  end if;
  return new;
end $$;
revoke all on function private.sync_trip_regulatory_record_v1() from public,anon,authenticated;
create trigger sync_trip_regulatory_record after insert or update on public.trips
for each row execute function private.sync_trip_regulatory_record_v1();

-- Backfill existing records without changing trip or driver state.
update public.trips set updated_at=updated_at;

create function private.protect_trip_retention_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare keep_until timestamptz;
begin
  select retention_until into keep_until from public.trip_regulatory_records where trip_id=old.id;
  if keep_until is not null and keep_until>now() then raise exception 'El expediente del viaje debe conservarse durante cinco años.';end if;
  return old;
end $$;
revoke all on function private.protect_trip_retention_v1() from public,anon,authenticated;
create trigger protect_trip_retention before delete on public.trips for each row execute function private.protect_trip_retention_v1();

create function private.complaint_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid:=nullif(payload->>'trip_id','')::uuid;created_id uuid;crime boolean:=coalesce((payload->>'suspected_crime')::boolean,false);
begin
  if uid is null or not exists(select 1 from public.profiles where id=uid and not suspended) then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  if target is not null and not private.is_participant(target) then raise exception 'Viaje no disponible.' using errcode='42501';end if;
  if (select count(*) from public.complaints where owner_id=uid and created_at>now()-interval '1 hour')>=5 then raise exception 'Límite de reportes alcanzado. Intenta más tarde.';end if;
  if length(trim(coalesce(payload->>'body','')))<10 then raise exception 'Describe lo ocurrido con al menos 10 caracteres.';end if;
  insert into public.complaints(owner_id,trip_id,subject,body,suspected_crime,authority_report_status)
  values(uid,target,left(coalesce(payload->>'subject','General'),100),left(payload->>'body',2000),crime,case when crime then 'pending' else 'not_required' end)
  returning id into created_id;
  if crime then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'authority_incident_queued',created_id,jsonb_build_object('trip_id',target));end if;
  return jsonb_build_object('id',created_id,'authority_report_status',case when crime then 'pending' else 'not_required' end);
end $$;
revoke all on function private.complaint_v2(jsonb) from public,anon;
grant execute on function private.complaint_v2(jsonb) to authenticated;

create function private.rating_and_report_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;report_result jsonb;
begin
  if coalesce((payload->>'report_issue')::boolean,false) and (length(trim(coalesce(payload->>'report_subject','')))<3 or length(trim(coalesce(payload->>'report_body','')))<10) then raise exception 'Completa el motivo y la descripción del reporte.';end if;
  result:=private.rating_v3(payload);
  if coalesce((payload->>'report_issue')::boolean,false) then
    report_result:=private.complaint_v2(payload||jsonb_build_object('subject',payload->>'report_subject','body',payload->>'report_body'));
  end if;
  return result||jsonb_build_object('report',report_result);
end $$;
revoke all on function private.rating_and_report_v2(jsonb) from public,anon;
grant execute on function private.rating_and_report_v2(jsonb) to authenticated;

create function private.transport_compliance_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();settings private.transport_compliance_settings;action_value text:=coalesce(payload->>'action','read');path_value text;target uuid;note_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede administrar cumplimiento.' using errcode='42501';end if;
  select * into settings from private.transport_compliance_settings where id for update;
  if action_value='save' then
    path_value:=coalesce(nullif(payload->>'company_policy_path',''),settings.company_policy_path);
    if path_value is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=path_value and (storage.foldername(name))[1]=uid::text) then raise exception 'Póliza empresarial inválida.';end if;
    update private.transport_compliance_settings set legal_name=left(trim(coalesce(payload->>'legal_name','')),150),rfc=left(upper(trim(coalesce(payload->>'rfc',''))),20),
      state_authorization_number=left(trim(coalesce(payload->>'state_authorization_number','')),100),authorization_issued_at=nullif(payload->>'authorization_issued_at','')::date,
      authorization_expires=nullif(payload->>'authorization_expires','')::date,collaboration_agreement_at=nullif(payload->>'collaboration_agreement_at','')::date,
      company_policy_number=left(trim(coalesce(payload->>'company_policy_number','')),100),company_insurer=left(trim(coalesce(payload->>'company_insurer','')),120),
      company_policy_path=path_value,company_policy_starts_at=nullif(payload->>'company_policy_starts_at','')::date,company_policy_expires_at=nullif(payload->>'company_policy_expires_at','')::date,
      company_policy_coverage_cents=greatest(0,coalesce((payload->>'company_policy_coverage_cents')::bigint,0)),company_policy_coverage_uma=greatest(0,coalesce((payload->>'company_policy_coverage_uma')::numeric,0)),
      mobility_fund_bps=least(10000,greatest(0,coalesce((payload->>'mobility_fund_bps')::integer,150))),receipt_email_enabled=coalesce((payload->>'receipt_email_enabled')::boolean,false),
      authority_reporting_channel=left(trim(coalesce(payload->>'authority_reporting_channel','')),300),enforcement_mode=coalesce(payload->>'enforcement_mode','monitor'),updated_by=uid,updated_at=now() where id;
    if coalesce(payload->>'enforcement_mode','monitor')='enforce' and (not private.company_transport_ready_v1() or exists(select 1 from public.drivers where approved and cardinality(private.driver_legal_missing_v1(id))>0)) then
      raise exception 'Completa y verifica la autorización, póliza empresarial y expedientes aprobados antes de activar el bloqueo.';
    end if;
    insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'transport_compliance_settings_updated',uid,jsonb_build_object('enforcement_mode',payload->>'enforcement_mode','authorization_expires',payload->>'authorization_expires','company_policy_expires_at',payload->>'company_policy_expires_at'));
  elsif action_value='receipt_sent' then
    target:=(payload->>'trip_id')::uuid;note_value:=left(trim(coalesce(payload->>'reference','')),500);
    if length(note_value)<3 then raise exception 'Registra la referencia del envío.';end if;
    update private.trip_receipt_outbox set status='sent',delivered_at=now(),last_error='',attempts=attempts+1,updated_at=now() where trip_id=target;
    update public.trip_regulatory_records set receipt_status='sent',receipt_sent_at=now(),updated_at=now() where trip_id=target;
    insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'trip_receipt_sent',target,jsonb_build_object('reference',note_value));
  elsif action_value='incident_reported' then
    target:=(payload->>'complaint_id')::uuid;note_value:=left(trim(coalesce(payload->>'reference','')),500);
    if length(note_value)<3 then raise exception 'Registra folio, autoridad y medio de envío.';end if;
    update public.complaints set authority_report_status='reported',authority_reported_at=now(),authority_reference=note_value,updated_at=now() where id=target and authority_report_status='pending';
    insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'authority_incident_reported',target,jsonb_build_object('reference',note_value));
  elsif action_value<>'read' then raise exception 'Acción de cumplimiento inválida.';end if;
  select * into settings from private.transport_compliance_settings where id;
  return jsonb_build_object(
    'settings',to_jsonb(settings)-'updated_by',
    'company_ready',private.company_transport_ready_v1(),
    'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (select d.id,p.full_name,d.approved,d.affiliation_number,d.affiliation_expires,d.vehicle,d.plate,d.license_expires,d.insurance_expires,d.transport_card_expires,d.vehicle_registration_expires,cardinality(private.driver_legal_missing_v1(d.id))=0 as legal_ready,to_jsonb(private.driver_legal_missing_v1(d.id)) as missing from public.drivers d join public.profiles p on p.id=d.id)x),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (select o.trip_id,o.recipient_email,o.status,o.attempts,o.last_error,o.delivered_at,o.created_at,t.origin,t.destination,t.completed_at from private.trip_receipt_outbox o join public.trips t on t.id=o.trip_id order by o.created_at desc limit 200)x),
    'authority_incidents',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (select c.id,c.trip_id,c.subject,c.body,c.status,c.authority_report_status,c.authority_reported_at,c.authority_reference,c.created_at,p.full_name as reported_by from public.complaints c join public.profiles p on p.id=c.owner_id where c.suspected_crime order by c.created_at desc limit 200)x),
    'retention',(select jsonb_build_object('records',count(*),'protected_until_after',min(retention_until),'pending_receipts',count(*) filter(where receipt_status in ('pending','failed'))) from public.trip_regulatory_records)
  );
end $$;
revoke all on function private.transport_compliance_v1(jsonb) from public,anon;
grant execute on function private.transport_compliance_v1(jsonb) to authenticated;

create function private.trip_v10(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;target uuid:=(payload->>'trip_id')::uuid;record_value jsonb;policy_value jsonb;
begin
  base:=private.trip_v9(payload);
  if private.is_admin() and coalesce(auth.jwt()->>'aal','aal1')='aal2' then
    select to_jsonb(r)-'passenger_id'-'driver_id' into record_value
    from public.trip_regulatory_records r where r.trip_id=target;
  else
    select jsonb_build_object(
      'trip_id',r.trip_id,
      'request_snapshot',jsonb_build_object('regulatory_terms_version',r.request_snapshot->'regulatory_terms_version','regulatory_terms_accepted_at',r.request_snapshot->'regulatory_terms_accepted_at'),
      'assignment_snapshot',jsonb_build_object('assigned_at',r.assignment_snapshot->'assigned_at','driver',(r.assignment_snapshot->'driver')-'license_number'-'license_expires','vehicle',(r.assignment_snapshot->'vehicle')-'vin'-'transport_card_number'-'transport_card_expires'-'insurance_expires'),
      'completion_snapshot',r.completion_snapshot,
      'assigned_at',r.assigned_at,'started_at',r.started_at,'completed_at',r.completed_at,
      'retention_until',r.retention_until,'receipt_status',r.receipt_status,'receipt_sent_at',r.receipt_sent_at
    ) into record_value from public.trip_regulatory_records r where r.trip_id=target;
  end if;
  select jsonb_build_object('insurer',company_insurer,'policy_number',company_policy_number,'starts_at',company_policy_starts_at,'expires_at',company_policy_expires_at,'coverage_cents',company_policy_coverage_cents,'coverage_uma',company_policy_coverage_uma,'available',private.company_transport_ready_v1()) into policy_value from private.transport_compliance_settings where id;
  return base||jsonb_build_object('regulatory_record',record_value,'company_insurance',policy_value);
end $$;
revoke all on function private.trip_v10(jsonb) from public,anon;
grant execute on function private.trip_v10(jsonb) to authenticated;

create function private.operations_report_v4(payload jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb;start_value timestamptz;end_value timestamptz;driver_value uuid:=nullif(payload->>'driver_id','')::uuid;
begin
  base:=private.operations_report_v3(payload);start_value:=(base#>>'{meta,from}')::timestamptz;end_value:=(base#>>'{meta,to}')::timestamptz;
  return base||jsonb_build_object('regulatory',jsonb_build_object(
    'company_ready',private.company_transport_ready_v1(),
    'settings',(select jsonb_build_object('legal_name',legal_name,'rfc',rfc,'state_authorization_number',state_authorization_number,'authorization_expires',authorization_expires,'company_insurer',company_insurer,'company_policy_number',company_policy_number,'company_policy_expires_at',company_policy_expires_at,'enforcement_mode',enforcement_mode,'receipt_email_enabled',receipt_email_enabled,'mobility_fund_bps',mobility_fund_bps) from private.transport_compliance_settings where id),
    'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (select d.id,p.full_name,d.affiliation_number,d.affiliation_expires,d.vehicle,d.plate,d.vin,d.license_expires,d.transport_card_number,d.transport_card_expires,d.insurance_expires,d.vehicle_registration_expires,cardinality(private.driver_legal_missing_v1(d.id))=0 as legal_ready,to_jsonb(private.driver_legal_missing_v1(d.id)) as missing from public.drivers d join public.profiles p on p.id=d.id where driver_value is null or d.id=driver_value)x),
    'trips',(select jsonb_build_object('requested',count(*),'completed',count(*) filter(where status='completed'),'cancelled',count(*) filter(where status='cancelled'),'gross_cents',coalesce(sum(total_cents) filter(where status='completed'),0),'mobility_fund_contribution_cents',round(coalesce(sum(total_cents) filter(where status='completed'),0)*(select mobility_fund_bps from private.transport_compliance_settings where id)/10000.0)::bigint,'distance_km',coalesce(round(sum(distance_km) filter(where status='completed'),2),0)) from public.trips where created_at>=start_value and created_at<end_value and (driver_value is null or driver_id=driver_value)),
    'receipts',(select jsonb_build_object('pending',count(*) filter(where receipt_status='pending'),'sent',count(*) filter(where receipt_status='sent'),'failed',count(*) filter(where receipt_status='failed')) from public.trip_regulatory_records where coalesce(completed_at,created_at)>=start_value and coalesce(completed_at,created_at)<end_value and (driver_value is null or driver_id=driver_value)),
    'incidents',(select jsonb_build_object('pending_authority',count(*) filter(where authority_report_status='pending'),'reported',count(*) filter(where authority_report_status='reported')) from public.complaints where created_at>=start_value and created_at<end_value)
  ));
end $$;
revoke all on function private.operations_report_v4(jsonb) from public,anon;
grant execute on function private.operations_report_v4(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v11(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v9(payload)
   when 'trip' then private.trip_v10(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v8(payload)
   when 'review_driver' then private.review_driver_v3(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v5(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v6(payload)
   when 'accept' then private.accept_offer_v2(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
   when 'transition' then private.transition_v7(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v3(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v1(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v4(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
   when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload)
   when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v2(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'scheduled_operations' then private.scheduled_operations_v1(payload)
   when 'confirm_scheduled_trip' then private.confirm_scheduled_trip_v1(payload)
   when 'assign_scheduled_trip' then private.assign_scheduled_trip_v1(payload)
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
