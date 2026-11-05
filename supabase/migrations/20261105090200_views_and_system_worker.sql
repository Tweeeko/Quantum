-- Reporting views (security_invoker => caller's RLS applies) and the
-- deterministic in-database worker for `system.*` tasks.

-- ---------------------------------------------------------------------------
-- Agent runtime status: DERIVED from tasks. Never stored.
-- ---------------------------------------------------------------------------
create view public.agent_status with (security_invoker = true) as
select a.*,
  case
    when a.admin_state = 'disabled' then 'disabled'
    when a.admin_state = 'paused' then 'paused'
    when exists (select 1 from public.tasks t where t.agent_id = a.id and t.status = 'running') then 'working'
    when exists (select 1 from public.tasks t where t.agent_id = a.id and t.status = 'awaiting_approval') then 'awaiting_approval'
    when exists (select 1 from public.tasks t where t.agent_id = a.id and t.status = 'queued') then 'queued'
    else coalesce((select case t.status when 'failed' then 'failed' when 'completed' then 'completed' end
                   from public.tasks t where t.agent_id = a.id and t.status in ('completed','failed')
                   order by t.completed_at desc nulls last limit 1), 'idle')
  end as runtime_status,
  (select count(*) from public.tasks t where t.agent_id = a.id and t.status = 'completed') as tasks_completed,
  (select count(*) from public.tasks t where t.agent_id = a.id and t.status = 'failed') as tasks_failed,
  (select max(t.completed_at) from public.tasks t where t.agent_id = a.id) as last_activity_at
from public.agents a;

-- ---------------------------------------------------------------------------
-- Financials: only settled, non-test ledger entries count as actuals.
-- Pending is shown separately. Amounts in minor units per currency.
-- ---------------------------------------------------------------------------
create view public.business_financials with (security_invoker = true) as
with e as (
  select business_id, currency, entry_type, amount_minor, payment_status
  from public.ledger_entries where not is_test
)
select b.id as business_id, b.name, coalesce(x.currency, 'GBP') as currency,
  coalesce(x.gross_revenue, 0)  as gross_revenue_minor,
  coalesce(x.refunds, 0)        as refunds_minor,
  coalesce(x.gross_revenue, 0) - coalesce(x.refunds, 0) as net_revenue_minor,
  coalesce(x.payment_fees, 0)   as payment_fees_minor,
  coalesce(x.operating_expenses, 0) as operating_expenses_minor,
  coalesce(x.adjustments, 0)    as adjustments_minor,
  coalesce(x.gross_revenue, 0) - coalesce(x.refunds, 0) - coalesce(x.payment_fees, 0)
    - coalesce(x.operating_expenses, 0) + coalesce(x.adjustments, 0) as operating_profit_minor,
  coalesce(x.pending, 0)        as pending_minor,
  coalesce(x.settled_entries, 0) as settled_entries
from public.businesses b
left join (
  select business_id, currency,
    sum(amount_minor) filter (where payment_status = 'settled' and entry_type = 'revenue') as gross_revenue,
    sum(amount_minor) filter (where payment_status = 'settled' and entry_type = 'refund') as refunds,
    sum(amount_minor) filter (where payment_status = 'settled' and entry_type = 'payment_fee') as payment_fees,
    sum(amount_minor) filter (where payment_status = 'settled' and entry_type in ('expense','software_cost','advertising_cost')) as operating_expenses,
    sum(amount_minor) filter (where payment_status = 'settled' and entry_type = 'adjustment') as adjustments,
    sum(amount_minor) filter (where payment_status = 'pending' and entry_type = 'revenue') as pending,
    count(*) filter (where payment_status = 'settled') as settled_entries
  from e group by business_id, currency
) x on x.business_id = b.id;
-- Note: tax entries are recorded but not netted into operating profit; cash
-- balance is NOT derivable from this view (profit != cash).

-- ---------------------------------------------------------------------------
-- Portfolio overview for the command centre (one call, RLS-scoped).
-- ---------------------------------------------------------------------------
create or replace function public.portfolio_overview() returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'businesses', (select jsonb_build_object(
        'total', count(*) filter (where status <> 'archived'),
        'active', count(*) filter (where status = 'active'),
        'developing', count(*) filter (where status in ('proposed','developing')),
        'paused', count(*) filter (where status = 'paused')) from public.businesses),
    'finance_gbp', (select jsonb_build_object(
        'gross_revenue_minor', coalesce(sum(gross_revenue_minor),0),
        'net_revenue_minor', coalesce(sum(net_revenue_minor),0),
        'expenses_minor', coalesce(sum(operating_expenses_minor + payment_fees_minor),0),
        'operating_profit_minor', coalesce(sum(operating_profit_minor),0),
        'pending_minor', coalesce(sum(pending_minor),0),
        'settled_entries', coalesce(sum(settled_entries),0))
      from public.business_financials where currency = 'GBP'),
    'agents', (select jsonb_build_object(
        'total', count(*),
        'active', count(*) filter (where admin_state = 'enabled'),
        'working', count(*) filter (where runtime_status = 'working')) from public.agent_status),
    'tasks', (select jsonb_build_object(
        'queued', count(*) filter (where status = 'queued'),
        'running', count(*) filter (where status = 'running'),
        'awaiting_approval', count(*) filter (where status = 'awaiting_approval'),
        'failed_7d', count(*) filter (where status = 'failed' and completed_at > now() - interval '7 days'),
        'completed_7d', count(*) filter (where status = 'completed' and completed_at > now() - interval '7 days'))
      from public.tasks),
    'approvals_pending', (select count(*) from public.approvals where status = 'pending'),
    'notifications_unread', (select count(*) from public.notifications where read_at is null),
    'recent_orders', (select coalesce(jsonb_agg(o order by o.created_at desc), '[]') from (
        select id, business_id, status, payment_status, total_minor, currency, created_at
        from public.orders where not is_test order by created_at desc limit 5) o),
    'controls', (select jsonb_object_agg(key, value) from public.system_controls where key in ('emergency_stop','ai_inference','limits')),
    'generated_at', now());
$$;
revoke all on function public.portfolio_overview() from public, anon;
grant execute on function public.portfolio_overview() to authenticated;
grant select on public.agent_status, public.business_financials to authenticated;

-- ---------------------------------------------------------------------------
-- Deterministic system worker. Runs inside Postgres via pg_cron, so it needs
-- no external service and no AI inference. Handles only `system.*` kinds.
-- AI kinds stay queued until an inference worker exists (Phase 5).
-- ---------------------------------------------------------------------------
create or replace function public.execute_system_task(t public.tasks) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  case t.kind
  when 'system.daily_review' then
    select jsonb_build_object(
      'failed_last_24h', (select count(*) from public.tasks where status = 'failed' and completed_at > now() - interval '24 hours'),
      'pending_approvals', (select count(*) from public.approvals where status = 'pending'),
      'queued_tasks', (select count(*) from public.tasks where status = 'queued'),
      'orders_last_24h', (select count(*) from public.orders where not is_test and created_at > now() - interval '24 hours'),
      'settled_revenue_last_24h_minor', (select coalesce(sum(amount_minor),0) from public.ledger_entries
           where not is_test and entry_type = 'revenue' and payment_status = 'settled' and occurred_at > now() - interval '24 hours'),
      'ai_inference', (select value ->> 'status' from public.system_controls where key = 'ai_inference'),
      'reviewed_at', now()) into v;
    insert into public.notifications(category, priority, title, body, link)
    values ('daily_review', case when (v->>'failed_last_24h')::int > 0 then 'high' else 'low' end,
      'Daily review',
      format('%s failed task(s) in 24h, %s pending approval(s), %s queued, %s new order(s).',
             v->>'failed_last_24h', v->>'pending_approvals', v->>'queued_tasks', v->>'orders_last_24h'),
      '#/tasks/' || t.id);
    return v;
  when 'system.healthcheck' then
    return jsonb_build_object('ok', true, 'db_time', now());
  else
    raise exception 'unknown system task kind %', t.kind using errcode = '22023';
  end case;
end $$;

create or replace function public.run_system_tasks(p_max integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.tasks; n_ok int := 0; n_fail int := 0; v_result jsonb;
  v_worker text := 'pg-system-worker';
begin
  for i in 1..p_max loop
    select * into t from public.claim_next_task(v_worker, 'system.');
    exit when t.id is null;
    begin
      v_result := public.execute_system_task(t);
      perform public.complete_task(t.id, v_worker, v_result, '{"inference": "none"}');
      n_ok := n_ok + 1;
    exception when others then
      perform public.fail_task(t.id, v_worker, jsonb_build_object('message', sqlerrm, 'code', sqlstate), sqlstate <> '22023');
      n_fail := n_fail + 1;
    end;
  end loop;
  return jsonb_build_object('completed', n_ok, 'failed', n_fail);
end $$;

create or replace function public.schedule_daily_review() returns uuid
language plpgsql security definer set search_path = public as $$
begin
  -- Idempotent per day.
  if exists (select 1 from public.tasks where kind = 'system.daily_review' and created_at::date = now()::date) then
    return null;
  end if;
  return public.enqueue_task(null, null, 'system.daily_review', 'Daily portfolio review',
    'Scheduled deterministic review of tasks, approvals, orders and revenue.', '{}', 60::smallint);
end $$;

revoke all on function public.execute_system_task(public.tasks), public.run_system_tasks(integer),
  public.schedule_daily_review() from public, anon, authenticated;
grant execute on function public.run_system_tasks(integer), public.schedule_daily_review() to service_role;
