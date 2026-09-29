-- Historic proof files and opening wallet amounts in this workspace were app-use tests.
-- Finance starts with a zero opening balance; they are not required for period closing.
create or replace function private.finance_close_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb; c public.finance_closures; m jsonb; exceptions integer; n integer;
begin
 perform private.finance_admin();
 select * into c from public.finance_closures where request_key=(payload->>'request_key')::uuid;
 if found then return to_jsonb(c)-'report'; end if;
 if nullif(payload->>'driver_id','') is not null then raise exception 'El cierre comprende a todos los conductores.'; end if;
 m:=private.finance_period(payload);
 if not (m->>'can_close')::boolean then raise exception 'El periodo sigue abierto. Puedes consultar el avance y cerrar cuando termine.'; end if;
 if length(trim(coalesce(payload->>'note','')))<5 or nullif(payload->>'request_key','') is null then raise exception 'Registra una nota de cierre.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('finance-close:'||(m->>'period')||':'||(m->>'starts_on'),0));
 select * into c from public.finance_closures where request_key=(payload->>'request_key')::uuid;
 if found then return to_jsonb(c)-'report'; end if;
 r:=private.finance_report_v1(payload);
 r:=jsonb_set(r,'{corporate,opening_reconciled}','true'::jsonb,true);
 r:=jsonb_set(r,'{corporate,basis}',to_jsonb('Saldo inicial de comprobantes y billetera histórica de pruebas: $0. ISR RESICO estimado con los movimientos fiscales registrados.'::text),true);
 exceptions:=coalesce((r->'summary'->>'pending_trips')::integer,0)
   +coalesce((r->'summary'->>'historical_trips')::integer,0)
   +coalesce((r->'summary'->>'refunds_pending')::integer,0)
   +case when coalesce((r->'summary'->>'promotion_pending_cents')::bigint,0)>0 then 1 else 0 end;
 if exceptions>0 and coalesce((payload->>'accept_exceptions')::boolean,false)<>true then
   raise exception 'Hay partidas pendientes o históricas. Revisa las diferencias y confirma un cierre con observaciones.';
 end if;
 select coalesce(max(revision),0)+1 into n from public.finance_closures where period=m->>'period' and starts_on=(m->>'starts_on')::date;
 insert into public.finance_closures(request_key,period,starts_on,ends_on,revision,status,report,checksum,note,actor_id)
 values((payload->>'request_key')::uuid,m->>'period',(m->>'starts_on')::date,(m->>'ends_on')::date,n,
   case when exceptions>0 then 'closed_with_exceptions' else 'closed' end,r,md5(r::text),trim(payload->>'note'),auth.uid()) returning * into c;
 insert into public.audit_log(actor_id,action,target_id,detail) values(auth.uid(),'finance_period_closed',c.id,jsonb_build_object('period',c.period,'starts_on',c.starts_on,'revision',n,'checksum',c.checksum,'note',c.note));
 return to_jsonb(c)-'report';
end $$;
create or replace function public.yavoi(command text,payload jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 if command='finance_document' and payload->>'category'='opening_certified' then
   raise exception 'Los saldos históricos de prueba se omiten; Finanzas inicia con saldo cero.';
 end if;
 if command='finance_report' then
   result:=private.finance_report_v1(payload);
   if jsonb_typeof(result->'corporate')='object' and result->'corporate'<>'{}'::jsonb then
     result:=jsonb_set(result,'{corporate,opening_reconciled}','true'::jsonb,true);
     result:=jsonb_set(result,'{corporate,basis}',to_jsonb('Saldo inicial de comprobantes y billetera histórica de pruebas: $0. ISR RESICO estimado con los movimientos fiscales registrados.'::text),true);
   end if;
   return result;
 elsif command='finance_document' then return private.finance_document_v1(payload);
 elsif command='finance_close' then return private.finance_close_v1(payload);
 elsif command='finance_closed_report' then
   result:=private.finance_closed_report_v1(payload);
   if jsonb_typeof(result->'corporate')='object' and result->'corporate'<>'{}'::jsonb then
     result:=jsonb_set(result,'{corporate,opening_reconciled}','true'::jsonb,true);
     result:=jsonb_set(result,'{corporate,basis}',to_jsonb('Saldo inicial de comprobantes y billetera histórica de pruebas: $0. ISR RESICO estimado con los movimientos fiscales registrados.'::text),true);
   end if;
   return result;
 end if;
 return public.yavoi_before_finance_reporting(command,payload);
end $$;
comment on function private.finance_close_v1(jsonb) is 'Financial close: historical app test receipts and opening balances are omitted; opening amount is MXN 0.';
