-- Applied to production between core_foundation and rpc_and_queue: removes
-- PostgreSQL's implicit PUBLIC execute grant from the core helper functions.
revoke execute on function public.write_audit(text,text,text,text,uuid,jsonb) from public, anon, authenticated;
revoke execute on function public.limit_value(text) from public, anon, authenticated;
revoke execute on function public.emergency_stop_active() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.audit_row() from public, anon, authenticated;
revoke execute on function public.log_task_event() from public, anon, authenticated;
revoke execute on function public.forbid_ledger_mutation() from public, anon, authenticated;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
revoke execute on function public.is_owner() from public, anon;
revoke execute on function public.can_access_business(uuid) from public, anon;
revoke execute on function public.can_manage_business(uuid) from public, anon;
