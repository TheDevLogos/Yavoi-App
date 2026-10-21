-- The same durable queue used by the Operations composer is drained even if
-- its browser tab closes. The secret is generated inside Vault, never copied
-- into the application or migration history.
create function public.verify_yavoi_communications_worker_token(supplied_token text)
returns boolean language plpgsql security definer set search_path='' as $$
declare valid boolean:=false;
begin
  if supplied_token is null or length(supplied_token)<32 or to_regclass('vault.decrypted_secrets') is null then return false; end if;
  execute 'select exists(select 1 from vault.decrypted_secrets where name=''yavoi_communications_worker_token'' and decrypted_secret=$1)'
    into valid using supplied_token;
  return coalesce(valid,false);
end $$;
revoke all on function public.verify_yavoi_communications_worker_token(text) from public,anon,authenticated;
grant execute on function public.verify_yavoi_communications_worker_token(text) to service_role;

do $setup$
begin
  if to_regclass('vault.secrets') is null or to_regclass('cron.job') is null then return; end if;
  if not exists(select 1 from vault.secrets where name='yavoi_communications_worker_token') then
    perform vault.create_secret(encode(gen_random_bytes(32),'hex'),'yavoi_communications_worker_token','Token exclusivo para el trabajador push de Yavoi!');
  end if;
  if exists(select 1 from cron.job where jobname='yavoi-communications-every-minute') then
    perform cron.unschedule('yavoi-communications-every-minute');
  end if;
  perform cron.schedule('yavoi-communications-every-minute','* * * * *',
    $job$
      select net.http_post(
        url := 'https://asjlyureqokifjkpdwgc.supabase.co/functions/v1/push-communications',
        headers := jsonb_build_object('Content-Type','application/json','x-yavoi-communications-worker',
          (select decrypted_secret from vault.decrypted_secrets where name='yavoi_communications_worker_token')),
        body := jsonb_build_object('message_id',j.message_id),
        timeout_milliseconds := 20000
      )
      from public.communication_push_jobs j
      join public.communication_messages m on m.id=j.message_id
      where j.state in ('queued','sending') and m.ends_at>now()
      order by j.updated_at limit 10
    $job$
  );
end $setup$;
