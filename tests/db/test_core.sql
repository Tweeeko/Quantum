-- Quantum database tests. Run as the `authenticator` login role (like
-- PostgREST) by tests/db/run.ts. Any failed assertion raises and aborts.
\set ON_ERROR_STOP 1
\set QUIET 1

-- Role switching: psql variables from helpers.sql (:as_owner, :as_manager,
-- :as_stranger, :as_service, :as_anon, :as_admin). Assertions: t.ok, t.raises.
\i helpers.sql

-- ======================= Fixtures =======================
:as_admin
insert into public.system_controls(key, value) values ('owner_email', '"owner@example.test"');
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test'),
  ('00000000-0000-0000-0000-00000000000b', 'stranger@example.test'),
  ('00000000-0000-0000-0000-00000000000c', 'manager@example.test');

select t.ok((select count(*) = 1 from public.portfolio_owners), 'only the configured owner email becomes portfolio owner');
select t.ok(exists(select 1 from public.portfolio_owners where user_id = '00000000-0000-0000-0000-00000000000a'), 'owner bootstrapped');

-- ======================= Business Factory =======================
:as_owner
select public.create_business('Alpha Ltd', 'alpha', 'physical_product', 'First', 'hardware') as alpha \gset
select public.create_business('Beta Co', 'beta', 'digital_products') as beta \gset
select t.ok((select count(*) = 2 from public.businesses), 'owner sees both businesses');
select t.ok((select count(*) > 5 from public.business_modules where business_id = :'alpha'), 'template modules enabled');
select t.ok((select status = 'proposed' from public.businesses where id = :'alpha'), 'new business starts as proposed, not launched');
select t.raises($$select public.create_business('X', 'x', 'no_such_template')$$, 'unknown template rejected', '22023');
select t.raises($$select public.create_business('Bad', 'Bad Slug!', 'custom')$$, 'invalid slug rejected', '23514');

-- Owner grants manager access to beta only (direct insert as admin, RPC comes in a later phase)
:as_admin
insert into public.business_members(business_id, user_id, role) values (:'beta', '00000000-0000-0000-0000-00000000000c', 'manager');

-- ======================= Isolation =======================
:as_stranger
select t.ok((select count(*) = 0 from public.businesses), 'stranger sees no businesses');
select t.ok((select count(*) = 0 from public.service_register), 'stranger cannot read service register');
select t.ok((select count(*) = 0 from public.system_controls), 'stranger cannot read controls');
select t.raises($$select public.create_business('S', 'stranger-biz', 'custom')$$, 'stranger cannot create business', '42501');
select t.raises($$select public.set_emergency_stop(true, 'x')$$, 'stranger cannot trigger emergency stop', '42501');

:as_manager
select t.ok((select count(*) = 1 and bool_and(slug = 'beta') from public.businesses), 'manager sees only their business');
select t.raises(format($$select public.enqueue_task(%L, null, 'research.market', 'x')$$, :'alpha'), 'manager cannot queue work for another business', '42501');
select t.raises(format($$insert into public.products(business_id, name, product_type) values (%L, 'p', 'digital')$$, :'alpha'), 'manager cannot insert products into another business', '42501');
insert into public.products(business_id, name, product_type, price_minor) values (:'beta', 'Guide', 'digital', 1500);
select t.ok((select count(*) = 1 from public.products), 'manager can add product to own business');
select t.raises($$update public.businesses set status = 'active'$$, 'clients cannot change business status directly', '42501');
select t.raises($$insert into public.tasks(kind, title) values ('system.healthcheck', 'x')$$, 'clients cannot insert tasks directly', '42501');
select t.raises($$select public.claim_next_task('evil-worker')$$, 'clients cannot claim tasks', '42501');
select t.ok((select count(*) = 0 from public.system_controls where key = 'owner_email'), 'owner_email never exposed');

:as_owner
select t.ok((select count(*) = 0 from public.system_controls where key = 'owner_email'), 'owner_email hidden even from owner via API');

-- Anonymous role: nothing.
:as_anon
select t.raises($$select count(*) from public.businesses$$, 'anon has no table access', '42501');
select t.raises($$select public.portfolio_overview()$$, 'anon cannot call overview', '42501');

-- ======================= Agents & isolation of agents =======================
:as_owner
select public.create_agent(:'alpha', 'Alpha Marketing', 'Marketing', array['campaigns']) as alpha_agent \gset
select public.create_agent(null, 'Chief Executive', 'Chief Executive', array['portfolio review'], 1::smallint, 'strategic') as ceo \gset
select t.raises(format($$select public.enqueue_task(%L, %L, 'marketing.plan', 'cross-business')$$, :'beta', :'alpha_agent'),
  'business agent cannot be assigned work for another business', '42501');
select t.ok((select runtime_status = 'idle' from public.agent_status where id = :'alpha_agent'), 'agent with no tasks is idle');

select public.enqueue_task(:'alpha', :'alpha_agent', 'marketing.plan', 'Plan launch') as task1 \gset
select t.ok((select runtime_status = 'queued' from public.agent_status where id = :'alpha_agent'), 'agent shows queued, not working, before execution');

-- ======================= Queue: claim, complete, fail, retry =======================
:as_service
select id as claimed from public.claim_next_task('w1') \gset
select t.ok(:'claimed' = :'task1', 'worker claims the queued task');
:as_owner
select t.ok((select runtime_status = 'working' from public.agent_status where id = :'alpha_agent'), 'agent shows working only while task is running');
:as_service
select t.raises(format($$select public.complete_task(%L, 'w1', null)$$, :'task1'), 'completion without result rejected', '22004');
select t.raises(format($$select public.complete_task(%L, 'other-worker', '{"x":1}')$$, :'task1'), 'other worker cannot complete a task it does not hold', '55000');
select t.ok((select public.fail_task(:'task1', 'w1', '{"message":"inference unavailable"}') = 'queued'), 'first failure re-queues');
select t.ok((select status = 'queued' and attempts = 1 and run_after > now() from public.tasks where id = :'task1'), 'retry is delayed with backoff');
update public.tasks set run_after = now() where id = :'task1';
select public.claim_next_task('w1') \gset ignored_
select public.fail_task(:'task1', 'w1', '{"message":"again"}');
update public.tasks set run_after = now() where id = :'task1';
select public.claim_next_task('w1') \gset ignored_
select t.ok((select public.fail_task(:'task1', 'w1', '{"message":"final"}') = 'failed'), 'task fails permanently after max attempts');
select t.ok((select status = 'failed' and result is null and error is not null from public.tasks where id = :'task1'), 'failed task is never recorded as completed');
select t.ok((select count(*) = 1 from public.notifications where category = 'task_failure'), 'failure raises a notification');
select t.ok((select count(*) >= 6 from public.task_events where task_id = :'task1'), 'task history recorded');
:as_owner
select t.ok((select runtime_status = 'failed' from public.agent_status where id = :'alpha_agent'), 'agent status reflects failure, not completion');

-- Timeout reaper
select public.enqueue_task(:'alpha', null, 'research.market', 'Slow job') as slow \gset
:as_service
select public.claim_next_task('w2') \gset ignored_
update public.tasks set locked_at = now() - interval '1 hour' where id = :'slow';
select public.reap_stale_tasks();
select t.ok((select status = 'queued' and error->>'code' = 'timeout' from public.tasks where id = :'slow'), 'timed-out task is retried by reaper');

-- Paused agent: tasks are not claimed
:as_owner
select public.set_agent_state(:'alpha_agent', 'paused');
select public.enqueue_task(:'alpha', :'alpha_agent', 'marketing.copy', 'Copy') as paused_task \gset
:as_service
update public.tasks set run_after = now() + interval '1 day' where id = :'slow';
select t.ok((select count(*) = 0 from public.claim_next_task('w3')), 'tasks for paused agents are not claimed');

-- ======================= Delegation limits =======================
:as_service
select public.enqueue_task(:'alpha', null, 'research.a', 'root', null, '{"q":1}') as d0 \gset
select public.enqueue_task(:'alpha', null, 'research.b', 'child', null, '{"q":2}', 50::smallint, false, :'d0') as d1 \gset
select t.raises(format($$select public.enqueue_task(%L, null, 'research.a', 'loop', null, '{"q":1}', 50::smallint, false, %L)$$, :'alpha', :'d1'),
  'delegation loop detected', '54000');
select public.enqueue_task(:'alpha', null, 'research.c', 'l2', null, '{}', 50::smallint, false, :'d1') as d2 \gset
select public.enqueue_task(:'alpha', null, 'research.d', 'l3', null, '{}', 50::smallint, false, :'d2') as d3 \gset
select public.enqueue_task(:'alpha', null, 'research.e', 'l4', null, '{}', 50::smallint, false, :'d3') as d4 \gset
select t.raises(format($$select public.enqueue_task(%L, null, 'research.f', 'l5', null, '{}', 50::smallint, false, %L)$$, :'alpha', :'d4'),
  'delegation depth limit enforced', '54000');
select public.cancel_task(id) from public.tasks where kind like 'research.%' and status = 'queued';

-- ======================= Approvals =======================
:as_owner
select public.enqueue_task(:'alpha', null, 'finance.purchase', 'Buy domain', null, '{}', 80::smallint, true, null, null,
  'Spend £10 on a domain', 4::smallint, 1000) as spend \gset
select t.ok((select status = 'awaiting_approval' from public.tasks where id = :'spend'), 'consequential task waits for approval');
:as_service
select t.ok((select count(*) = 0 from public.claim_next_task('w4', 'finance.')), 'unapproved task is never claimed');
:as_manager
select t.raises(format($$select public.decide_approval((select id from public.approvals where task_id = %L), true)$$, :'spend'),
  'non-owner cannot approve', '42501');
:as_owner
select public.decide_approval((select id from public.approvals where task_id = :'spend'), true, 'ok');
select t.ok((select status = 'queued' from public.tasks where id = :'spend'), 'approved task becomes runnable');
select t.raises(format($$select public.decide_approval((select id from public.approvals where task_id = %L), false)$$, :'spend'),
  'approval cannot be decided twice', '55000');
select t.ok((select count(*) >= 1 from public.audit_log where action = 'approve'), 'approval is audited');

-- Expiry: silence is never approval
select public.enqueue_task(:'alpha', null, 'marketing.publish', 'Publish post', null, '{}', 50::smallint, true) as pub \gset
:as_admin
update public.approvals set expires_at = now() - interval '1 minute' where task_id = :'pub';
:as_service
select public.reap_stale_tasks();
select t.ok((select status = 'cancelled' from public.tasks where id = :'pub'), 'expired approval cancels the task');
select t.ok((select status = 'expired' from public.approvals where task_id = :'pub'), 'approval marked expired');

-- ======================= Emergency stop =======================
:as_owner
select public.set_emergency_stop(true, 'test');
:as_service
select t.ok((select count(*) = 0 from public.claim_next_task('w5')), 'emergency stop halts all claiming');
select t.ok((select (public.run_system_tasks(5)->>'completed')::int = 0), 'system worker idle during emergency stop');
:as_owner
select public.set_emergency_stop(false, 'resume');
select t.ok((select count(*) = 2 from public.audit_log where action like 'emergency_stop_%'), 'emergency stop changes audited');

-- ======================= System worker =======================
:as_service
select public.schedule_daily_review() as review \gset
select t.ok((select public.schedule_daily_review() is null), 'daily review scheduling is idempotent');
select t.ok((select (public.run_system_tasks(10)->>'completed')::int >= 1), 'system worker completes system tasks');
select t.ok((select status = 'completed' and result ? 'pending_approvals' from public.tasks where id = :'review'), 'review stored a real result');

-- ======================= Ledger & financial reporting =======================
:as_owner
select t.ok((select (public.portfolio_overview()->'finance_gbp'->>'gross_revenue_minor')::bigint = 0), 'no data => zero revenue, nothing invented');
select public.record_manual_ledger_entry(:'alpha', 'revenue', 9999, now(), 'settled', 'sales', 'Order 1') as rev \gset
select public.record_manual_ledger_entry(:'alpha', 'revenue', 5000, now(), 'pending', 'sales', 'Unpaid order');
select public.record_manual_ledger_entry(:'alpha', 'revenue', 5000, now(), 'failed', 'sales', 'Failed payment');
select public.record_manual_ledger_entry(:'alpha', 'revenue', 777777, now(), 'settled', 'sample', 'SAMPLE DATA', null, 'GBP', true);
select public.record_manual_ledger_entry(:'alpha', 'payment_fee', 170, now(), 'settled', 'stripe_fees');
select public.record_manual_ledger_entry(:'alpha', 'software_cost', 400, now(), 'settled', 'software');
select public.record_manual_ledger_entry(:'alpha', 'refund', 1000, now(), 'settled', 'refund');
select t.ok((select gross_revenue_minor = 9999 from public.business_financials where business_id = :'alpha'), 'only settled, non-test revenue counts (pending/failed/test excluded)');
select t.ok((select pending_minor = 5000 from public.business_financials where business_id = :'alpha'), 'pending revenue shown separately');
select t.ok((select net_revenue_minor = 8999 and operating_profit_minor = 8999 - 170 - 400 from public.business_financials where business_id = :'alpha'), 'net revenue and operating profit computed correctly');
select t.ok((select (public.portfolio_overview()->'finance_gbp'->>'gross_revenue_minor')::bigint = 9999), 'portfolio overview excludes test data');
select t.raises(format($$update public.ledger_entries set amount_minor = 1 where id = %L$$, :'rev'), 'ledger amounts cannot be edited by clients', '42501');
:as_admin
select t.raises(format($$update public.ledger_entries set amount_minor = 1 where id = %L$$, :'rev'), 'ledger is append-only even for admins', 'P0001');
select t.raises(format($$delete from public.ledger_entries where id = %L$$, :'rev'), 'ledger rows cannot be deleted', 'P0001');
update public.ledger_entries set reconciliation_status = 'reconciled' where id = :'rev';
select t.ok((select reconciliation_status = 'reconciled' from public.ledger_entries where id = :'rev'), 'reconciliation status may be updated');
select t.raises(format($$insert into public.ledger_entries(business_id, entry_type, amount_minor, occurred_at, payment_status, source) values (%L, 'revenue', 100, now(), 'settled', 'stripe')$$, :'alpha'),
  'non-manual ledger entries require a traceable reference', '23514');
:as_manager
select t.raises(format($$select public.record_manual_ledger_entry(%L, 'revenue', 100, now(), 'settled')$$, :'beta'), 'managers cannot record manual revenue', '42501');
select t.ok((select count(*) = 0 from public.ledger_entries), 'manager cannot see another business ledger');

-- ======================= Content publication integrity =======================
:as_owner
select t.raises(format($$insert into public.content_items(business_id, channel, status) values (%L, 'tiktok', 'published')$$, :'alpha'),
  'clients cannot mark content published', '42501');

:as_admin
select t.ok((select count(*) > 0 from public.audit_log where entity = 'ledger_entries'), 'ledger writes audited');

-- ======================= Privilege guard (catches future leaks) =======================
:as_admin
select t.ok((select count(*) = 0 from information_schema.role_table_grants
             where table_schema = 'public' and grantee = 'anon'), 'anon has no table/view privileges');
select t.ok((select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')), 'anon cannot execute any public function');
select t.ok((select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute'))
  = array['can_access_business','can_manage_business','cancel_task','create_agent','create_business','decide_approval',
          'enqueue_task','is_owner','portfolio_overview','record_manual_ledger_entry','set_agent_state',
          'set_business_status','set_emergency_stop'], 'authenticated can execute only the allow-listed RPCs');
select t.ok((select count(*) = 0 from pg_tables where schemaname = 'public' and not rowsecurity), 'RLS enabled on every public table');
\echo ALL_DB_TESTS_PASSED
