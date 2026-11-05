-- Applied to production as one of several smaller migrations (see DECISIONS D9).

-- Times out stuck tasks; approval expiry lives in expire_approvals() (next migration).
create or replace function public.reap_stale_tasks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_timed_out int := 0;
begin
  for r in select id, locked_by from public.tasks
           where status = 'running' and locked_at < now() - make_interval(secs => timeout_seconds)
           for update skip locked loop
    perform public.fail_task(r.id, r.locked_by, jsonb_build_object('message', 'timed out', 'code', 'timeout'), true);
    v_timed_out := v_timed_out + 1;
  end loop;
  return jsonb_build_object('timed_out', v_timed_out, 'approvals_expired', public.expire_approvals());
end $$;
