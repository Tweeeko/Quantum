-- Applied to production as one of several smaller migrations (see DECISIONS D9).

-- Expired approvals cancel their task: silence is never treated as approval.
create or replace function public.expire_approvals() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id, task_id from public.approvals where status = 'pending' and expires_at < now() loop
    update public.approvals set status = 'expired', decided_at = now(), decision_note = 'no decision before expiry'
    where id = r.id and status = 'pending';
    update public.tasks set status = 'cancelled', completed_at = now(),
      error = jsonb_build_object('message', 'approval window ended without a decision')
    where id = r.task_id and status = 'awaiting_approval';
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.expire_approvals() from public, anon, authenticated;
revoke execute on function public.reap_stale_tasks() from public, anon, authenticated;
grant execute on function public.reap_stale_tasks() to service_role;
