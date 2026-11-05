-- Applied to production as one of several smaller migrations (see DECISIONS D9).

create or replace function public.claim_next_task(p_worker text, p_kind_prefix text default null)
returns setof public.tasks language plpgsql security definer set search_path = public as $$
declare v_running int; v_max int := coalesce(public.limit_value('max_concurrent_tasks'), 5);
begin
  if public.emergency_stop_active() then return; end if;
  select count(*) into v_running from public.tasks where status = 'running';
  if v_running >= v_max then return; end if;

  return query
  update public.tasks t set status = 'running', locked_by = p_worker, locked_at = now(),
         started_at = coalesce(t.started_at, now()), attempts = t.attempts + 1
  where t.id = (
    select q.id from public.tasks q
    left join public.agents a on a.id = q.agent_id
    left join public.businesses b on b.id = q.business_id
    where q.status = 'queued' and q.run_after <= now()
      and (p_kind_prefix is null or q.kind like p_kind_prefix || '%')
      and (q.agent_id is null or a.admin_state = 'enabled')
      and (q.business_id is null or b.status not in ('paused','archived'))
    order by q.priority desc, q.run_after, q.created_at
    for update of q skip locked
    limit 1)
  returning t.*;
end $$;

create or replace function public.complete_task(p_task uuid, p_worker text, p_result jsonb, p_usage jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_result is null then raise exception 'a completed task must have a result' using errcode = '22004'; end if;
  update public.tasks set status = 'completed', result = p_result, usage = coalesce(p_usage,'{}'),
    completed_at = now(), locked_by = null, error = null
  where id = p_task and status = 'running' and locked_by = p_worker;
  if not found then raise exception 'task % is not running under worker %', p_task, p_worker using errcode = '55000'; end if;
end $$;

create or replace function public.fail_task(p_task uuid, p_worker text, p_error jsonb, p_retryable boolean default true)
returns public.task_status language plpgsql security definer set search_path = public as $$
declare v public.tasks; v_next public.task_status; v_base int := coalesce(public.limit_value('retry_base_seconds'), 30);
begin
  select * into v from public.tasks where id = p_task and status = 'running' and locked_by = p_worker for update;
  if not found then raise exception 'task % is not running under worker %', p_task, p_worker using errcode = '55000'; end if;
  if p_retryable and v.attempts < v.max_attempts then
    v_next := 'queued';
    update public.tasks set status = 'queued', locked_by = null, locked_at = null,
      error = coalesce(p_error, '{}'::jsonb) || jsonb_build_object('attempt', v.attempts),
      run_after = now() + make_interval(secs => v_base * power(2, v.attempts - 1))
    where id = p_task;
  else
    v_next := 'failed';
    update public.tasks set status = 'failed', locked_by = null, completed_at = now(),
      error = coalesce(p_error, '{}'::jsonb) || jsonb_build_object('attempt', v.attempts, 'final', true)
    where id = p_task;
    insert into public.notifications(business_id, category, priority, title, body, link)
    values (v.business_id, 'task_failure', 'high', 'Task failed: ' || v.title,
            left(coalesce(p_error ->> 'message', p_error::text), 500), '#/tasks/' || v.id);
  end if;
  return v_next;
end $$;

revoke execute on function public.claim_next_task(text,text) from public, anon, authenticated;
revoke execute on function public.complete_task(uuid,text,jsonb,jsonb) from public, anon, authenticated;
revoke execute on function public.fail_task(uuid,text,jsonb,boolean) from public, anon, authenticated;
grant execute on function public.claim_next_task(text,text), public.complete_task(uuid,text,jsonb,jsonb),
  public.fail_task(uuid,text,jsonb,boolean) to service_role;
