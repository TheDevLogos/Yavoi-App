-- An accepted price is evidence for the passenger, driver and weekly close.
-- Only the two controlled events below may complete that snapshot: applying a
-- reward before assignment, and assigning the driver contractual terms.
create function private.lock_quote_financial_snapshot_v1() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if old.financial_terms <> '{}'::jsonb and (
    new.fare_cents is distinct from old.fare_cents or
    new.commission_cents is distinct from old.commission_cents or
    new.zone_surcharge_cents is distinct from old.zone_surcharge_cents or
    new.booking_fee_cents is distinct from old.booking_fee_cents or
    new.accessibility_surcharge_cents is distinct from old.accessibility_surcharge_cents or
    new.pickup_surcharge_cents is distinct from old.pickup_surcharge_cents or
    new.distance_charge_cents is distinct from old.distance_charge_cents or
    new.time_charge_cents is distinct from old.time_charge_cents or
    new.minimum_adjustment_cents is distinct from old.minimum_adjustment_cents or
    new.pricing_version is distinct from old.pricing_version or
    new.financial_terms is distinct from old.financial_terms
  ) then
    raise exception 'La cotización financiera ya fue emitida y no puede modificarse.';
  end if;
  return new;
end $$;
revoke all on function private.lock_quote_financial_snapshot_v1() from public,anon,authenticated;
create trigger zz_lock_quote_financial_snapshot before update on public.quotes
for each row execute function private.lock_quote_financial_snapshot_v1();

create function private.expected_trip_financial_breakdown_v1(item public.trips) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare gross bigint; tips bigint; commission bigint; split jsonb; promotion_split jsonb;
begin
  gross:=case when item.status='cancelled' then item.cancellation_fee_cents else greatest(0,item.fare_cents-item.reward_discount_cents) end;
  tips:=case when item.status='cancelled' then 0 else item.tip_cents end;
  commission:=case when item.status='cancelled' then item.cancellation_commission_cents else item.commission_cents end;
  split:=private.finance_split(gross,tips,commission,item.payment_method='card',item.financial_terms);
  promotion_split:=private.finance_split(case when item.status='cancelled' then 0 else item.reward_discount_cents end,0,0,true,item.financial_terms);
  return split||jsonb_build_object(
    'version',item.financial_terms->>'version','fare_cents',item.fare_cents,'passenger_total_cents',gross+tips,
    'promotion_pending_cents',case when item.status='cancelled' then 0 else item.reward_discount_cents end,
    'contractual_net_cents',(split->>'net_cents')::bigint+(promotion_split->>'net_cents')::bigint,
    'state_contribution_cents',round(gross*150/10000.0),'state_payer','Yavoi!','vat_included',true,
    'cash_commission_due_cents',case when item.payment_method='cash' then commission else 0 end,
    'level',item.financial_terms->>'level'
  );
end $$;
revoke all on function private.expected_trip_financial_breakdown_v1(public.trips) from public,anon,authenticated;

create function private.lock_trip_financial_snapshot_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare reward_application boolean; driver_assignment boolean; expected jsonb;
begin
  reward_application:=old.driver_id is null and new.driver_id is null
    and old.reward_redemption_id is null and new.reward_redemption_id is not null
    and old.fare_cents=new.fare_cents and new.reward_discount_cents between 0 and new.fare_cents
    and new.total_cents=new.fare_cents-new.reward_discount_cents+new.tip_cents;
  driver_assignment:=(old.driver_id is null and new.driver_id is not null
      or old.status='scheduled' and new.status='scheduled' and old.driver_id is distinct from new.driver_id and new.driver_id is not null)
    and new.fare_cents=old.fare_cents and new.total_cents=old.total_cents
    and new.tip_cents=old.tip_cents and new.reward_discount_cents=old.reward_discount_cents
    and new.payment_method=old.payment_method and new.cash_tender_cents is not distinct from old.cash_tender_cents
    and (new.financial_terms - array['entity','rfc_provided','fiscal_locked_at','level','level_discount_bps','original_commission_bps','commission_bps'])=old.financial_terms;

  if new.quote_id is distinct from old.quote_id or new.fare_cents is distinct from old.fare_cents
    or new.pricing_version is distinct from old.pricing_version
    or new.zone_surcharge_cents is distinct from old.zone_surcharge_cents
    or new.booking_fee_cents is distinct from old.booking_fee_cents
    or new.accessibility_surcharge_cents is distinct from old.accessibility_surcharge_cents
    or new.pickup_surcharge_cents is distinct from old.pickup_surcharge_cents
    or new.distance_charge_cents is distinct from old.distance_charge_cents
    or new.time_charge_cents is distinct from old.time_charge_cents
    or new.minimum_adjustment_cents is distinct from old.minimum_adjustment_cents then
    raise exception 'La tarifa aceptada del viaje no puede modificarse.';
  end if;

  if (new.total_cents is distinct from old.total_cents or new.tip_cents is distinct from old.tip_cents
      or new.reward_discount_cents is distinct from old.reward_discount_cents
      or new.reward_redemption_id is distinct from old.reward_redemption_id
      or new.payment_method is distinct from old.payment_method
      or new.cash_tender_cents is distinct from old.cash_tender_cents) and not reward_application then
    raise exception 'El total, propina, recompensa y método de pago quedan fijados al solicitar el viaje.';
  end if;

  if old.driver_id is not null and new.driver_id is distinct from old.driver_id and old.status<>'scheduled' then
    raise exception 'El conductor asignado no puede sustituirse sin cancelar el viaje.';
  end if;
  if (old.financial_terms <> '{}'::jsonb or new.financial_terms <> '{}'::jsonb) and (new.commission_cents is distinct from old.commission_cents
    or new.commission_bps_applied is distinct from old.commission_bps_applied
    or new.billing_mode is distinct from old.billing_mode
    or new.financial_terms is distinct from old.financial_terms) then
    if not driver_assignment then
      raise exception 'Las condiciones comerciales se fijan al aceptar el conductor.';
    end if;
  end if;

  if new.driver_id is not null and new.financial_terms <> '{}'::jsonb then
    expected:=private.expected_trip_financial_breakdown_v1(new);
    if new.financial_breakdown is distinct from expected then
      raise exception 'El desglose financiero no coincide con el viaje registrado.';
    end if;
  end if;
  return new;
end $$;
revoke all on function private.lock_trip_financial_snapshot_v1() from public,anon,authenticated;
create trigger zz_lock_trip_financial_snapshot before update on public.trips
for each row execute function private.lock_trip_financial_snapshot_v1();

-- A reserved driver receives the contractual rate at reservation time. When
-- its scheduled service opens, activate the trip without recalculating that
-- rate from a newer contract. The legacy branch remains only for records that
-- predate the financial snapshot.
create or replace function private.release_scheduled_trips_v1() returns void
language plpgsql security definer set search_path='' as $$
declare waiting record;
begin
  update public.trips t set driver_id=null,updated_at=now()
  where t.status='scheduled' and t.driver_id is not null and t.scheduled_at<=now()+interval '15 minutes'
    and (
      not exists(
        select 1 from public.drivers d join public.profiles p on p.id=d.id
        where d.id=t.driver_id and p.role='driver' and not p.suspended and d.approved and d.account_active
          and d.license_expires>=current_date and d.insurance_expires>=current_date
          and private.driver_can_cover_category_v1(d.category,t.category)
          and (not t.women_only or d.female_verified) and (not t.accessible or d.accessible_verified)
      )
      or exists(select 1 from public.trips busy where busy.driver_id=t.driver_id and busy.id<>t.id and busy.status in ('accepted','arrived','in_progress'))
    );

  for waiting in
    select t.id,d.id as driver_id,d.billing_mode,private.driver_commission_bps(d.id,t.payment_method) as commission_bps,t.financial_terms
    from public.trips t join public.drivers d on d.id=t.driver_id
    where t.status='scheduled' and t.scheduled_at<=now()+interval '15 minutes'
      and (t.payment_method='cash' or t.payment_status='paid')
    for update of t
  loop
    if waiting.financial_terms <> '{}'::jsonb then
      update public.trips set status='accepted',updated_at=now() where id=waiting.id;
    else
      update public.trips set status='accepted',billing_mode=waiting.billing_mode,
        commission_bps_applied=waiting.commission_bps,
        commission_cents=round(fare_cents*waiting.commission_bps/10000.0)::integer,updated_at=now()
      where id=waiting.id;
    end if;
    insert into public.trip_events(trip_id,actor_id,event,detail)
    values(waiting.id,waiting.driver_id,'accepted',jsonb_build_object(
      'scheduled_activation',true,'billing_mode',waiting.billing_mode,'commission_bps',waiting.commission_bps,
      'financial_snapshot_locked',waiting.financial_terms <> '{}'::jsonb
    ));
  end loop;

  update public.trips set status='requested',updated_at=now()
  where status='scheduled' and driver_id is null and scheduled_at<=now()+interval '15 minutes'
    and (payment_method='cash' or payment_status='paid');
  for waiting in select id,preferred_driver_id from public.trips where driver_id is null and status='requested' order by created_at limit 25 loop
    perform private.auto_assign_trip(waiting.id,waiting.preferred_driver_id);
  end loop;
end $$;
revoke all on function private.release_scheduled_trips_v1() from public,anon,authenticated;
