-- Clear Operations audit trail and on-demand reporting. All sensitive report
-- data is produced server-side and is restricted to an AAL2 admin session.
create function private.operations_report_v1(payload jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  uid uuid:=auth.uid();
  period_value text:=coalesce(nullif(payload->>'period',''),'month');
  driver_value uuid:=nullif(payload->>'driver_id','')::uuid;
  start_value timestamptz;
  end_value timestamptz;
  report_value text:=coalesce(nullif(payload->>'report',''),'overview');
  summary_value jsonb;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Sólo Operaciones con verificación en dos pasos puede consultar informes.' using errcode='42501';
  end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>4000 then raise exception 'Solicitud inválida.';end if;
  if period_value not in ('day','week','month','year','custom') then raise exception 'Periodo de informe inválido.';end if;
  if report_value not in ('overview','drivers','incidents','ratings','insurance','audit') then raise exception 'Tipo de informe inválido.';end if;
  if driver_value is not null and not exists(select 1 from public.drivers where id=driver_value) then raise exception 'Conductor no encontrado.';end if;

  if period_value='day' then start_value:=date_trunc('day',now());end if;
  if period_value='week' then start_value:=date_trunc('week',now());end if;
  if period_value='month' then start_value:=date_trunc('month',now());end if;
  if period_value='year' then start_value:=date_trunc('year',now());end if;
  if period_value='custom' then
    start_value:=nullif(payload->>'from','')::date;
    end_value:=(nullif(payload->>'to','')::date+1)::timestamptz;
    if start_value is null or end_value is null or end_value<=start_value or end_value-start_value>interval '366 days' then raise exception 'El rango personalizado debe tener entre 1 y 366 días.';end if;
  else
    end_value:=now()+interval '1 second';
  end if;

  select jsonb_build_object(
    'trips',count(*),
    'completed',count(*) filter(where t.status='completed'),
    'cancelled',count(*) filter(where t.status='cancelled'),
    'active',count(*) filter(where t.status not in ('completed','cancelled')),
    'gross_cents',coalesce(sum(t.total_cents) filter(where t.status='completed'),0),
    'fares_cents',coalesce(sum(t.fare_cents) filter(where t.status='completed'),0),
    'tips_cents',coalesce(sum(t.tip_cents) filter(where t.status='completed'),0),
    'discounts_cents',coalesce(sum(t.reward_discount_cents) filter(where t.status='completed'),0),
    'platform_commission_cents',coalesce(sum(t.commission_cents) filter(where t.status='completed'),0),
    'driver_earnings_cents',coalesce(sum(t.fare_cents-t.commission_cents+t.tip_cents) filter(where t.status='completed'),0),
    'cash_cents',coalesce(sum(t.total_cents) filter(where t.status='completed' and t.payment_method='cash'),0),
    'card_cents',coalesce(sum(t.total_cents) filter(where t.status='completed' and t.payment_method='card'),0),
    'average_ticket_cents',coalesce(round(avg(t.total_cents) filter(where t.status='completed'))::integer,0),
    'distance_km',coalesce(round(sum(t.distance_km) filter(where t.status='completed'),2),0)
  ) into summary_value
  from public.trips t
  where coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value
    and (driver_value is null or t.driver_id=driver_value);

  summary_value:=summary_value||jsonb_build_object(
    'incidents',(select count(*) from public.complaints c left join public.trips t on t.id=c.trip_id where c.created_at>=start_value and c.created_at<end_value and (driver_value is null or t.driver_id=driver_value)),
    'open_incidents',(select count(*) from public.complaints c left join public.trips t on t.id=c.trip_id where c.created_at>=start_value and c.created_at<end_value and c.status<>'resolved' and (driver_value is null or t.driver_id=driver_value)),
    'average_rating',(select round(avg(r.stars),2) from public.ratings r join public.profiles recipient on recipient.id=r.recipient_id left join public.trips t on t.id=r.trip_id where r.created_at>=start_value and r.created_at<end_value and recipient.role='driver' and (driver_value is null or t.driver_id=driver_value)),
    'ratings_count',(select count(*) from public.ratings r join public.profiles recipient on recipient.id=r.recipient_id left join public.trips t on t.id=r.trip_id where r.created_at>=start_value and r.created_at<end_value and recipient.role='driver' and (driver_value is null or t.driver_id=driver_value)),
    'drivers_total',(select count(*) from public.drivers),
    'drivers_approved',(select count(*) from public.drivers where approved),
    'drivers_online',(select count(*) from public.drivers where online),
    'insurance_expiring',(select count(*) from public.drivers where insurance_expires between current_date and current_date+60),
    'insurance_expired',(select count(*) from public.drivers where insurance_expires<current_date or insurance_expires is null)
  );

  return jsonb_build_object(
    'meta',jsonb_build_object('period',period_value,'report',report_value,'from',start_value,'to',end_value,'driver_id',driver_value,'generated_at',now()),
    'summary',summary_value,
    'periods',(select jsonb_object_agg(period_name,metrics) from (
      select period_name,jsonb_build_object(
        'trips',count(t.id),
        'completed',count(t.id) filter(where t.status='completed'),
        'gross_cents',coalesce(sum(t.total_cents) filter(where t.status='completed'),0),
        'platform_commission_cents',coalesce(sum(t.commission_cents) filter(where t.status='completed'),0)
      ) metrics
      from (values
        ('day',date_trunc('day',now())),
        ('week',date_trunc('week',now())),
        ('month',date_trunc('month',now())),
        ('year',date_trunc('year',now()))
      ) bounds(period_name,period_start)
      left join public.trips t on coalesce(t.completed_at,t.created_at)>=bounds.period_start and coalesce(t.completed_at,t.created_at)<now()+interval '1 second' and (driver_value is null or t.driver_id=driver_value)
      group by period_name
    )period_metrics),
    'series',(select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]') from (
      select day::date as day,count(t.id) as trips,count(t.id) filter(where t.status='completed') as completed,
        coalesce(sum(t.total_cents) filter(where t.status='completed'),0) as gross_cents,
        coalesce(sum(t.commission_cents) filter(where t.status='completed'),0) as platform_commission_cents
      from generate_series(date_trunc('day',start_value),date_trunc('day',least(end_value-interval '1 second',start_value+interval '365 days')),interval '1 day') day
      left join public.trips t on coalesce(t.completed_at,t.created_at)>=day and coalesce(t.completed_at,t.created_at)<day+interval '1 day' and (driver_value is null or t.driver_id=driver_value)
      group by day
    )x),
    'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.completed desc,x.full_name),'[]') from (
      select p.id,p.full_name,p.phone,d.approved,d.online,d.account_active,d.vehicle,d.vehicle_make,d.vehicle_model,d.vehicle_year,d.vehicle_color,d.plate,d.category,
        d.insurance_expires,d.insurance_path,d.license_expires,
        case when d.insurance_expires is null or d.insurance_expires<current_date then 'expired' when d.insurance_expires<=current_date+30 then 'critical' when d.insurance_expires<=current_date+60 then 'warning' else 'valid' end as insurance_status,
        (select count(*) from public.trips t where t.driver_id=d.id and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value) as trips,
        (select count(*) from public.trips t where t.driver_id=d.id and t.status='completed' and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value) as completed,
        (select count(*) from public.trips t where t.driver_id=d.id and t.status='cancelled' and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value) as cancelled,
        (select coalesce(sum(t.total_cents),0) from public.trips t where t.driver_id=d.id and t.status='completed' and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value) as gross_cents,
        (select coalesce(sum(t.fare_cents-t.commission_cents+t.tip_cents),0) from public.trips t where t.driver_id=d.id and t.status='completed' and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value) as driver_earnings_cents,
        (select coalesce(sum(t.commission_cents),0) from public.trips t where t.driver_id=d.id and t.status='completed' and coalesce(t.completed_at,t.created_at)>=start_value and coalesce(t.completed_at,t.created_at)<end_value) as platform_commission_cents,
        (select round(avg(r.stars),2) from public.ratings r where r.recipient_id=d.id and r.created_at>=start_value and r.created_at<end_value) as rating,
        (select count(*) from public.ratings r where r.recipient_id=d.id and r.created_at>=start_value and r.created_at<end_value) as ratings_count,
        (select count(*) from public.complaints c join public.trips t on t.id=c.trip_id where t.driver_id=d.id and c.owner_id<>d.id and c.created_at>=start_value and c.created_at<end_value) as incidents,
        (select max(coalesce(t.completed_at,t.created_at)) from public.trips t where t.driver_id=d.id) as last_trip_at
      from public.drivers d join public.profiles p on p.id=d.id
      where driver_value is null or d.id=driver_value
    )x),
    'incidents',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
      select c.id,c.trip_id,c.subject,c.body,c.status,c.response,c.created_at,c.updated_at,owner.full_name as reported_by,
        t.driver_id,driver.full_name as driver_name,t.origin,t.destination
      from public.complaints c join public.profiles owner on owner.id=c.owner_id left join public.trips t on t.id=c.trip_id left join public.profiles driver on driver.id=t.driver_id
      where c.created_at>=start_value and c.created_at<end_value and (driver_value is null or t.driver_id=driver_value)
      order by c.created_at desc limit 500
    )x),
    'ratings',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
      select r.id,r.trip_id,r.stars,r.comfort,r.safety,r.comment,r.created_at,author.full_name as author_name,recipient.full_name as driver_name,recipient.id as driver_id
      from public.ratings r join public.profiles author on author.id=r.author_id join public.profiles recipient on recipient.id=r.recipient_id join public.trips t on t.id=r.trip_id
      where recipient.role='driver' and r.created_at>=start_value and r.created_at<end_value and (driver_value is null or recipient.id=driver_value)
      order by r.created_at desc limit 1000
    )x),
    'insurance',(select coalesce(jsonb_agg(to_jsonb(x) order by x.insurance_expires nulls first,x.full_name),'[]') from (
      select p.id,p.full_name,p.phone,d.vehicle,d.vehicle_make,d.vehicle_model,d.vehicle_year,d.vehicle_color,d.plate,d.category,d.approved,d.insurance_path,d.insurance_expires,
        d.insurance_expires-current_date as days_remaining,
        case when d.insurance_expires is null or d.insurance_expires<current_date then 'expired' when d.insurance_expires<=current_date+30 then 'critical' when d.insurance_expires<=current_date+60 then 'warning' else 'valid' end as status
      from public.drivers d join public.profiles p on p.id=d.id where driver_value is null or d.id=driver_value
    )x),
    'audit',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
      select a.id,a.actor_id,a.action,a.target_id,a.detail,a.created_at,actor.full_name as actor_name,actor.role as actor_role,au.email as actor_email,
        target.full_name as target_name,target.role as target_role,t.origin as target_trip_origin,t.destination as target_trip_destination
      from public.audit_log a join public.profiles actor on actor.id=a.actor_id left join auth.users au on au.id=a.actor_id
      left join public.profiles target on target.id=a.target_id left join public.trips t on t.id=a.target_id
      where a.created_at>=start_value and a.created_at<end_value and (driver_value is null or a.actor_id=driver_value or a.target_id=driver_value or t.driver_id=driver_value)
      order by a.created_at desc limit 500
    )x)
  );
end $$;
revoke all on function private.operations_report_v1(jsonb) from public,anon;
grant execute on function private.operations_report_v1(jsonb) to authenticated;

create function private.update_driver_insurance_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;path_value text;expiry_value date;note_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede renovar pólizas.' using errcode='42501';end if;
  target:=(payload->>'driver_id')::uuid;path_value:=trim(coalesce(payload->>'insurance_path',''));expiry_value:=nullif(payload->>'insurance_expires','')::date;note_value:=trim(coalesce(payload->>'note',''));
  if not exists(select 1 from public.drivers where id=target) then raise exception 'Conductor no encontrado.';end if;
  if expiry_value is null or expiry_value<current_date then raise exception 'La nueva fecha de vigencia debe ser actual o futura.';end if;
  if length(path_value)<5 or not exists(select 1 from storage.objects where bucket_id='yavoi-documents' and name=path_value and (storage.foldername(name))[1]=uid::text) then raise exception 'Adjunta una póliza PDF válida desde la cuenta de Operaciones.';end if;
  if length(note_value)<5 then raise exception 'Registra la referencia o validación de la póliza.';end if;
  update public.drivers set insurance_path=path_value,insurance_expires=expiry_value,updated_at=now() where id=target;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'driver_insurance_renewed',target,jsonb_build_object('insurance_expires',expiry_value,'note',left(note_value,500)));
  return jsonb_build_object('ok',true,'driver_id',target,'insurance_expires',expiry_value);
end $$;
revoke all on function private.update_driver_insurance_v1(jsonb) from public,anon;
grant execute on function private.update_driver_insurance_v1(jsonb) to authenticated;

create function private.log_report_export_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();report_value text;format_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Acceso de Operaciones requerido.' using errcode='42501';end if;
  report_value:=payload->>'report';format_value:=payload->>'format';
  if report_value not in ('overview','drivers','incidents','ratings','insurance','audit') or format_value not in ('pdf','print') then raise exception 'Exportación inválida.';end if;
  insert into public.audit_log(actor_id,action,detail) values(uid,'operations_report_exported',jsonb_build_object('report',report_value,'format',format_value,'period',left(coalesce(payload->>'period',''),20),'driver_id',nullif(payload->>'driver_id','')));
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.log_report_export_v1(jsonb) from public,anon;
grant execute on function private.log_report_export_v1(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v3(payload)
   when 'dashboard' then private.dashboard_v6(payload)
   when 'profile' then private.profile_v3(payload)
   when 'quote' then private.quote_v4(payload)
   when 'available_units' then private.available_units_v3(payload)
   when 'request_trip' then private.request_trip_v6(payload)
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
   when 'transition' then private.transition_v4(payload)
   when 'rating' then private.rating_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v1(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v1(payload)
   when 'operations_report' then private.operations_report_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
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
