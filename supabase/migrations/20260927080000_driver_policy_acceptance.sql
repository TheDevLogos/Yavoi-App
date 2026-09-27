-- Driver approval remains based on the profile photo and four documents.  The
-- two current Yavoi policies are explicit, recorded acceptance requirements.
create or replace function private.driver_dossier_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d
    join public.profiles p on p.id=d.id
    where d.id=target
      and p.avatar_path is not null
      and d.government_id_path is not null
      and d.license_path is not null
      and d.vehicle_registration_path is not null
      and d.insurance_path is not null
      and p.privacy_policy_accepted_at is not null and p.privacy_policy_version='2026-09-11'
      and p.terms_accepted_at is not null and p.terms_version='2026-09-11'
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars' and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.government_id_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.license_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.vehicle_registration_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.insurance_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.driver_dossier_complete(uuid) from public,anon,authenticated;

create or replace function private.driver_profile_v10(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid(); profile_value public.profiles; path_key text; path_value text;
  complete_value boolean; privacy_was_accepted boolean; terms_was_accepted boolean;
begin
  select * into profile_value from public.profiles where id=uid for update;
  if uid is null or not found or profile_value.role<>'driver' or profile_value.suspended then
    raise exception 'Acceso de conductor requerido.' using errcode='42501';
  end if;
  if not private.profile_edit_open(uid) then
    raise exception 'Tu expediente está protegido. Operaciones debe autorizar temporalmente cualquier modificación.' using errcode='42501';
  end if;
  if jsonb_typeof(payload)<>'object' or octet_length(payload::text)>12000 then raise exception 'Solicitud inválida.'; end if;
  if not coalesce((payload->>'accept_privacy_policy')::boolean,false) or coalesce(payload->>'privacy_policy_version','')<>'2026-09-11' then
    raise exception 'Lee y acepta la Política de Privacidad vigente.';
  end if;
  if not coalesce((payload->>'accept_terms')::boolean,false) or coalesce(payload->>'terms_version','')<>'2026-09-11' then
    raise exception 'Lee y acepta los Términos de Servicio vigentes.';
  end if;
  foreach path_key in array array['government_id_path','license_path','vehicle_registration_path','insurance_path'] loop
    path_value:=nullif(payload->>path_key,'');
    if path_value is not null and not exists(
      select 1 from storage.objects where bucket_id='yavoi-documents' and name=path_value and (storage.foldername(name))[1]=uid::text
    ) then raise exception 'Documento inválido o ajeno a tu cuenta.'; end if;
  end loop;
  privacy_was_accepted:=profile_value.privacy_policy_accepted_at is not null and profile_value.privacy_policy_version='2026-09-11';
  terms_was_accepted:=profile_value.terms_accepted_at is not null and profile_value.terms_version='2026-09-11';
  update public.profiles set
    privacy_policy_accepted_at=case when privacy_was_accepted then privacy_policy_accepted_at else now() end,
    privacy_policy_version='2026-09-11',
    terms_accepted_at=case when terms_was_accepted then terms_accepted_at else now() end,
    terms_version='2026-09-11', updated_at=now()
  where id=uid;
  update public.drivers set
    government_id_path=coalesce(nullif(payload->>'government_id_path',''),government_id_path),
    license_path=coalesce(nullif(payload->>'license_path',''),license_path),
    vehicle_registration_path=coalesce(nullif(payload->>'vehicle_registration_path',''),vehicle_registration_path),
    insurance_path=coalesce(nullif(payload->>'insurance_path',''),insurance_path),
    approved=false,online=false,dossier_submitted_at=now(),updated_at=now()
  where id=uid;
  complete_value:=private.driver_dossier_complete(uid);
  if complete_value then update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid; end if;
  delete from public.driver_profile_drafts where driver_id=uid;
  if not privacy_was_accepted then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'driver_privacy_policy_accepted',uid,jsonb_build_object('version','2026-09-11')); end if;
  if not terms_was_accepted then insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'driver_terms_accepted',uid,jsonb_build_object('version','2026-09-11')); end if;
  insert into public.audit_log(actor_id,action,target_id,detail)
    values(uid,'driver_dossier_submitted',uid,jsonb_build_object('complete',complete_value,'requirements','profile_photo_four_documents_two_policies'));
  return jsonb_build_object('ok',true,'complete',complete_value,'profile_locked',complete_value);
end $$;
revoke all on function private.driver_profile_v10(jsonb) from public,anon;
grant execute on function private.driver_profile_v10(jsonb) to authenticated;

-- Operations receives the two acceptance timestamps with the existing private
-- driver dossier so its readiness indicator matches the approval rule.
create or replace function private.dashboard_v18(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.profiles; base jsonb; cards jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) into cards
  from public.feature_cards c
  where p.role='admin' or (c.active and c.audience=p.role);
  base:=private.dashboard_v17(payload);
  if p.role='admin' then
    base:=jsonb_set(base,'{drivers}',(
      select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object(
        'full_name',pr.full_name,'phone',pr.phone,'avatar_path',pr.avatar_path,
        'privacy_policy_accepted_at',pr.privacy_policy_accepted_at,'privacy_policy_version',pr.privacy_policy_version,
        'terms_accepted_at',pr.terms_accepted_at,'terms_version',pr.terms_version
      ) order by pr.full_name),'[]'::jsonb)
      from public.drivers d join public.profiles pr on pr.id=d.id
    ),true);
  end if;
  return jsonb_set(base,'{marketing,feature_cards}',cards,true);
end $$;
revoke all on function private.dashboard_v18(jsonb) from public,anon;
grant execute on function private.dashboard_v18(jsonb) to authenticated;
