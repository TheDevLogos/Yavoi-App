-- An Operations reactivation must survive dashboard and availability checks.
-- Existing overdue fees remain visible for accounting; a later unpaid fee can
-- suspend the account again.
alter table public.drivers
  add column account_access_authorized_at timestamptz,
  add column account_access_authorized_by uuid references public.profiles(id),
  add column account_access_note text not null default '' check(char_length(account_access_note)<=500);

create index drivers_account_access_authorized_by
  on public.drivers(account_access_authorized_by)
  where account_access_authorized_by is not null;

create or replace function private.dashboard_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;
begin
 select * into p from public.profiles where id=uid;
 base:=private.dispatch('dashboard',payload);
 if p.role='driver' then perform private.ensure_weekly_fee(uid);end if;
 if p.role='admin' then
   update public.weekly_fees set status='overdue',updated_at=now()
   where status in ('pending','submitted') and due_at<now();
   update public.drivers d set account_active=false,online=false,updated_at=now()
   where d.billing_mode='weekly_fee' and exists(
     select 1 from public.weekly_fees f
     where f.driver_id=d.id and f.status='overdue'
       and (d.account_access_authorized_at is null or f.due_at>d.account_access_authorized_at)
   );
 end if;
 return base||jsonb_build_object(
  'payments',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
    select pay.*,t.origin,t.destination,pr.full_name as payer_name,drp.full_name as driver_name
    from public.payments pay left join public.trips t on t.id=pay.trip_id
    join public.profiles pr on pr.id=pay.payer_id left join public.profiles drp on drp.id=pay.driver_id
    where pay.payer_id=uid or pay.driver_id=uid or p.role='admin' order by pay.created_at desc limit 500)x),
  'weekly_fees',(select coalesce(jsonb_agg(to_jsonb(x) order by x.week_start desc),'[]') from (
    select f.*,pr.full_name as driver_name,d.account_active,d.account_access_authorized_at,
      d.account_access_authorized_by,d.account_access_note
    from public.weekly_fees f join public.profiles pr on pr.id=f.driver_id
    join public.drivers d on d.id=f.driver_id
    where f.driver_id=uid or p.role='admin' order by f.week_start desc limit 500)x)
 );
end $$;
revoke all on function private.dashboard_v3(jsonb) from public,anon;
grant execute on function private.dashboard_v3(jsonb) to authenticated;

create or replace function private.availability_v3(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;d public.drivers;going_online boolean;fee public.weekly_fees;
begin
 select * into p from public.profiles where id=uid;
 select * into d from public.drivers where id=uid for update;
 if not found or p.role<>'driver' then raise exception 'Acceso de conductor requerido.' using errcode='42501';end if;
 going_online:=coalesce((payload->>'online')::boolean,false);
 fee:=private.ensure_weekly_fee(uid);
 if exists(
   select 1 from public.weekly_fees f
   where f.driver_id=uid and f.status in ('pending','submitted','overdue') and f.due_at<now()
     and (d.account_access_authorized_at is null or f.due_at>d.account_access_authorized_at)
 ) then
   update public.weekly_fees set status='overdue',updated_at=now()
   where driver_id=uid and status in ('pending','submitted') and due_at<now()
     and (d.account_access_authorized_at is null or due_at>d.account_access_authorized_at);
   update public.drivers set account_active=false,online=false,updated_at=now() where id=uid;
   d.account_active:=false;
 end if;
 if going_online and (not d.approved or not d.account_active or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then raise exception 'Tu expediente debe estar aprobado; el acceso semanal y los documentos deben estar activos y vigentes.';end if;
 if exists(select 1 from public.trips where driver_id=uid and status not in ('completed','cancelled')) then raise exception 'Termina tu viaje antes de cambiar tu disponibilidad.';end if;
 update public.drivers set online=going_online,updated_at=now() where id=uid;
 return jsonb_build_object('ok',true,'weekly_fee',to_jsonb(fee),'account_active',d.account_active);
end $$;
revoke all on function private.availability_v3(jsonb) from public,anon;
grant execute on function private.availability_v3(jsonb) to authenticated;

create or replace function private.set_driver_access_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();target uuid;active_value boolean;note_value text;d public.drivers;covered integer:=0;
begin
 if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede realizar esta acción.' using errcode='42501';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>4000 then raise exception 'Solicitud inválida.';end if;
 target:=(payload->>'driver_id')::uuid;
 active_value:=coalesce((payload->>'active')::boolean,false);
 note_value:=trim(coalesce(payload->>'note',''));
 if char_length(note_value)<5 or char_length(note_value)>500 then raise exception 'Describe el motivo del cambio de acceso (5 a 500 caracteres).';end if;
 select * into d from public.drivers where id=target for update;
 if not found then raise exception 'Conductor no encontrado.';end if;
 if active_value and (not d.approved or coalesce(d.license_expires<current_date,true) or coalesce(d.insurance_expires<current_date,true)) then
   raise exception 'El conductor necesita expediente aprobado y documentos vigentes antes de reactivar su cuenta.';
 end if;
 if active_value then
   select count(*)::integer into covered from public.weekly_fees
   where driver_id=target and status='overdue' and due_at<=now();
   update public.drivers set account_active=true,account_access_authorized_at=now(),
     account_access_authorized_by=uid,account_access_note=left(note_value,500),updated_at=now()
   where id=target;
 else
   update public.drivers set account_active=false,online=false,account_access_authorized_at=null,
     account_access_authorized_by=null,account_access_note=left(note_value,500),updated_at=now()
   where id=target;
 end if;
 insert into public.audit_log(actor_id,action,target_id,detail)
 values(uid,'set_driver_access',target,jsonb_build_object('active',active_value,'note',note_value,'overdue_fees_preserved',covered));
 return jsonb_build_object('ok',true,'active',active_value,'overdue_fees_preserved',covered);
end $$;
revoke all on function private.set_driver_access_v1(jsonb) from public,anon;
grant execute on function private.set_driver_access_v1(jsonb) to authenticated;
