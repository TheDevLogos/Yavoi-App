-- The Chihuahua transport contribution is provisioned from every completed
-- trip's locked financial breakdown, including cash trips. Saved closures
-- remain historical snapshots; this affects live reports and new revisions.
alter function private.finance_report_v1(jsonb) rename to finance_report_before_state_contribution_v2;

create function private.finance_report_v1(payload jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; a timestamptz; b timestamptz; target uuid:=nullif(payload->>'driver_id','')::uuid;
  state_total bigint; prior_state bigint; prior_result bigint;
begin
  result:=private.finance_report_before_state_contribution_v2(payload);
  a:=((result->'meta'->>'starts_on')::date::timestamp at time zone 'America/Chihuahua');
  b:=((result->'meta'->>'ends_on')::date::timestamp at time zone 'America/Chihuahua');
  select coalesce(sum(coalesce(
    nullif(t.financial_breakdown->>'state_contribution_cents','')::bigint,
    round(greatest(0,coalesce(t.total_cents,t.fare_cents,0)-coalesce(t.tip_cents,0))*150/10000.0)::bigint
  )),0) into state_total
  from public.trips t
  where t.status='completed' and t.completed_at>=a and t.completed_at<b
    and t.payment_status is distinct from 'refunded'
    and (target is null or t.driver_id=target);
  prior_state:=coalesce((result->'summary'->>'state_contribution_cents')::bigint,0);
  prior_result:=coalesce((result->'summary'->>'operating_result_cents')::bigint,0);
  result:=jsonb_set(result,'{summary,state_contribution_cents}',to_jsonb(state_total),true);
  return jsonb_set(result,'{summary,operating_result_cents}',to_jsonb(prior_result+prior_state-state_total),true);
end $$;
revoke all on function private.finance_report_v1(jsonb) from public,anon;
grant execute on function private.finance_report_v1(jsonb) to authenticated;
