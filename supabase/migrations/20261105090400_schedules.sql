-- Persistent schedules via pg_cron (runs inside Supabase; independent of any
-- browser or Claude session). Skipped where pg_cron is unavailable (local tests).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('quantum-system-worker', '* * * * *', 'select public.run_system_tasks(10)');
    perform cron.schedule('quantum-reaper', '* * * * *', 'select public.reap_stale_tasks()');
    -- 07:00 UTC daily (08:00 BST / 07:00 GMT)
    perform cron.schedule('quantum-daily-review', '0 7 * * *', 'select public.schedule_daily_review()');
  else
    raise notice 'pg_cron not available; schedules not installed';
  end if;
end $$;
