-- A request made early Monday belongs to that day's free payout window.
create function private.finance_weekly_due(moment timestamptz default now()) returns timestamptz
language sql stable set search_path='' as $$
 with clock as (select timezone('America/Chihuahua',moment) local_time)
 select (date_trunc('week',local_time)::date +
   case when extract(isodow from local_time)=1 then 0 else 7 end + time '07:00')
   at time zone 'America/Chihuahua' from clock
$$;
revoke all on function private.finance_weekly_due(timestamptz) from public,anon,authenticated;
do $patch$ declare original text; revised text; begin
 original:=pg_get_functiondef('private.finance_withdraw_internal(uuid,text,bigint,uuid)'::regprocedure);
 revised:=replace(original,
 $$due:=(date_trunc('week',local_time)+time '07:00') at time zone 'America/Chihuahua';
 if local_time::date<>date_trunc('week',local_time)::date or local_time::time<time '07:00' then due:=due+interval '7 days'; end if;$$,
 'due:=private.finance_weekly_due();');
 if revised=original then raise exception 'No se encontró la regla semanal esperada.'; end if;
 execute revised;
 original:=pg_get_functiondef('private.finance_wallet_data(uuid,date)'::regprocedure);
 revised:=replace(original,
 $$((date_trunc('week',timezone('America/Chihuahua',now()))::date+7)+time '07:00') at time zone 'America/Chihuahua'$$,
 'private.finance_weekly_due()');
 if revised=original then raise exception 'No se encontró la fecha semanal esperada.'; end if;
 execute revised;
end $patch$;

-- Refund a post-trip tip and its ISR with separate, reversible tax entries.
do $patch$ declare original text; revised text; begin
 original:=pg_get_functiondef('private.finance_payment_journal_trigger()'::regprocedure);
 revised:=replace(original,
 $$select coalesce(sum(amount_cents),0) into gross from public.driver_wallet_entries where entry_key like k||':%';
 perform private.finance_post(t.driver_id,t.id,new.id,k||':refund','refund',-gross);$$,
 $$for s in select to_jsonb(e) from public.driver_wallet_entries e where e.entry_key like k||':%' and e.kind in ('card_tip','isr') loop
 perform private.finance_post(t.driver_id,t.id,new.id,'tip-refund:'||(s->>'id'),'refund',-(s->>'amount_cents')::bigint,jsonb_build_object('reverses',s->>'id','reversed_kind',s->>'kind'));
 end loop;$$);
 if revised=original then raise exception 'No se encontró la devolución de propina esperada.'; end if;
 execute revised;
end $patch$;
