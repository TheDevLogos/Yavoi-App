-- Device registrations are role neutral. The existing driver table remains
-- available to the offer webhook; this table lets passenger reminders share
-- the same persistent Web Push channel.
create table if not exists public.device_push_subscriptions(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(profile_id,endpoint)
);
alter table public.device_push_subscriptions enable row level security;
revoke all on public.device_push_subscriptions from anon,authenticated;

create or replace function private.push_subscription_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); endpoint_value text:=left(trim(payload->>'endpoint'),2048); key_value text:=left(trim(payload->>'p256dh'),512); auth_value text:=left(trim(payload->>'auth'),512); profile_role text;
begin
  select role into profile_role from public.profiles where id=uid and not suspended;
  if uid is null or profile_role is null then raise exception 'Cuenta activa requerida.' using errcode='42501'; end if;
  if endpoint_value !~ '^https://' or length(key_value)<20 or length(auth_value)<10 then raise exception 'Suscripción de notificaciones inválida.'; end if;
  insert into public.device_push_subscriptions(profile_id,endpoint,p256dh,auth,user_agent,updated_at)
  values(uid,endpoint_value,key_value,auth_value,left(coalesce(payload->>'user_agent',''),300),now())
  on conflict(profile_id,endpoint) do update set p256dh=excluded.p256dh,auth=excluded.auth,user_agent=excluded.user_agent,updated_at=now();
  if profile_role='driver' then
    insert into public.driver_push_subscriptions(driver_id,endpoint,p256dh,auth,user_agent,updated_at)
    values(uid,endpoint_value,key_value,auth_value,left(coalesce(payload->>'user_agent',''),300),now())
    on conflict(driver_id,endpoint) do update set p256dh=excluded.p256dh,auth=excluded.auth,user_agent=excluded.user_agent,updated_at=now();
  end if;
  return jsonb_build_object('ok',true,'role',profile_role);
end $$;
revoke all on function private.push_subscription_v1(jsonb) from public,anon;
grant execute on function private.push_subscription_v1(jsonb) to authenticated;

create table if not exists public.push_notification_templates(
  id text primary key, audience text not null check(audience in ('passenger','driver')), title text not null, body text not null, target text not null default 'home', priority text not null default 'normal' check(priority in ('normal','high')), active boolean not null default true, created_at timestamptz not null default now()
);
alter table public.push_notification_templates enable row level security;
revoke all on public.push_notification_templates from anon,authenticated;
insert into public.push_notification_templates(id,audience,title,body,target,priority) values
('passenger-rewards','passenger','Tus recompensas te esperan','Consulta tus puntos y beneficios disponibles en Yavoi!.','rewards','normal'),
('passenger-safety','passenger','Tu viaje, visible y seguro','Comparte el seguimiento de tu viaje desde Yavoi!.','trips','high'),
('passenger-transparency','passenger','Información clara antes de subir','Revisa tarifa, conductor y unidad antes de iniciar.','trips','normal'),
('passenger-saved-places','passenger','Guarda tus destinos frecuentes','Casa, trabajo o escuela estarán listos al pedir.','home','normal'),
('passenger-schedule','passenger','Planea tu próxima salida','Programa tu viaje con anticipación desde Yavoi!.','home','normal'),
('passenger-rating','passenger','Tu opinión mejora Yavoi!','Califica tu último servicio cuando termine.','trips','normal'),
('passenger-payment','passenger','Métodos de pago claros','Confirma el método de pago antes de solicitar.','home','normal'),
('passenger-help','passenger','Ayuda cuando la necesitas','Consulta tus viajes y reporta cualquier incidencia.','trips','normal'),
('passenger-reliability','passenger','Servicio confiable en tu ciudad','Mantén actualizada tu ubicación para una mejor recogida.','home','normal'),
('passenger-route','passenger','Sigue tu recorrido','Consulta la ruta propuesta y el avance de tu viaje.','trips','normal'),
('driver-offers','driver','No pierdas una solicitud','Activa las alertas para abrir y decidir cada viaje a tiempo.','home','high'),
('driver-location','driver','Tu ubicación mantiene activa la operación','Permite ubicación para recibir solicitudes compatibles.','home','high'),
('driver-queue','driver','Organiza tu siguiente viaje','Las solicitudes en cola aparecen durante tu servicio.','trips','normal'),
('driver-safety','driver','Seguridad en cada servicio','Consulta datos del viaje y reporta incidentes desde Mis viajes.','trips','high'),
('driver-earnings','driver','Tus ingresos siempre visibles','Revisa tus ganancias y cobros desde tu perfil.','rewards','normal'),
('driver-rewards','driver','Tus recompensas avanzan contigo','Consulta puntos, nivel y beneficios de conductor.','rewards','normal'),
('driver-rating','driver','La calidad abre nuevas oportunidades','Mantén un servicio claro y respetuoso en cada viaje.','home','normal'),
('driver-documents','driver','Mantén tu expediente vigente','Operaciones revisa tu documentación y vigencias.','profile','normal'),
('driver-route','driver','Navegación integrada','Sigue la ruta dentro de Yavoi! durante el servicio.','trips','normal'),
('driver-demand','driver','Hay demanda disponible','Las solicitudes pendientes se priorizan sin interrumpir tu viaje actual.','home','high')
on conflict(id) do update set audience=excluded.audience,title=excluded.title,body=excluded.body,target=excluded.target,priority=excluded.priority,active=true;

