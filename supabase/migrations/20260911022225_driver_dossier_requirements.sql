alter table public.drivers
  add column criminal_record_path text,
  add column policy_commitment_path text,
  add column traffic_law_commitment_path text,
  add column policy_version text,
  add column traffic_law_version text,
  add column dossier_submitted_at timestamptz;

create function private.driver_dossier_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from public.drivers d
    join public.profiles p on p.id=d.id
    where d.id=target
      and length(trim(p.full_name))>=2
      and length(trim(p.phone))>=10
      and p.avatar_path is not null
      and length(trim(d.vehicle_make))>=2
      and length(trim(d.vehicle_model))>=1
      and d.vehicle_year between 1990 and extract(year from current_date)::integer+1
      and length(trim(d.vehicle_color))>=3
      and length(trim(d.plate))>=5
      and length(trim(d.license_number))>=3
      and d.license_expires>=current_date
      and d.insurance_expires>=current_date
      and d.license_path is not null
      and d.insurance_path is not null
      and d.criminal_record_path is not null
      and d.policy_commitment_path is not null
      and d.traffic_law_commitment_path is not null
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars' and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.license_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.insurance_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.criminal_record_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.policy_commitment_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.traffic_law_commitment_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.driver_dossier_complete(uuid) from public,anon,authenticated;

create function private.driver_profile_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid();
  p public.profiles;
  make_value text;
  model_value text;
  year_value integer;
  color_value text;
  combined text;
  path_key text;
  path_value text;
begin
  if uid is null then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  select * into p from public.profiles where id=uid;
  if not found or p.role<>'driver' or p.suspended then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
  if not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Verifica tu correo para continuar.' using errcode='42501';end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>20000 then raise exception 'Solicitud inválida.';end if;
  if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de editar el expediente.';end if;

  make_value:=trim(coalesce(payload->>'vehicle_make',''));
  model_value:=trim(coalesce(payload->>'vehicle_model',''));
  year_value:=nullif(payload->>'vehicle_year','')::integer;
  color_value:=trim(coalesce(payload->>'vehicle_color',''));
  if length(make_value)<2 or length(model_value)<1 or year_value not between 1990 and extract(year from current_date)::integer+1 or length(color_value)<3 or length(trim(coalesce(payload->>'plate','')))<5 then
    raise exception 'Completa marca, modelo, año, color y placas.';
  end if;
  if length(trim(coalesce(payload->>'license_number','')))<3 then raise exception 'Completa el número de licencia.';end if;
  if coalesce(nullif(payload->>'license_expires','')::date<current_date,true) or coalesce(nullif(payload->>'insurance_expires','')::date<current_date,true) then raise exception 'La licencia y el seguro deben estar vigentes.';end if;
  if not exists(select 1 from public.categories where id=payload->>'category') then raise exception 'Categoría inválida.';end if;

  foreach path_key in array array['license_path','insurance_path','criminal_record_path','policy_commitment_path','traffic_law_commitment_path'] loop
    path_value:=nullif(payload->>path_key,'');
    if path_value is not null and not exists(
      select 1 from storage.objects where bucket_id='yavoi-documents' and name=path_value and (storage.foldername(name))[1]=uid::text
    ) then raise exception 'Documento inválido o ajeno a tu cuenta.';end if;
  end loop;

  combined:=left(make_value||' '||model_value||' '||year_value::text,100);
  update public.drivers set
    vehicle=combined,
    vehicle_make=left(make_value,50),
    vehicle_model=left(model_value,50),
    vehicle_year=year_value,
    vehicle_color=left(color_value,40),
    plate=upper(left(trim(payload->>'plate'),20)),
    category=payload->>'category',
    license_number=left(trim(payload->>'license_number'),50),
    license_expires=nullif(payload->>'license_expires','')::date,
    insurance_expires=nullif(payload->>'insurance_expires','')::date,
    license_path=coalesce(nullif(payload->>'license_path',''),license_path),
    insurance_path=coalesce(nullif(payload->>'insurance_path',''),insurance_path),
    criminal_record_path=coalesce(nullif(payload->>'criminal_record_path',''),criminal_record_path),
    policy_commitment_path=coalesce(nullif(payload->>'policy_commitment_path',''),policy_commitment_path),
    traffic_law_commitment_path=coalesce(nullif(payload->>'traffic_law_commitment_path',''),traffic_law_commitment_path),
    policy_version=case when nullif(payload->>'policy_commitment_path','') is not null then '2026-09-10' else policy_version end,
    traffic_law_version=case when nullif(payload->>'traffic_law_commitment_path','') is not null then 'POE-2026-08-08-63' else traffic_law_version end,
    advertising_interest=coalesce((payload->>'advertising_interest')::boolean,false),
    approved=false,
    online=false,
    dossier_submitted_at=now(),
    updated_at=now()
  where id=uid;
  insert into public.audit_log(actor_id,action,target_id,detail) values(
    uid,'driver_dossier_submitted',uid,
    jsonb_build_object('complete',private.driver_dossier_complete(uid),'policy_version','2026-09-10','traffic_law_version','POE-2026-08-08-63')
  );
  return jsonb_build_object('ok',true,'complete',private.driver_dossier_complete(uid));
end $$;
revoke all on function private.driver_profile_v4(jsonb) from public,anon;
grant execute on function private.driver_profile_v4(jsonb) to authenticated;

create function private.review_driver_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;d public.drivers;approved_value boolean;
begin
  if uid is null or not private.is_admin() then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501';end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16000 then raise exception 'Solicitud inválida.';end if;
  target:=(payload->>'driver_id')::uuid;
  select * into d from public.drivers where id=target for update;
  if not found then raise exception 'Conductor no encontrado.';end if;
  if length(trim(coalesce(payload->>'note','')))<5 then raise exception 'Registra el resultado de tu revisión.';end if;
  approved_value:=coalesce((payload->>'approved')::boolean,false);
  if approved_value and not private.driver_dossier_complete(target) then
    raise exception 'El expediente requiere fotografía, unidad, licencia y seguro vigentes, carta de no antecedentes y ambas cartas firmadas.';
  end if;
  if exists(select 1 from public.trips where driver_id=target and status not in ('completed','cancelled')) then raise exception 'Resuelve el viaje activo antes de cambiar la autorización.';end if;
  update public.drivers set
    approved=approved_value,
    online=false,
    female_verified=coalesce((payload->>'female_verified')::boolean,false),
    accessible_verified=coalesce((payload->>'accessible_verified')::boolean,false),
    review_note=left(payload->>'note',1000),
    updated_at=now()
  where id=target;
  insert into public.audit_log(actor_id,action,target_id,detail) values(
    uid,'review_driver',target,
    jsonb_build_object('approved',approved_value,'female_verified',coalesce((payload->>'female_verified')::boolean,false),'accessible_verified',coalesce((payload->>'accessible_verified')::boolean,false),'note',left(payload->>'note',1000))
  );
  return jsonb_build_object('ok',true,'approved',approved_value);
end $$;
revoke all on function private.review_driver_v2(jsonb) from public,anon;
grant execute on function private.review_driver_v2(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v4(payload)
   when 'quote' then private.quote_v3(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v4(payload)
   when 'trip' then private.trip_v4(payload)
   when 'driver_profile' then private.driver_profile_v4(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v4(payload)
   when 'accept' then private.accept_offer_v1(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'transition' then private.transition_v3(payload)
   when 'payment_checkout' then private.payment_checkout_v1(payload)
   when 'refund_checkout' then private.refund_checkout_v1(payload)
   when 'post_trip_tip' then private.post_trip_tip_v1(payload)
   when 'submit_weekly_fee' then private.submit_weekly_fee_v1(payload)
   when 'review_weekly_fee' then private.review_weekly_fee_v1(payload)
   when 'set_driver_access' then private.set_driver_access_v1(payload)
   when 'category' then private.category_v2(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
