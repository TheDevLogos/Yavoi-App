-- Keep passenger rewards current and add a private, verified vehicle-front photo.
alter table public.drivers add column vehicle_front_path text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('yavoi-vehicle-photos','yavoi-vehicle-photos',false,2097152,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create policy vehicle_photos_driver_insert on storage.objects for insert to authenticated with check(
  bucket_id='yavoi-vehicle-photos'
  and (storage.foldername(name))[1]=(select auth.uid())::text
  and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver' and not p.suspended)
);
create policy vehicle_photos_authorized_read on storage.objects for select to authenticated using(
  bucket_id='yavoi-vehicle-photos' and (
    (storage.foldername(name))[1]=(select auth.uid())::text
    or (select private.is_admin())
    or exists(
      select 1 from public.trips t
      where t.driver_id::text=(storage.foldername(name))[1]
        and t.passenger_id=(select auth.uid())
        and t.driver_id is not null
    )
  )
);

create or replace function private.driver_dossier_complete(target uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.drivers d join public.profiles p on p.id=d.id
    where d.id=target
      and length(trim(p.full_name))>=2 and length(trim(p.phone))>=10 and p.avatar_path is not null
      and length(trim(d.vehicle_make))>=2 and length(trim(d.vehicle_model))>=1
      and d.vehicle_year between 1990 and extract(year from current_date)::integer+1
      and length(trim(d.vehicle_color))>=3 and length(trim(d.plate))>=5
      and d.vehicle_front_path is not null and length(trim(d.license_number))>=3
      and d.license_expires>=current_date and d.insurance_expires>=current_date
      and d.license_path is not null and d.insurance_path is not null and d.criminal_record_path is not null
      and d.policy_commitment_path is not null and d.traffic_law_commitment_path is not null
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-avatars' and o.name=p.avatar_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-vehicle-photos' and o.name=d.vehicle_front_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.license_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.insurance_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.criminal_record_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.policy_commitment_path and (storage.foldername(o.name))[1]=target::text)
      and exists(select 1 from storage.objects o where o.bucket_id='yavoi-documents' and o.name=d.traffic_law_commitment_path and (storage.foldername(o.name))[1]=target::text)
  )
$$;
revoke all on function private.driver_dossier_complete(uuid) from public,anon,authenticated;

create function private.driver_profile_v7(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();photo_path text;result jsonb;complete_value boolean;
begin
  photo_path:=nullif(payload->>'vehicle_front_path','');
  if photo_path is not null and not exists(
    select 1 from storage.objects where bucket_id='yavoi-vehicle-photos' and name=photo_path
      and (storage.foldername(name))[1]=uid::text
  ) then raise exception 'La fotografía frontal del vehículo es inválida o pertenece a otra cuenta.';end if;
  result:=private.driver_profile_v6(payload);
  if photo_path is not null then
    update public.drivers set vehicle_front_path=photo_path,approved=false,online=false,updated_at=now() where id=uid;
  end if;
  complete_value:=private.driver_dossier_complete(uid);
  if complete_value then update public.profiles set profile_locked_at=coalesce(profile_locked_at,now()) where id=uid;end if;
  return result||jsonb_build_object('complete',complete_value,'vehicle_front_path',(select vehicle_front_path from public.drivers where id=uid));
end $$;
revoke all on function private.driver_profile_v7(jsonb) from public,anon;
grant execute on function private.driver_profile_v7(jsonb) to authenticated;

create function private.trip_v7(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;t public.trips;driver_value jsonb;
begin
  base:=private.trip_v6(payload);
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if t.driver_id is null then return base;end if;
  driver_value:=coalesce(base->'driver','{}'::jsonb)||jsonb_build_object(
    'vehicle_front_path',(select vehicle_front_path from public.drivers where id=t.driver_id)
  );
  return jsonb_set(base,'{driver}',driver_value,true);
end $$;
revoke all on function private.trip_v7(jsonb) from public,anon;
grant execute on function private.trip_v7(jsonb) to authenticated;

create function private.transition_v7(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;driver_points integer;
begin
  result:=private.transition_v6(payload);
  if result ? 'error' then return result;end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if t.status='completed' and payload->>'status'='completed' and (select rewards_enabled from private.app_settings where id) then
    insert into public.reward_entries(user_id,trip_id,points,entry_type,description)
    values(t.passenger_id,t.id,10,'trip_complete','Viaje completado · Puntos Viajeros')
    on conflict(user_id,trip_id,entry_type) where trip_id is not null
    do update set points=excluded.points,description=excluded.description;
    driver_points:=12+least(8,floor(t.fare_cents/5000.0)::integer);
    insert into public.reward_entries(user_id,trip_id,points,entry_type,description)
    values(t.driver_id,t.id,driver_points,'trip_complete','Viaje e ingreso generado · Rating Yavoi!')
    on conflict(user_id,trip_id,entry_type) where trip_id is not null
    do update set points=excluded.points,description=excluded.description;
  end if;
  return result;
end $$;
revoke all on function private.transition_v7(jsonb) from public,anon;
grant execute on function private.transition_v7(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v9(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v7(payload)
   when 'trip' then private.trip_v7(payload)
   when 'driver_profile' then private.driver_profile_v7(payload)
   when 'review_driver' then private.review_driver_v2(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v4(payload)
   when 'presence' then private.presence_v3(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v5(payload)
   when 'accept' then private.accept_offer_v2(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'transition' then private.transition_v7(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v1(payload)
   when 'redeem_reward' then private.redeem_reward_v3(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v1(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'operations_report' then private.operations_report_v1(payload)
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
   when 'category' then private.category_v3(payload)
   else private.dispatch(command,payload) end
$$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
