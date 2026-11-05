-- Supabase grants new public objects to anon/authenticated by default, and
-- PostgreSQL grants EXECUTE on new functions to PUBLIC. Quantum has no
-- anonymous surface at all. Explicit statements only (reviewable; see D9).
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on sequences from anon;
-- Future functions are not executable by clients unless granted explicitly.
alter default privileges in schema public revoke execute on functions from authenticated, public;

-- Functions created in views_and_system_worker:
revoke execute on function public.portfolio_overview() from public, anon;
revoke execute on function public.execute_system_task(public.tasks) from public, anon, authenticated;
revoke execute on function public.run_system_tasks(integer) from public, anon, authenticated;
revoke execute on function public.schedule_daily_review() from public, anon, authenticated;
