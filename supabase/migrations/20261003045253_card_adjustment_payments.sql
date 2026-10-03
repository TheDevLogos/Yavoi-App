-- A post-acceptance card amount is never added to a completed ride until the
-- passenger has separately authorized it with Mercado Pago.
alter table public.payments drop constraint payments_kind_check;
alter table public.payments add constraint payments_kind_check
  check(kind in ('ride','tip','weekly_fee','cancellation_fee','trip_adjustment'));
alter table public.payments drop constraint payments_check1;
alter table public.payments add constraint payments_check1
  check((kind in ('ride','tip','cancellation_fee','trip_adjustment') and trip_id is not null) or kind='weekly_fee');
alter table public.ledger drop constraint ledger_kind_check;
alter table public.ledger add constraint ledger_kind_check
  check(kind in ('fare','commission','cash_tip','card_tip','cancellation_fee','fare_adjustment','commission_adjustment'));

create index payments_trip_adjustment_pending on public.payments(trip_id,created_at)
  where kind='trip_adjustment' and status in ('created','pending','in_process');

create function private.create_trip_adjustment_payment_v1(target uuid, amount integer, source_value text)
returns uuid language plpgsql security definer set search_path='' as $$
declare t public.trips; payment_id uuid;
begin
  if amount<1 then return null; end if;
  select * into t from public.trips where id=target for update;
  if not found or t.payment_method<>'card' or t.status not in ('arrived','in_progress') then return null; end if;
  insert into public.payments(trip_id,payer_id,driver_id,kind,provider,amount_cents,status,status_detail)
  values(t.id,t.passenger_id,t.driver_id,'trip_adjustment','mercado_pago',amount,'created',source_value)
  returning id into payment_id;
  insert into public.trip_events(trip_id,actor_id,event,detail)
  values(t.id,null,'trip_adjustment_payment_created',jsonb_build_object('payment_id',payment_id,'amount_cents',amount,'source',source_value));
  return payment_id;
end $$;
revoke all on function private.create_trip_adjustment_payment_v1(uuid,integer,text) from public,anon,authenticated;

-- Add the fixed wait charge as a distinct, auditable payment when boarding
-- starts.  The before trigger has already frozen charged_cents at this point.
create or replace function private.manage_trip_wait_charge_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare rate_value integer; frozen_cents integer;
begin
  if new.status='arrived' and old.status='accepted' then
    select c.minute_cents into rate_value from public.categories c where c.id=new.category;
    insert into public.trip_wait_charges(trip_id,arrived_at,free_until,rate_cents_per_minute)
    values(new.id,now(),now()+interval '2 minutes',coalesce(rate_value,1)) on conflict(trip_id) do nothing;
    insert into public.trip_events(trip_id,actor_id,event,detail)
    values(new.id,new.driver_id,'waiting_started',jsonb_build_object('free_seconds',120,'rate_cents_per_minute',coalesce(rate_value,1)));
  elsif new.status='in_progress' and old.status='arrived' then
    update public.trip_wait_charges as waiting set status='stopped',stopped_at=now(),
      charged_cents=private.trip_wait_charge_cents_v1(waiting,now())
    where waiting.trip_id=new.id and waiting.status='running' returning charged_cents into frozen_cents;
    insert into public.trip_events(trip_id,actor_id,event,detail)
    select new.id,new.driver_id,'waiting_stopped',jsonb_build_object('charged_cents',charged_cents,'stopped_at',stopped_at)
    from public.trip_wait_charges where trip_id=new.id;
    if new.payment_method='card' and coalesce(frozen_cents,0)>0 then
      perform private.create_trip_adjustment_payment_v1(new.id,frozen_cents,'waiting');
    end if;
  end if;
  return new;
end $$;

create or replace function private.trip_fare_adjustment_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.trips; adjustment public.trip_fare_adjustments; action_value text:=payload->>'action'; reason_value text:=payload->>'reason'; amount integer:=coalesce((payload->>'amount_cents')::integer,0); decision text:=payload->>'decision';
begin
 select * into t from public.trips where id=(payload->>'trip_id')::uuid for update;
 if not found or auth.uid() not in (t.passenger_id,t.driver_id) or t.status not in ('accepted','arrived','in_progress') then raise exception 'El ajuste sólo puede solicitarse por las personas de un viaje activo.'; end if;
 if action_value='propose' then
   if reason_value not in ('detour','route_change','extra_pickup') or amount<1 or amount>100000 then raise exception 'Selecciona motivo e importe válidos.'; end if;
   insert into public.trip_fare_adjustments(trip_id,proposed_by,reason,amount_cents) values(t.id,auth.uid(),reason_value,amount) returning * into adjustment;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'fare_adjustment_proposed',jsonb_build_object('adjustment_id',adjustment.id,'reason',reason_value,'amount_cents',amount));
 elsif action_value='decide' then
   select * into adjustment from public.trip_fare_adjustments where id=(payload->>'adjustment_id')::uuid and trip_id=t.id for update;
   if not found or adjustment.status<>'pending' or adjustment.proposed_by=auth.uid() or decision not in ('accepted','declined') then raise exception 'No puedes resolver este ajuste.'; end if;
   update public.trip_fare_adjustments set status=decision,decided_by=auth.uid(),decided_at=now() where id=adjustment.id returning * into adjustment;
   if decision='accepted' then
     update public.trips set financial_breakdown=private.expected_trip_financial_breakdown_v1(public.trips),updated_at=now() where id=t.id;
     if t.payment_method='card' then perform private.create_trip_adjustment_payment_v1(t.id,adjustment.amount_cents,adjustment.reason); end if;
   end if;
   insert into public.trip_events(trip_id,actor_id,event,detail) values(t.id,auth.uid(),'fare_adjustment_'||decision,jsonb_build_object('adjustment_id',adjustment.id,'reason',adjustment.reason,'amount_cents',adjustment.amount_cents));
 else raise exception 'Acción de ajuste inválida.'; end if;
 return to_jsonb(adjustment);
end $$;

create or replace function private.payment_checkout_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();p public.profiles;pay public.payments;email_value text;
begin
 select * into p from public.profiles where id=uid;
 if uid is null or not found or p.suspended then raise exception 'Inicia sesión para continuar.' using errcode='42501'; end if;
 select * into pay from public.payments where id=(payload->>'payment_id')::uuid for update;
 if not found or pay.payer_id<>uid or pay.provider<>'mercado_pago' or pay.status not in ('created','pending','in_process')
   or (pay.kind='ride' and not exists(select 1 from public.trips where id=pay.trip_id and status='payment_pending'))
   or (pay.kind='trip_adjustment' and not exists(select 1 from public.trips where id=pay.trip_id and status in ('arrived','in_progress'))) then raise exception 'Pago no disponible.'; end if;
 select email into email_value from auth.users where id=uid;
 return jsonb_build_object('payment_id',pay.id,'amount_cents',pay.amount_cents,'currency',pay.currency,'idempotency_key',pay.idempotency_key,'kind',pay.kind,'trip_id',pay.trip_id,'payer_email',email_value,'description',case pay.kind when 'ride' then 'Viaje Yavoi!' when 'tip' then 'Propina Yavoi!' when 'trip_adjustment' then 'Ajuste de viaje Yavoi!' else 'Cuota semanal Yavoi!' end);
end $$;

create or replace function private.transition_v11(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid:=(payload->>'trip_id')::uuid; outstanding integer;
begin
 if payload->>'status'='completed' then
   select count(*) into outstanding from public.payments
   where trip_id=target and kind='trip_adjustment' and status<>'approved';
   if outstanding>0 then raise exception 'Hay un ajuste de tarjeta pendiente de autorización del pasajero.'; end if;
 end if;
 return private.transition_v10(payload);
end $$;
revoke all on function private.transition_v11(jsonb) from public,anon;
grant execute on function private.transition_v11(jsonb) to authenticated;

create or replace function private.finance_reconcile_trip(target uuid) returns void language plpgsql security definer set search_path='' as $$
declare t public.trips; p public.payments; s jsonb; gross bigint; tips bigint; fee bigint; key_value text; cancelled boolean; additions integer; paid_adjustments integer;
begin
 select * into t from public.trips where id=target;
 if not found or t.driver_id is null or t.financial_terms='{}' or t.status not in ('completed','cancelled') then return; end if;
 perform 1 from public.drivers where id=t.driver_id for update;
 cancelled:=t.status='cancelled'; if cancelled and t.cancellation_fee_cents=0 then return; end if;
 additions:=case when cancelled then 0 else private.trip_post_acceptance_adjustments_cents_v1(t.id) end;
 if t.payment_method='cash' then
   if cancelled and not exists(select 1 from public.payments where trip_id=t.id and kind='cancellation_fee' and status='approved') then return; end if;
   fee:=case when cancelled then t.cancellation_commission_cents else t.commission_cents+round(additions*coalesce(t.commission_bps_applied,0)/10000.0)::integer end;
   perform private.finance_post(t.driver_id,t.id,null,'trip:'||t.id||':cash-commission','cash_commission',-fee,jsonb_build_object('post_acceptance_adjustments_cents',additions));
   return;
 end if;
 select * into p from public.payments where trip_id=t.id and kind='ride' and provider='mercado_pago';
 if not found then return; end if;
 key_value:='trip:'||t.id;
 if p.status='refunded' and not cancelled then
   for s in select to_jsonb(e) from public.driver_wallet_entries e where e.trip_id=t.id and e.entry_key like key_value||':%' and e.kind not in ('refund','promotion_credit') loop
     perform private.finance_post(t.driver_id,t.id,p.id,'refund:'||(s->>'id'),'refund',-(s->>'amount_cents')::bigint,jsonb_build_object('reverses',s->>'id','reversed_kind',s->>'kind'));
   end loop; return;
 end if;
 if (not cancelled and p.status<>'approved') or (cancelled and p.status not in ('approved','refunded')) then return; end if;
 select coalesce(sum(amount_cents),0)::integer into paid_adjustments from public.payments where trip_id=t.id and kind='trip_adjustment' and status='approved';
 if not cancelled and paid_adjustments<>additions then raise exception 'Los ajustes cobrados no coinciden con el detalle final del viaje.'; end if;
 gross:=case when cancelled then least(t.cancellation_fee_cents,p.retained_amount_cents) else greatest(0,t.fare_cents-t.reward_discount_cents)+additions end;
 tips:=case when cancelled then 0 else t.tip_cents end;
 fee:=case when cancelled then t.cancellation_commission_cents else t.commission_cents+round(additions*coalesce(t.commission_bps_applied,0)/10000.0)::integer end;
 if cancelled and gross=0 then return; end if;
 s:=private.finance_split(gross,tips,fee,true,t.financial_terms)||jsonb_build_object('collected_at',p.provider_approved_at,'post_acceptance_adjustments_cents',additions);
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':credit','card_credit',gross+tips,jsonb_build_object('collected_at',p.provider_approved_at));
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':commission','commission',-fee);
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':isr','isr',-(s->>'isr_withheld_cents')::bigint,s);
 perform private.finance_post(t.driver_id,t.id,p.id,key_value||':iva','vat',-(s->>'vat_withheld_cents')::bigint,s);
end $$;

alter function public.yavoi(text,jsonb) rename to yavoi_before_card_adjustments;
create function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$ begin
 if command='transition' then return private.transition_v11(payload); end if;
 return public.yavoi_before_card_adjustments(command,payload);
end $$;
revoke all on function public.yavoi(text,jsonb) from public,anon;
grant execute on function public.yavoi(text,jsonb) to authenticated;
