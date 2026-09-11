-- Completed passenger and driver profiles become read-only until Operations grants a temporary edit window.
alter table public.profiles
  add column profile_locked_at timestamptz,
  add column profile_edit_allowed_until timestamptz,
  add column profile_edit_authorized_by uuid references public.profiles(id),
  add column profile_edit_authorization_note text check(char_length(profile_edit_authorization_note)<=500);

create index profiles_edit_authorized_by on public.profiles(profile_edit_authorized_by)
where profile_edit_authorized_by is not null;

update public.profiles p
set profile_locked_at=now()
where p.role='passenger' and private.passenger_profile_complete(p.id);

update public.profiles p
set profile_locked_at=now()
where p.role='driver' and private.driver_dossier_complete(p.id);

create function private.profile_edit_open(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p
    where p.id=target and (
      p.role='admin' or p.profile_locked_at is null or p.profile_edit_allowed_until>now()
    )
  )
$$;
revoke all on function private.profile_edit_open(uuid) from public,anon;
grant execute on function private.profile_edit_open(uuid) to authenticated;

drop policy yavoi_upload on storage.objects;
create policy yavoi_upload on storage.objects for insert to authenticated with check(
  bucket_id in ('yavoi-documents','yavoi-avatars')
  and (storage.foldername(name))[1]=(select auth.uid())::text
  and exists(
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and not p.suspended
      and (p.profile_locked_at is null or p.profile_edit_allowed_until>now())
  )
);

create function private.profile_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;result jsonb;
begin
  select * into p from public.profiles where id=uid for update;
  if uid is null or not found then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  if p.role in ('passenger','driver') and not private.profile_edit_open(uid) then
    raise exception 'Tu perfil está protegido. Operaciones debe autorizar temporalmente cualquier modificación.' using errcode='42501';
  end if;
  result:=private.profile_v2(payload);
  if (p.role='passenger' and private.passenger_profile_complete(uid))
     or (p.role='driver' and private.driver_dossier_complete(uid)) then
    update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid;
  end if;
  return result||jsonb_build_object(
    'profile_locked',(select profile_locked_at is not null from public.profiles where id=uid),
    'edit_allowed_until',(select profile_edit_allowed_until from public.profiles where id=uid)
  );
end $$;
revoke all on function private.profile_v3(jsonb) from public,anon;
grant execute on function private.profile_v3(jsonb) to authenticated;

create function private.driver_profile_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;result jsonb;
begin
  select * into p from public.profiles where id=uid for update;
  if uid is null or not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
  if not private.profile_edit_open(uid) then
    raise exception 'Tu expediente está protegido. Operaciones debe autorizar temporalmente cualquier modificación.' using errcode='42501';
  end if;
  result:=private.driver_profile_v4(payload);
  if private.driver_dossier_complete(uid) then
    update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid;
  end if;
  return result||jsonb_build_object(
    'profile_locked',(select profile_locked_at is not null from public.profiles where id=uid),
    'edit_allowed_until',(select profile_edit_allowed_until from public.profiles where id=uid)
  );
end $$;
revoke all on function private.driver_profile_v5(jsonb) from public,anon;
grant execute on function private.driver_profile_v5(jsonb) to authenticated;

create function private.authorize_profile_edit_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;allowed boolean;note_value text;target_profile public.profiles;until_value timestamptz;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede autorizar cambios de perfil.' using errcode='42501';
  end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>4000 then raise exception 'Solicitud inválida.';end if;
  target:=(payload->>'profile_id')::uuid;
  allowed:=coalesce((payload->>'allowed')::boolean,false);
  note_value:=trim(coalesce(payload->>'note',''));
  if length(note_value)<5 then raise exception 'Registra el motivo de la autorización.';end if;
  select * into target_profile from public.profiles where id=target for update;
  if not found or target_profile.role='admin' then raise exception 'Perfil no disponible para esta acción.';end if;
  if target_profile.profile_locked_at is null then raise exception 'El perfil aún no está completo ni protegido.';end if;
  until_value:=case when allowed then now()+interval '24 hours' else null end;
  update public.profiles set
    profile_edit_allowed_until=until_value,
    profile_edit_authorized_by=case when allowed then uid else null end,
    profile_edit_authorization_note=left(note_value,500),
    updated_at=now()
  where id=target;
  insert into public.audit_log(actor_id,action,target_id,detail) values(
    uid,case when allowed then 'profile_edit_authorized' else 'profile_edit_revoked' end,target,
    jsonb_build_object('allowed_until',until_value,'note',left(note_value,500))
  );
  return jsonb_build_object('ok',true,'allowed',allowed,'allowed_until',until_value);
end $$;
revoke all on function private.authorize_profile_edit_v1(jsonb) from public,anon;
grant execute on function private.authorize_profile_edit_v1(jsonb) to authenticated;

create function private.dashboard_v5(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  base:=private.dashboard_v4(payload);
  return base||jsonb_build_object(
    'managed_profiles',case when p.role='admin' then (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.role,x.full_name),'[]') from (
        select pr.id,pr.role,pr.full_name,pr.phone,pr.avatar_path,pr.profile_locked_at,
          pr.profile_edit_allowed_until,pr.profile_edit_authorized_by,pr.profile_edit_authorization_note,
          d.vehicle,d.plate
        from public.profiles pr left join public.drivers d on d.id=pr.id
        where pr.role in ('passenger','driver')
      )x
    ) else '[]'::jsonb end
  );
end $$;
revoke all on function private.dashboard_v5(jsonb) from public,anon;
grant execute on function private.dashboard_v5(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v5(payload)
   when 'profile' then private.profile_v3(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v5(payload)
   when 'trip' then private.trip_v4(payload)
   when 'driver_profile' then private.driver_profile_v5(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
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
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
