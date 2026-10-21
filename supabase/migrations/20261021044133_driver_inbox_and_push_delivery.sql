-- Give authenticated users read-only access to their own driver inbox rows.
-- The public Inbox RPC has legacy invoker wrappers that check these tables
-- before delegating to the protected, ownership-scoped read functions.
alter table public.driver_operating_notices enable row level security;
alter table public.driver_settlement_notices enable row level security;
alter table public.driver_settlement_receipts enable row level security;
revoke all on public.driver_operating_notices, public.driver_settlement_notices, public.driver_settlement_receipts from anon, authenticated;
grant select on public.driver_operating_notices, public.driver_settlement_notices, public.driver_settlement_receipts to authenticated;

drop policy if exists driver_operating_notices_read_own on public.driver_operating_notices;
create policy driver_operating_notices_read_own on public.driver_operating_notices
  for select to authenticated using (driver_id = (select auth.uid()));
drop policy if exists driver_settlement_notices_read_own on public.driver_settlement_notices;
create policy driver_settlement_notices_read_own on public.driver_settlement_notices
  for select to authenticated using (driver_id = (select auth.uid()));
drop policy if exists driver_settlement_receipts_read_own on public.driver_settlement_receipts;
create policy driver_settlement_receipts_read_own on public.driver_settlement_receipts
  for select to authenticated using (driver_id = (select auth.uid()));

-- A push can start immediately from Operations while the minute cron remains
-- as a durable fallback. A short lease makes those two paths idempotent.
alter table public.communication_push_jobs
  add column if not exists claim_token uuid,
  add column if not exists claim_expires_at timestamptz;

create or replace function public.claim_yavoi_communications_push_job(target_message_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job public.communication_push_jobs;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'Sólo el servicio de notificaciones puede tomar un envío.' using errcode='42501';
  end if;
  update public.communication_push_jobs j
     set state='sending', claim_token=gen_random_uuid(), claim_expires_at=now()+interval '2 minutes', updated_at=now()
    from public.communication_messages m
   where j.message_id=target_message_id and m.id=j.message_id and m.ends_at>now()
     and j.state in ('queued','sending') and (j.claim_expires_at is null or j.claim_expires_at<now())
  returning j.* into job;
  if found then
    return jsonb_build_object('claimed',true,'job_id',job.id,'claim_token',job.claim_token,
      'last_profile_id',job.last_profile_id,'delivered_count',job.delivered_count,'failed_count',job.failed_count);
  end if;
  select * into job from public.communication_push_jobs where message_id=target_message_id;
  if not found then return jsonb_build_object('claimed',false,'not_found',true); end if;
  return jsonb_build_object('claimed',false,'complete',job.state='complete','processing',job.state<>'complete',
    'delivered_count',job.delivered_count,'failed_count',job.failed_count);
end $$;
revoke all on function public.claim_yavoi_communications_push_job(uuid) from public, anon, authenticated;
grant execute on function public.claim_yavoi_communications_push_job(uuid) to service_role;
