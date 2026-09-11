-- Scalable rewards for passengers and drivers. Points are an append-only ledger;
-- redemptions are server controlled and ride benefits are applied atomically.
alter table public.reward_entries alter column trip_id drop not null;
alter table public.reward_entries drop constraint reward_entries_user_id_trip_id_key;
alter table public.reward_entries
  add column entry_type text not null default 'trip_complete' check(entry_type in ('trip_complete','rating_given','rating_bonus','adjustment','redemption','redemption_refund')),
  add column description text not null default '' check(char_length(description)<=200),
  add column source_key text,
  add column detail jsonb not null default '{}';
create unique index reward_entries_trip_type on public.reward_entries(user_id,trip_id,entry_type) where trip_id is not null;
create unique index reward_entries_source_key on public.reward_entries(source_key) where source_key is not null;

create table public.reward_catalog(
  id text primary key check(id ~ '^[a-z0-9_]{3,60}$'),
  audience text not null check(audience in ('passenger','driver')),
  name text not null check(char_length(name) between 3 and 100),
  description text not null check(char_length(description) between 5 and 500),
  kind text not null check(kind in ('fare_discount_fixed','fare_discount_percent','free_local_trip','ride_amenity','partner_coupon','driver_benefit')),
  icon text not null default 'gift' check(char_length(icon)<=40),
  points_cost integer not null check(points_cost>=0),
  value_cents integer check(value_cents>=0),
  value_percent numeric check(value_percent between 0 and 100),
  max_discount_cents integer check(max_discount_cents>=0),
  eligible_category text references public.categories(id),
  min_trips integer not null default 0 check(min_trips>=0),
  min_rating numeric check(min_rating between 1 and 5),
  min_income_cents integer not null default 0 check(min_income_cents>=0),
  max_recent_incidents integer check(max_recent_incidents>=0),
  partner_name text not null default '' check(char_length(partner_name)<=100),
  fulfillment_note text not null default '' check(char_length(fulfillment_note)<=500),
  automatic boolean not null default false,
  milestone_every integer check(milestone_every>0),
  total_stock integer check(total_stock>=0),
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((kind='fare_discount_fixed' and value_cents is not null) or kind<>'fare_discount_fixed'),
  check((kind='fare_discount_percent' and value_percent is not null and max_discount_cents is not null) or kind<>'fare_discount_percent'),
  check((not automatic) or milestone_every is not null)
);

create table public.reward_redemptions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  reward_id text not null references public.reward_catalog(id),
  trip_id uuid references public.trips(id),
  code text not null unique check(code ~ '^YV-[A-F0-9]{8}$'),
  status text not null check(status in ('available','requested','applied','fulfilled','cancelled','expired')),
  points_spent integer not null check(points_spent>=0),
  source_key text unique,
  operations_note text not null default '' check(char_length(operations_note)<=500),
  requested_at timestamptz not null default now(),
  expires_at timestamptz,
  applied_at timestamptz,
  fulfilled_at timestamptz,
  fulfilled_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
create index reward_redemptions_user_status on public.reward_redemptions(user_id,status,requested_at desc);
create index reward_redemptions_trip on public.reward_redemptions(trip_id) where trip_id is not null;
create index reward_redemptions_fulfilled_by on public.reward_redemptions(fulfilled_by) where fulfilled_by is not null;

alter table public.reward_entries add column redemption_id uuid references public.reward_redemptions(id);
create unique index reward_entries_redemption_type on public.reward_entries(redemption_id,entry_type) where redemption_id is not null;
alter table public.trips
  add column reward_redemption_id uuid references public.reward_redemptions(id),
  add column reward_discount_cents integer not null default 0 check(reward_discount_cents>=0 and reward_discount_cents<=fare_cents);
create index trips_reward_redemption on public.trips(reward_redemption_id) where reward_redemption_id is not null;

insert into public.reward_catalog(id,audience,name,description,kind,icon,points_cost,value_cents,value_percent,max_discount_cents,eligible_category,min_trips,min_rating,min_income_cents,max_recent_incidents,partner_name,fulfillment_note,automatic,milestone_every,total_stock,active,sort_order) values
('passenger_refreshment','passenger','Refresco en tu próximo viaje','Una bebida individual entregada durante un viaje participante.','ride_amenity','cup-soda',45,null,null,null,null,2,null,0,null,'Yavoi!','Sujeto a inventario de la unidad asignada.',false,null,null,true,10),
('passenger_snack','passenger','Botana para el camino','Una botana individual incluida en tu próximo viaje participante.','ride_amenity','popcorn',70,null,null,null,null,3,null,0,null,'Yavoi!','Sujeto a inventario de la unidad asignada.',false,null,null,true,20),
('passenger_discount_20','passenger','$20 para tu próximo viaje','Descuento directo de $20 en un próximo viaje Yavoi!.','fare_discount_fixed','badge-dollar-sign',120,2000,null,null,null,5,null,0,null,'Yavoi!','Se aplica antes de confirmar el cobro.',false,null,null,true,30),
('passenger_discount_15','passenger','15% de descuento','Ahorra 15% en un viaje; descuento máximo de $40.','fare_discount_percent','badge-percent',200,null,15,4000,null,8,null,0,null,'Yavoi!','Se aplica antes de confirmar el cobro.',false,null,null,true,40),
('passenger_movie_ticket','passenger','Boleto de cine','Canje por un boleto de cine con proveedor participante.','partner_coupon','ticket',350,null,null,null,null,12,null,0,null,'Proveedor por definir','Operaciones entregará el cupón cuando exista un convenio activo.',false,null,null,false,50),
('passenger_partner_coupon','passenger','Cupón con comercio local','Descuento especial con un proveedor local participante.','partner_coupon','store',250,null,null,null,null,10,null,0,null,'Proveedor por definir','Se activará al formalizar el convenio comercial.',false,null,null,false,60),
('passenger_free_local_15','passenger','Viaje local Básico gratis','Un viaje local en categoría Básico, sin incluir propina, por cada 15 viajes completados.','free_local_trip','car-front',0,null,null,null,'basic',15,null,0,null,'Yavoi!','Se genera automáticamente y puede acumularse.',true,15,null,true,5),
('driver_wash_discount','driver','15% en lavado exterior','Descuento para mantener tu unidad limpia y presentable.','driver_benefit','droplets',100,null,null,null,null,10,4.50,250000,1,'Proveedor por definir','Operaciones entregará un cupón al validar disponibilidad.',false,null,null,true,10),
('driver_wash_free','driver','Lavado exterior gratis','Un lavado exterior sin costo con proveedor participante.','driver_benefit','sparkles',280,null,null,null,null,25,4.60,600000,0,'Proveedor por definir','Operaciones coordinará el canje con el proveedor.',false,null,null,true,20),
('driver_full_wash','driver','30% en lavado completo','Descuento en lavado exterior e interior.','driver_benefit','car-front',420,null,null,null,null,40,4.65,1000000,0,'Proveedor por definir','Operaciones entregará el cupón correspondiente.',false,null,null,true,30),
('driver_parts_discount','driver','Descuento en refacciones','Cupón para compra de refacciones con proveedor participante.','driver_benefit','wrench',500,null,null,null,null,45,4.65,1200000,0,'Proveedor por definir','Beneficio sujeto al convenio y sus condiciones.',false,null,null,false,40),
('driver_oil_discount','driver','Descuento en cambio de aceite','Apoyo para el mantenimiento preventivo de tu unidad.','driver_benefit','gauge',550,null,null,null,null,50,4.70,1500000,0,'Proveedor por definir','Operaciones entregará el cupón correspondiente.',false,null,null,true,50),
('driver_cap','driver','Gorra Yavoi!','Gorra oficial para conductores destacados.','driver_benefit','crown',700,null,null,null,null,60,4.70,1800000,0,'Yavoi!','Recoge el artículo después de la confirmación de Operaciones.',false,null,100,true,60),
('driver_tumbler','driver','Thermo Yavoi!','Thermo reutilizable para tus jornadas de conducción.','driver_benefit','cup-soda',750,null,null,null,null,65,4.75,2000000,0,'Yavoi!','Recoge el artículo después de la confirmación de Operaciones.',false,null,100,true,70),
('driver_tuneup','driver','Descuento en afinación','Beneficio para una afinación preventiva con proveedor participante.','driver_benefit','settings',1000,null,null,null,null,80,4.75,2800000,0,'Proveedor por definir','Operaciones validará el cupón y sus condiciones.',false,null,null,true,80),
('driver_free_full_wash','driver','Lavado completo gratis','Lavado exterior e interior para conductores de alto desempeño.','driver_benefit','shield-check',1200,null,null,null,null,100,4.80,3500000,0,'Proveedor por definir','Operaciones coordinará la cita o cupón.',false,null,null,true,90),
('driver_cooler','driver','Hielera eléctrica para tu unidad','Equipo de 12 V para conductores con trayectoria sobresaliente.','driver_benefit','snowflake',2200,null,null,null,null,180,4.85,6500000,0,'Yavoi!','Sujeto a inventario y revisión final de Operaciones.',false,null,30,true,100);

alter table public.reward_catalog enable row level security;
alter table public.reward_redemptions enable row level security;
revoke all on public.reward_catalog,public.reward_redemptions from anon,authenticated;
grant select on public.reward_catalog,public.reward_redemptions to authenticated;
create policy reward_catalog_read on public.reward_catalog for select to authenticated using(true);
create policy reward_redemptions_own on public.reward_redemptions for select to authenticated using(user_id=(select auth.uid()) or (select private.is_admin()));

create function private.reward_metrics(target uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare role_value text;available_value integer;lifetime_value integer;trip_value integer;rating_value numeric;income_value integer;incident_value integer;level_value text;next_level_value text;next_points_value integer;
begin
  select role into role_value from public.profiles where id=target;
  if role_value not in ('passenger','driver') then return '{}'::jsonb;end if;
  select coalesce(sum(points),0),coalesce(sum(points) filter(where points>0),0) into available_value,lifetime_value from public.reward_entries where user_id=target;
  select count(*) into trip_value from public.trips where status='completed' and (case when role_value='driver' then driver_id=target else passenger_id=target end);
  select round(avg(stars),2) into rating_value from public.ratings where recipient_id=target;
  select coalesce(sum(fare_cents),0) into income_value from public.trips where status='completed' and driver_id=target;
  if role_value='driver' then
    select count(*) into incident_value from public.complaints c join public.trips t on t.id=c.trip_id where t.driver_id=target and c.owner_id<>target and c.created_at>now()-interval '90 days';
    if lifetime_value>=1600 then level_value:='Referente';next_level_value:=null;next_points_value:=null;
    elsif lifetime_value>=800 then level_value:='Élite';next_level_value:='Referente';next_points_value:=1600;
    elsif lifetime_value>=300 then level_value:='Destacado';next_level_value:='Élite';next_points_value:=800;
    else level_value:='Activo';next_level_value:='Destacado';next_points_value:=300;end if;
  else
    incident_value:=0;
    if lifetime_value>=900 then level_value:='Embajador';next_level_value:=null;next_points_value:=null;
    elsif lifetime_value>=400 then level_value:='Frecuente';next_level_value:='Embajador';next_points_value:=900;
    elsif lifetime_value>=150 then level_value:='Viajero';next_level_value:='Frecuente';next_points_value:=400;
    else level_value:='Explorador';next_level_value:='Viajero';next_points_value:=150;end if;
  end if;
  return jsonb_build_object('role',role_value,'available_points',greatest(available_value,0),'lifetime_points',lifetime_value,'trip_count',trip_value,'rating',rating_value,'income_cents',income_value,'recent_incidents',incident_value,'level',level_value,'next_level',next_level_value,'next_level_points',next_points_value,'trips_to_free_ride',case when role_value='passenger' then 15-(trip_value%15) else null end);
end $$;
revoke all on function private.reward_metrics(uuid) from public,anon,authenticated;

create function private.redeem_reward_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;reward public.reward_catalog;metrics jsonb;redemption public.reward_redemptions;balance integer;redeemed_count integer;initial_status text;
begin
  select * into p from public.profiles where id=uid for update;
  if uid is null or not found or p.suspended or p.role not in ('passenger','driver') then raise exception 'Cuenta no disponible para canjes.' using errcode='42501';end if;
  if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>2000 then raise exception 'Solicitud inválida.';end if;
  select * into reward from public.reward_catalog where id=payload->>'reward_id' for update;
  if not found or reward.audience<>p.role then raise exception 'Recompensa no disponible para tu cuenta.';end if;
  if not reward.active then raise exception 'Esta recompensa estará disponible al confirmar el proveedor.';end if;
  if reward.automatic then raise exception 'Esta recompensa se genera automáticamente al cumplir la meta.';end if;
  metrics:=private.reward_metrics(uid);balance:=(metrics->>'available_points')::integer;
  if balance<reward.points_cost then raise exception 'Aún no tienes los puntos necesarios.';end if;
  if (metrics->>'trip_count')::integer<reward.min_trips then raise exception 'Aún no cumples el número mínimo de viajes.';end if;
  if reward.min_rating is not null and coalesce((metrics->>'rating')::numeric,0)<reward.min_rating then raise exception 'Tu rating aún no cumple el nivel requerido.';end if;
  if (metrics->>'income_cents')::integer<reward.min_income_cents then raise exception 'Aún no cumples la meta de ingresos de esta recompensa.';end if;
  if reward.max_recent_incidents is not null and (metrics->>'recent_incidents')::integer>reward.max_recent_incidents then raise exception 'Esta recompensa requiere un historial reciente sin incidentes.';end if;
  if reward.total_stock is not null then
    select count(*) into redeemed_count from public.reward_redemptions where reward_id=reward.id and status not in ('cancelled','expired');
    if redeemed_count>=reward.total_stock then raise exception 'La recompensa agotó su inventario actual.';end if;
  end if;
  initial_status:=case when reward.kind in ('fare_discount_fixed','fare_discount_percent','ride_amenity') then 'available' else 'requested' end;
  insert into public.reward_redemptions(user_id,reward_id,code,status,points_spent,expires_at)
  values(uid,reward.id,'YV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),initial_status,reward.points_cost,now()+interval '180 days') returning * into redemption;
  insert into public.reward_entries(user_id,trip_id,points,entry_type,description,redemption_id,detail)
  values(uid,null,-reward.points_cost,'redemption','Canje: '||reward.name,redemption.id,jsonb_build_object('reward_id',reward.id));
  return to_jsonb(redemption)||jsonb_build_object('reward',to_jsonb(reward),'balance',balance-reward.points_cost);
end $$;
revoke all on function private.redeem_reward_v1(jsonb) from public,anon;
grant execute on function private.redeem_reward_v1(jsonb) to authenticated;

create function private.request_trip_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();existing public.trips;q public.quotes;redemption public.reward_redemptions;reward public.reward_catalog;call_payload jsonb:=payload;result jsonb;target_trip uuid;discount_value integer:=0;tip_value integer;final_total integer;actual_method text;tender integer;payment_id uuid;code_value text:=upper(trim(coalesce(payload->>'reward_code','')));
begin
  select * into existing from public.trips where passenger_id=uid and request_key=(payload->>'request_key')::uuid;
  if found then return to_jsonb(existing)||jsonb_build_object('payment_id',(select id from public.payments where trip_id=existing.id and kind='ride' order by created_at limit 1));end if;
  if code_value<>'' then
    select r.* into redemption from public.reward_redemptions r where r.user_id=uid and r.code=code_value for update;
    if not found or redemption.status<>'available' or (redemption.expires_at is not null and redemption.expires_at<=now()) then raise exception 'La recompensa elegida no está disponible.';end if;
    select * into reward from public.reward_catalog where id=redemption.reward_id and active;
    if not found or reward.audience<>'passenger' or reward.kind not in ('fare_discount_fixed','fare_discount_percent','free_local_trip','ride_amenity') then raise exception 'Esta recompensa no puede aplicarse a un viaje.';end if;
    select * into q from public.quotes where id=(payload->>'quote_id')::uuid and passenger_id=uid;
    if not found or q.expires_at<now() then raise exception 'La cotización venció. Calcula una nueva tarifa.';end if;
    if reward.eligible_category is not null and reward.eligible_category<>q.category then raise exception 'La recompensa requiere otra categoría de servicio.';end if;
    if reward.kind='free_local_trip' and q.service_zone='regional' then raise exception 'El viaje gratis sólo puede aplicarse dentro de la zona local.';end if;
    discount_value:=case reward.kind when 'fare_discount_fixed' then least(q.fare_cents,reward.value_cents) when 'fare_discount_percent' then least(round(q.fare_cents*reward.value_percent/100.0)::integer,reward.max_discount_cents) when 'free_local_trip' then q.fare_cents else 0 end;
    tip_value:=coalesce((payload->>'tip_cents')::integer,0);
    if payload->>'payment_method'='cash' then call_payload:=jsonb_set(call_payload,'{cash_tender_cents}',to_jsonb(q.fare_cents+tip_value));end if;
    if payload->>'payment_method'='card' and q.fare_cents-discount_value+tip_value=0 then call_payload:=jsonb_set(jsonb_set(call_payload,'{payment_method}','"cash"'::jsonb),'{cash_tender_cents}',to_jsonb(q.fare_cents));end if;
  end if;
  call_payload:=call_payload-'reward_code';
  result:=private.request_trip_v5(call_payload);target_trip:=(result->>'id')::uuid;
  if code_value='' then return result;end if;
  select * into existing from public.trips where id=target_trip for update;
  final_total:=greatest(0,existing.fare_cents-discount_value)+existing.tip_cents;
  actual_method:=case when final_total=0 then 'cash' else payload->>'payment_method' end;
  if actual_method='cash' then
    tender:=coalesce((payload->>'cash_tender_cents')::integer,final_total);
    if tender<final_total or tender>300000 then raise exception 'Indica un monto de efectivo válido para el total con recompensa.';end if;
  else tender:=null;end if;
  update public.trips set reward_redemption_id=redemption.id,reward_discount_cents=discount_value,total_cents=final_total,payment_method=actual_method,cash_tender_cents=tender,
    service_notes=case when reward.kind='ride_amenity' then left(concat_ws(E'\n',nullif(service_notes,''),'Recompensa solicitada: '||reward.name),500) else service_notes end,updated_at=now()
  where id=target_trip returning * into existing;
  update public.payments set amount_cents=final_total,provider=case when actual_method='card' then 'mercado_pago' else 'cash' end,status=case when actual_method='card' then status else 'pending' end,updated_at=now()
  where trip_id=target_trip and kind='ride' returning id into payment_id;
  update public.reward_redemptions set status='applied',trip_id=target_trip,applied_at=now(),updated_at=now() where id=redemption.id;
  insert into public.trip_events(trip_id,actor_id,event,detail) values(target_trip,uid,'reward_applied',jsonb_build_object('reward_id',reward.id,'redemption_id',redemption.id,'discount_cents',discount_value));
  return to_jsonb(existing)||jsonb_build_object('payment_id',payment_id,'reward',to_jsonb(reward));
end $$;
revoke all on function private.request_trip_v6(jsonb) from public,anon;
grant execute on function private.request_trip_v6(jsonb) to authenticated;

create function private.transition_v4(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;t public.trips;completed_count integer;driver_points integer;milestone integer;
begin
  result:=private.transition_v3(payload);
  if result ? 'error' then return result;end if;
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  if t.status='completed' and payload->>'status'='completed' then
    update public.reward_entries set points=10,entry_type='trip_complete',description='Viaje completado · Puntos Viajeros' where user_id=t.passenger_id and trip_id=t.id and entry_type='trip_complete';
    driver_points:=12+least(8,floor(t.fare_cents/5000.0)::integer);
    update public.reward_entries set points=driver_points,entry_type='trip_complete',description='Viaje e ingreso generado · Rating Yavoi!' where user_id=t.driver_id and trip_id=t.id and entry_type='trip_complete';
    select count(*) into completed_count from public.trips where passenger_id=t.passenger_id and status='completed';
    if completed_count>0 and completed_count%15=0 then
      milestone:=completed_count/15;
      insert into public.reward_redemptions(user_id,reward_id,code,status,points_spent,source_key,expires_at)
      values(t.passenger_id,'passenger_free_local_15','YV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'available',0,'free_local:'||t.passenger_id::text||':'||milestone,now()+interval '365 days') on conflict(source_key) do nothing;
    end if;
  elsif t.status='cancelled' and t.reward_redemption_id is not null then
    update public.reward_redemptions set status='available',trip_id=null,applied_at=null,updated_at=now() where id=t.reward_redemption_id and status='applied';
  end if;
  return to_jsonb(t)||jsonb_build_object('refund_payment_id',result->'refund_payment_id');
end $$;
revoke all on function private.transition_v4(jsonb) from public,anon;
grant execute on function private.transition_v4(jsonb) to authenticated;

create function private.rating_v2(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();t public.trips;stars_value integer;result jsonb;bonus integer;
begin
  select * into t from public.trips where id=(payload->>'trip_id')::uuid;
  result:=private.dispatch('rating',payload);stars_value:=(payload->>'stars')::integer;
  insert into public.reward_entries(user_id,trip_id,points,entry_type,description)
  values(uid,t.id,2,'rating_given','Evaluación completada') on conflict(user_id,trip_id,entry_type) where trip_id is not null do nothing;
  if uid=t.passenger_id and t.driver_id is not null and stars_value>=4 then
    bonus:=case when stars_value=5 then 8 else 3 end;
    insert into public.reward_entries(user_id,trip_id,points,entry_type,description,detail)
    values(t.driver_id,t.id,bonus,'rating_bonus','Bono por calificación del pasajero',jsonb_build_object('stars',stars_value)) on conflict(user_id,trip_id,entry_type) where trip_id is not null do nothing;
  end if;
  return result||jsonb_build_object('points_awarded',2,'driver_bonus',coalesce(bonus,0));
end $$;
revoke all on function private.rating_v2(jsonb) from public,anon;
grant execute on function private.rating_v2(jsonb) to authenticated;

create function private.review_reward_redemption_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();redemption public.reward_redemptions;decision text;note_value text;
begin
  if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede gestionar recompensas.' using errcode='42501';end if;
  decision:=payload->>'status';note_value:=trim(coalesce(payload->>'note',''));
  if decision not in ('fulfilled','cancelled') or length(note_value)<5 then raise exception 'Indica un resultado y una nota de revisión.';end if;
  select * into redemption from public.reward_redemptions where id=(payload->>'redemption_id')::uuid for update;
  if not found or redemption.status<>'requested' then raise exception 'El canje ya fue procesado o no requiere entrega.';end if;
  update public.reward_redemptions set status=decision,operations_note=left(note_value,500),fulfilled_at=case when decision='fulfilled' then now() else null end,fulfilled_by=uid,updated_at=now() where id=redemption.id;
  if decision='cancelled' and redemption.points_spent>0 then
    insert into public.reward_entries(user_id,trip_id,points,entry_type,description,redemption_id)
    values(redemption.user_id,null,redemption.points_spent,'redemption_refund','Devolución por canje cancelado',redemption.id) on conflict(redemption_id,entry_type) where redemption_id is not null do nothing;
  end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'reward_redemption_'||decision,redemption.id,jsonb_build_object('user_id',redemption.user_id,'reward_id',redemption.reward_id,'note',left(note_value,500)));
  return jsonb_build_object('ok',true,'status',decision);
end $$;
revoke all on function private.review_reward_redemption_v1(jsonb) from public,anon;
grant execute on function private.review_reward_redemption_v1(jsonb) to authenticated;

create function private.dashboard_v6(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;base jsonb;wallet jsonb;operations jsonb;
begin
  select * into p from public.profiles where id=uid;
  if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501';end if;
  base:=private.dashboard_v5(payload);
  if p.role in ('passenger','driver') then
    wallet:=private.reward_metrics(uid)||jsonb_build_object(
      'catalog',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order,c.points_cost),'[]') from public.reward_catalog c where c.audience=p.role),
      'redemptions',(select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at desc),'[]') from (select r.*,c.name,c.description,c.kind,c.icon,c.partner_name,c.fulfillment_note,c.value_cents,c.value_percent,c.max_discount_cents,c.eligible_category from public.reward_redemptions r join public.reward_catalog c on c.id=r.reward_id where r.user_id=uid order by r.requested_at desc limit 50)x),
      'entries',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (select id,trip_id,points,entry_type,description,created_at from public.reward_entries where user_id=uid order by created_at desc limit 50)x)
    );
  end if;
  if p.role='admin' then
    operations:=jsonb_build_object(
      'drivers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]') from (select pr.id,pr.full_name,d.approved,d.vehicle,d.plate,private.reward_metrics(pr.id) as rewards from public.profiles pr join public.drivers d on d.id=pr.id)x),
      'pending',(select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]') from (select r.*,c.name,c.description,c.kind,c.icon,c.partner_name,c.fulfillment_note,pr.full_name as driver_name,pr.phone from public.reward_redemptions r join public.reward_catalog c on c.id=r.reward_id join public.profiles pr on pr.id=r.user_id where c.audience='driver' and r.status='requested')x)
    );
  end if;
  return base||jsonb_build_object('reward_wallet',wallet,'reward_operations',operations);
end $$;
revoke all on function private.dashboard_v6(jsonb) from public,anon;
grant execute on function private.dashboard_v6(jsonb) to authenticated;

-- Create accumulated free local rides for existing passengers at each completed 15-trip milestone.
insert into public.reward_redemptions(user_id,reward_id,code,status,points_spent,source_key,expires_at)
select p.passenger_id,'passenger_free_local_15','YV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'available',0,
  'free_local:'||p.passenger_id::text||':'||milestone,now()+interval '365 days'
from (select passenger_id,count(*)::integer as completed from public.trips where status='completed' group by passenger_id)p
cross join lateral generate_series(1,p.completed/15) milestone
on conflict(source_key) do nothing;

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
