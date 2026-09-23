create table if not exists public.feature_cards(
  id text primary key check(id ~ '^[a-z0-9-]{3,80}$'),
  audience text not null check(audience in ('passenger','driver')),
  title text not null check(char_length(title) between 3 and 100),
  summary text not null check(char_length(summary) between 5 and 180),
  body text not null check(char_length(body) between 10 and 1200),
  image_path text,
  cta_label text not null check(char_length(cta_label) between 2 and 50),
  cta_href text not null default '#home' check(cta_href in ('#home','#trips','#wallet','#rewards','#profile','#safety','#help')),
  active boolean not null default true,
  sort_order integer not null default 100 check(sort_order between 0 and 10000),
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists feature_cards_audience_active_order on public.feature_cards(audience,active,sort_order);
alter table public.feature_cards enable row level security;
revoke all on public.feature_cards from anon,authenticated;

insert into public.feature_cards(id,audience,title,summary,body,image_path,cta_label,cta_href,sort_order) values
('passenger-reserve-ahead','passenger','Reserva con tiempo','Aparta una salida para la fecha y hora que necesitas.','Desde Opciones avanzadas puedes programar un viaje y, si lo necesitas, repetirlo cada día, semana o mes. Yavoi! conserva el detalle de cada salida en Mis viajes.','/assets/feature-cards/passenger-reserve-ahead.png','Programar viaje','#home',10),
('passenger-plan-routes','passenger','Planifica tus salidas','Elige destino, servicio y preferencias antes de confirmar.','Consulta la tarifa estimada, el tiempo y la ruta sugerida antes de pedir. Puedes agregar indicaciones para tu conductor y seleccionar las opciones que requiere tu salida.','/assets/feature-cards/passenger-plan-routes.png','Pedir un viaje','#home',20),
('passenger-saved-places','passenger','Lugares que usas','Guarda Casa, Trabajo o Escuela para pedir más rápido.','Después de elegir un destino, guárdalo desde Pedir un viaje. Quedará disponible junto con tus destinos recientes, sin volver a escribir toda la dirección.','/assets/feature-cards/passenger-saved-places.png','Ver destinos','#home',30),
('passenger-safety','passenger','Tu seguridad cuenta','Revisa los datos del viaje y reporta cualquier situación.','Antes de subir, confirma la información del conductor, unidad y placas. Durante el viaje puedes consultar la ruta y, si ocurre algo, crear un reporte para Operaciones.','/assets/feature-cards/passenger-safety.png','Ver seguridad','#safety',40),
('passenger-track-trip','passenger','Sigue tu viaje','Consulta el estado y el recorrido de tus servicios.','Mis viajes reúne los folios, destinos, comprobantes y detalle de cada recorrido. Abre un viaje para ver la información disponible y pedir apoyo relacionado.','/assets/feature-cards/passenger-track-trip.png','Abrir Mis viajes','#trips',50),
('passenger-rewards','passenger','Suma y disfruta','Revisa puntos, recompensas e invitaciones desde tu perfil.','Tus viajes y recomendaciones pueden acercarte a beneficios. Consulta los requisitos, puntos disponibles y los canjes que ya están listos para ti.','/assets/feature-cards/passenger-rewards.png','Ver recompensas','#rewards',60),
('passenger-payments','passenger','Pago claro y seguro','Revisa la tarifa antes de confirmar y conserva tus comprobantes.','Elige efectivo o tarjeta cuando esté disponible. La pantalla de confirmación separa cada concepto de la tarifa y el resumen queda asociado a tu viaje.','/assets/feature-cards/passenger-payments.png','Ver métodos de pago','#wallet',70),
('passenger-help','passenger','Estamos para ayudarte','Encuentra respuestas o abre un reporte con el viaje correcto.','El Centro de ayuda organiza temas de cuenta, pagos, seguridad y viajes recientes. Seleccionar un viaje permite que Operaciones revise el contexto adecuado.','/assets/feature-cards/passenger-help.png','Abrir ayuda','#help',80),
('driver-go-online','driver','Conduce a tu ritmo','Conéctate durante tu turno y controla tu disponibilidad.','Activa tu disponibilidad cuando estés listo para recibir solicitudes compatibles. Puedes desconectarte cuando termines y actualizar tu ubicación mientras estás conectado.','/assets/feature-cards/driver-go-online.png','Ir a Conducir','#home',10),
('driver-offers','driver','Decide cada oferta','Consulta origen, destino, pago y ganancia antes de aceptar.','Cada solicitud muestra el contexto operativo disponible. Revisa el servicio, las indicaciones, la distancia para recoger y el importe antes de decidir.','/assets/feature-cards/driver-offers.png','Ver solicitudes','#home',20),
('driver-earnings','driver','Tus ganancias, claras','Consulta ingresos, cuotas y movimientos en un solo lugar.','La billetera reúne los registros de tus viajes y el estado de tus pagos. Los datos se actualizan con el detalle que Operaciones registra para tu cuenta.','/assets/feature-cards/driver-earnings.png','Ver billetera','#wallet',30),
('driver-schedule','driver','Organiza tu jornada','Conoce el turno y mantén tu disponibilidad al día.','Tu turno asignado se muestra al conectarte. Mantener tu perfil y presencia actualizados ayuda a que las solicitudes lleguen con información correcta.','/assets/feature-cards/driver-schedule.png','Ver mi jornada','#home',40),
('driver-safety','driver','Conduce con respaldo','Consulta las pautas de seguridad y registra incidentes.','Revisa los datos del viaje antes de aceptarlo y usa el reporte dentro de la aplicación si surge una situación que Operaciones deba atender.','/assets/feature-cards/driver-safety.png','Ver seguridad','#safety',50),
('driver-rewards','driver','Reconocemos tu avance','Sigue metas, beneficios y recompensas de conductor.','Las recompensas disponibles consideran los requisitos configurados para tu perfil. Consulta tus puntos y las condiciones antes de iniciar un canje.','/assets/feature-cards/driver-rewards.png','Ver recompensas','#rewards',60),
('driver-profile','driver','Expediente siempre al día','Mantén documentos, unidad y datos de cobro actualizados.','Tu perfil concentra licencia, seguro, vehículo y datos requeridos por Operaciones. Actualizarlos a tiempo evita interrupciones al momento de conectarte.','/assets/feature-cards/driver-profile.png','Abrir mi perfil','#profile',70),
('driver-history','driver','Cada viaje cuenta','Consulta historial, folios y detalle de servicios completados.','Mis viajes conserva la información operativa de tus traslados. Úsala para revisar un recorrido o localizar el contexto de una aclaración.','/assets/feature-cards/driver-history.png','Abrir Mis viajes','#trips',80)
on conflict(id) do nothing;

create or replace function private.dashboard_v18(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;cards jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501'; end if;
  base:=private.dashboard_v17(payload);
  select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order,c.id),'[]'::jsonb) into cards
  from public.feature_cards c
  where p.role='admin' or (c.active and c.audience=p.role);
  return jsonb_set(base,'{marketing,feature_cards}',cards,true);
end $$;
revoke all on function private.dashboard_v18(jsonb) from public,anon;
grant execute on function private.dashboard_v18(jsonb) to authenticated;

create or replace function private.upsert_feature_card_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();result public.feature_cards;card_id text;audience_value text;image_value text;href_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede administrar estas tarjetas.' using errcode='42501'; end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>10000 then raise exception 'Solicitud inválida.'; end if;
  card_id:=trim(coalesce(payload->>'id',''));
  audience_value:=trim(coalesce(payload->>'audience',''));
  image_value:=nullif(trim(coalesce(payload->>'image_path','')),'');
  href_value:=trim(coalesce(payload->>'cta_href','#home'));
  if card_id !~ '^[a-z0-9-]{3,80}$' or audience_value not in ('passenger','driver') then raise exception 'Revisa el identificador y la audiencia.'; end if;
  if char_length(trim(coalesce(payload->>'title','')))<3 or char_length(trim(coalesce(payload->>'summary','')))<5 or char_length(trim(coalesce(payload->>'body','')))<10 then raise exception 'Completa título, resumen e información.'; end if;
  if href_value not in ('#home','#trips','#wallet','#rewards','#profile','#safety','#help') then raise exception 'El destino de la tarjeta no es válido.'; end if;
  if image_value is not null and image_value !~ '^/assets/feature-cards/' and not exists(select 1 from storage.objects where bucket_id='yavoi-marketing' and name=image_value) then raise exception 'La imagen no existe.'; end if;
  insert into public.feature_cards(id,audience,title,summary,body,image_path,cta_label,cta_href,active,sort_order,created_by,updated_by)
  values(card_id,audience_value,left(trim(payload->>'title'),100),left(trim(payload->>'summary'),180),left(trim(payload->>'body'),1200),image_value,left(trim(coalesce(payload->>'cta_label','Abrir opción')),50),href_value,coalesce((payload->>'active')::boolean,true),coalesce((payload->>'sort_order')::integer,100),uid,uid)
  on conflict(id) do update set audience=excluded.audience,title=excluded.title,summary=excluded.summary,body=excluded.body,image_path=coalesce(excluded.image_path,public.feature_cards.image_path),cta_label=excluded.cta_label,cta_href=excluded.cta_href,active=excluded.active,sort_order=excluded.sort_order,updated_by=uid,updated_at=now()
  returning * into result;
  insert into public.audit_log(actor_id,action,detail) values(uid,'feature_card_saved',jsonb_build_object('feature_card_id',result.id,'audience',result.audience,'active',result.active));
  return to_jsonb(result);
end $$;
revoke all on function private.upsert_feature_card_v1(jsonb) from public,anon;
grant execute on function private.upsert_feature_card_v1(jsonb) to authenticated;

create or replace function private.set_feature_card_active_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();card_id text:=trim(coalesce(payload->>'feature_card_id',''));active_value boolean:=coalesce((payload->>'active')::boolean,false);
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones puede administrar estas tarjetas.' using errcode='42501'; end if;
  update public.feature_cards set active=active_value,updated_by=uid,updated_at=now() where id=card_id;
  if not found then raise exception 'Tarjeta no encontrada.'; end if;
  insert into public.audit_log(actor_id,action,detail) values(uid,'feature_card_status_changed',jsonb_build_object('feature_card_id',card_id,'active',active_value));
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.set_feature_card_active_v1(jsonb) from public,anon;
grant execute on function private.set_feature_card_active_v1(jsonb) to authenticated;

create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
 select case command
   when 'bootstrap' then private.bootstrap_v4(payload)
   when 'dashboard' then private.dashboard_v18(payload)
   when 'onboard' then private.onboard_referral_v2(payload)
   when 'profile' then private.profile_v5(payload)
   when 'quote' then private.quote_v5(payload)
   when 'available_units' then private.available_units_v4(payload)
   when 'request_trip' then private.request_trip_v10(payload)
   when 'trip' then private.trip_v10(payload)
   when 'capture_trip_route' then private.capture_visible_trip_route_v1(payload)
   when 'driver_profile' then private.driver_profile_v9(payload)
   when 'save_driver_profile_draft' then private.save_driver_profile_draft_v1(payload)
   when 'review_driver' then private.review_driver_v3(payload)
   when 'authorize_profile_edit' then private.authorize_profile_edit_v1(payload)
   when 'availability' then private.availability_v7(payload)
   when 'presence' then private.presence_v4(payload)
   when 'location' then private.location_v3(payload)
   when 'offers' then private.offers_v7(payload)
   when 'accept' then private.accept_offer_v3(payload)
   when 'reject_offer' then private.reject_offer_v1(payload)
   when 'save_ride_draft' then private.save_ride_draft_v1(payload)
   when 'clear_ride_draft' then private.clear_ride_draft_v1(payload)
   when 'save_saved_place' then private.save_saved_place_v1(payload)
   when 'delete_saved_place' then private.delete_saved_place_v1(payload)
   when 'transition' then private.transition_v9(payload)
   when 'cancellation_quote' then private.cancellation_quote_v1(payload)
   when 'settle_cancellation_fee' then private.settle_cancellation_fee_v1(payload)
   when 'complaint' then private.complaint_v2(payload)
   when 'rating' then private.rating_v3(payload)
   when 'rating_and_report' then private.rating_and_report_v2(payload)
   when 'redeem_reward' then private.redeem_reward_v5(payload)
   when 'review_reward_redemption' then private.review_reward_redemption_v2(payload)
   when 'set_marketing_settings' then private.set_marketing_settings_v1(payload)
   when 'set_reward_active' then private.set_reward_active_v1(payload)
   when 'upsert_reward' then private.upsert_reward_v3(payload)
   when 'upsert_campaign' then private.upsert_campaign_v1(payload)
   when 'set_campaign_active' then private.set_campaign_active_v1(payload)
   when 'upsert_feature_card' then private.upsert_feature_card_v1(payload)
   when 'set_feature_card_active' then private.set_feature_card_active_v1(payload)
   when 'operations_report' then private.operations_report_v5(payload)
   when 'transport_compliance' then private.transport_compliance_v1(payload)
   when 'update_driver_insurance' then private.update_driver_insurance_v1(payload)
   when 'log_report_export' then private.log_report_export_v1(payload)
   when 'set_driver_billing' then private.set_driver_billing_v1(payload)
   when 'submit_driver_settlement' then private.submit_driver_settlement_v1(payload)
   when 'review_driver_settlement' then private.review_driver_settlement_v1(payload)
   when 'review_driver_promotion_reimbursement' then private.review_driver_promotion_reimbursement_v1(payload)
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
   when 'upsert_service_shift' then private.upsert_service_shift_v1(payload)
   when 'set_driver_shift' then private.set_driver_shift_v1(payload)
   else private.dispatch(command,payload) end
$$;
