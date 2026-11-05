-- Applied to production as one of several smaller migrations (see DECISIONS D9).

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
