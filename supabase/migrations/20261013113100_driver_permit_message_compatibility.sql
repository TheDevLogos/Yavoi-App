create or replace function private.driver_permission_status_v1(target uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.drivers; p public.profiles;
begin
  select * into p from public.profiles where id=target;
  select * into d from public.drivers where id=target;
  if not found or p.role <> 'driver' then
    return jsonb_build_object('allowed',false,'code','not_driver','label','Perfil de conductor no disponible','message','Tu perfil de conductor no está disponible. Contacta a Operaciones.');
  end if;
  if p.suspended then
    return jsonb_build_object('allowed',false,'code','profile_suspended','label','Cuenta suspendida por Operaciones','message','Tu cuenta está suspendida por Operaciones. Revisa tu Bandeja de Entrada.');
  end if;
  if not d.approved then
    return jsonb_build_object('allowed',false,'code','dossier_pending','label','Expediente pendiente de autorización','message','Tu expediente debe estar aprobado por Operaciones antes de que puedas conducir.');
  end if;
  if coalesce(d.license_expires < current_date,true) then
    return jsonb_build_object('allowed',false,'code','license_expired','label','Licencia vencida o pendiente','message','Actualiza tu licencia vigente en Mi perfil para solicitar la autorización.');
  end if;
  if coalesce(d.insurance_expires < current_date,true) then
    return jsonb_build_object('allowed',false,'code','insurance_expired','label','Seguro vencido o pendiente','message','Actualiza tu póliza vigente en Mi perfil para solicitar la autorización.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='overdue') then
    return jsonb_build_object('allowed',false,'code','settlement_overdue','label','Corte semanal vencido','message','Tu corte semanal está vencido. Sube el comprobante desde Mi perfil para que Operaciones lo concilie.');
  end if;
  if exists(select 1 from public.driver_commission_settlements s where s.driver_id=target and s.status='submitted') then
    return jsonb_build_object('allowed',false,'code','settlement_review','label','Comprobante en revisión','message','Operaciones está validando tu comprobante de corte semanal. Recibirás el comprobante de conciliación en tu Bandeja de Entrada.');
  end if;
  if not d.account_active then
    return jsonb_build_object('allowed',false,'code','operations_authorization','label','Permiso pendiente de Operaciones','message','Operaciones debe autorizar tu permiso para conducir. Revisa tu Bandeja de Entrada.');
  end if;
  return jsonb_build_object('allowed',true,'code','authorized','label','Permiso para conducir activo','message','Tu expediente, corte semanal y autorización están vigentes.');
end $$;
revoke all on function private.driver_permission_status_v1(uuid) from public, anon, authenticated;
