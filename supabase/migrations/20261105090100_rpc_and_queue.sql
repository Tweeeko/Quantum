-- RPCs: Business Factory, agent registry, task queue, approvals, controls, ledger.

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create or replace function public.require_owner() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then
    raise exception 'permission denied: portfolio owner required' using errcode = '42501';
  end if;
end $$;

create or replace function public.require_manage(bid uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if bid is null then perform public.require_owner(); return; end if;
  if not public.can_manage_business(bid) then
    raise exception 'permission denied for business %', bid using errcode = '42501';
  end if;
end $$;

-- service_role (workers, cron) is trusted; owner/managers are checked.
create or replace function public.is_service() returns boolean
language sql stable as $$
  -- JWT role as set by PostgREST (both legacy and current GUC forms), or a
  -- direct database session such as pg_cron. Clients always connect via
  -- `authenticator`, so session_user cannot be spoofed from the API.
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
                  nullif(current_setting('request.jwt.claim.role', true), '')) = 'service_role'
      or session_user in ('postgres','supabase_admin');
$$;

-- ---------------------------------------------------------------------------
-- Business Factory
-- ---------------------------------------------------------------------------
create or replace function public.create_business(
  p_name text, p_slug text, p_template_key text,
  p_description text default null, p_category text default null, p_business_model text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_modules text[];
begin
  perform public.require_owner();
  select modules into v_modules from public.business_templates where key = p_template_key;
  if v_modules is null then raise exception 'unknown template %', p_template_key using errcode = '22023'; end if;

  insert into public.businesses(name, slug, template_key, description, category, business_model, status, created_by)
  values (trim(p_name), lower(trim(p_slug)), p_template_key, p_description, p_category,
          coalesce(p_business_model, p_template_key), 'proposed', auth.uid())
  returning id into v_id;

  insert into public.business_modules(business_id, module_key)
  select v_id, unnest(v_modules);

  perform public.write_audit('user', 'create_business', 'businesses', v_id::text, v_id,
    jsonb_build_object('template', p_template_key));
  return v_id;
end $$;

create or replace function public.set_business_status(p_business uuid, p_status public.business_status, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_old public.business_status;
begin
  perform public.require_owner();
  select status into v_old from public.businesses where id = p_business for update;
  if v_old is null then raise exception 'business not found' using errcode = 'P0002'; end if;
  -- Launching (-> active) is a Level 3 decision; only the owner can do it, and it is audited.
  update public.businesses set status = p_status where id = p_business;
  perform public.write_audit('user', 'set_business_status', 'businesses', p_business::text, p_business,
    jsonb_build_object('from', v_old, 'to', p_status, 'note', p_note));
end $$;

-- ---------------------------------------------------------------------------
-- Agent registry
-- ---------------------------------------------------------------------------
create or replace function public.create_agent(
  p_business uuid, p_name text, p_role text, p_responsibilities text[] default '{}',
  p_autonomy_level smallint default 1, p_model_tier text default 'economical')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_manage(p_business);
  if p_autonomy_level >= 3 then perform public.require_owner(); end if;
  insert into public.agents(business_id, scope, name, role, responsibilities, autonomy_level, model_tier)
  values (p_business, case when p_business is null then 'portfolio' else 'business' end::public.agent_scope,
          p_name, p_role, coalesce(p_responsibilities,'{}'), p_autonomy_level, p_model_tier)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.set_agent_state(p_agent uuid, p_state public.agent_admin_state)
returns void language plpgsql security definer set search_path = public as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.agents where id = p_agent;
  if not found then raise exception 'agent not found' using errcode = 'P0002'; end if;
  perform public.require_manage(v_bid);
  update public.agents set admin_state = p_state where id = p_agent;
end $$;

-- ---------------------------------------------------------------------------
-- Task queue
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_task(
  p_business uuid, p_agent uuid, p_kind text, p_title text,
  p_description text default null, p_input jsonb default '{}',
  p_priority smallint default 50, p_requires_approval boolean default false,
  p_parent uuid default null, p_run_after timestamptz default null,
  p_approval_reason text default null, p_autonomy_level smallint default 3,
  p_financial_impact_minor bigint default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_depth smallint := 0; v_agent public.agents; v_parent public.tasks;
  v_max_depth int := coalesce(public.limit_value('max_task_depth'), 4);
begin
  if not public.is_service() then perform public.require_manage(p_business); end if;

  if p_agent is not null then
    select * into v_agent from public.agents where id = p_agent;
    if not found then raise exception 'agent not found' using errcode = 'P0002'; end if;
    -- Isolation: a business agent may only work on its own business.
    if v_agent.scope = 'business' and v_agent.business_id is distinct from p_business then
      raise exception 'agent % is not assigned to business %', p_agent, p_business using errcode = '42501';
    end if;
    if v_agent.scope = 'portfolio' and not public.is_service() then perform public.require_owner(); end if;
  end if;

  if p_parent is not null then
    select * into v_parent from public.tasks where id = p_parent;
    if not found then raise exception 'parent task not found' using errcode = 'P0002'; end if;
    v_depth := v_parent.depth + 1;
    if v_depth > v_max_depth then
      raise exception 'delegation depth % exceeds limit %', v_depth, v_max_depth using errcode = '54000';
    end if;
    -- Loop guard: refuse an identical kind+input already in this delegation chain.
    if exists (
      with recursive chain as (
        select id, parent_task_id, kind, input from public.tasks where id = p_parent
        union all
        select t.id, t.parent_task_id, t.kind, t.input from public.tasks t join chain c on t.id = c.parent_task_id)
      select 1 from chain where kind = p_kind and input = coalesce(p_input,'{}')) then
      raise exception 'delegation loop detected for kind %', p_kind using errcode = '54000';
    end if;
  end if;

  insert into public.tasks(business_id, agent_id, parent_task_id, depth, kind, title, description, input,
    priority, requires_approval, status, run_after, max_attempts, timeout_seconds, created_by)
  values (p_business, p_agent, p_parent, v_depth, p_kind, p_title, p_description, coalesce(p_input,'{}'),
    p_priority, p_requires_approval,
    case when p_requires_approval then 'awaiting_approval' else 'queued' end::public.task_status,
    coalesce(p_run_after, now()),
    coalesce(public.limit_value('default_max_attempts'), 3),
    coalesce(public.limit_value('default_timeout_seconds'), 300),
    auth.uid())
  returning id into v_id;

  if p_requires_approval then
    insert into public.approvals(business_id, task_id, requested_by_agent, action, reason, autonomy_level,
      financial_impact_minor, currency)
    values (p_business, v_id, p_agent, p_title, coalesce(p_approval_reason, 'Approval required before execution'),
      p_autonomy_level, p_financial_impact_minor, case when p_financial_impact_minor is not null then 'GBP' end);
    insert into public.notifications(business_id, category, priority, title, body, link)
    values (p_business, 'approval', 'high', 'Approval needed: ' || p_title, p_approval_reason, '#/approvals');
  end if;

  return v_id;
end $$;

create or replace function public.cancel_task(p_task uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.tasks;
begin
  select * into v from public.tasks where id = p_task for update;
  if not found then raise exception 'task not found' using errcode = 'P0002'; end if;
  if not public.is_service() then perform public.require_manage(v.business_id); end if;
  if v.status in ('completed','failed','cancelled') then
    raise exception 'task already finished (%)', v.status using errcode = '55000';
  end if;
  update public.tasks set status = 'cancelled', completed_at = now(),
    error = jsonb_build_object('cancelled', true, 'reason', p_reason), locked_by = null
  where id = p_task;
  update public.approvals set status = 'rejected', decided_at = now(), decision_note = 'task cancelled'
  where task_id = p_task and status = 'pending';
end $$;

-- Claim the next runnable task. Workers only (service_role / cron).
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

-- Fail with exponential backoff retry until max_attempts.
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

-- Time out stuck tasks and expire stale approvals. Run by cron.
create or replace function public.reap_stale_tasks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_timed_out int := 0; v_expired int := 0;
begin
  for r in select id, locked_by from public.tasks
           where status = 'running' and locked_at < now() - make_interval(secs => timeout_seconds)
           for update skip locked loop
    perform public.fail_task(r.id, r.locked_by, jsonb_build_object('message', 'timed out', 'code', 'timeout'), true);
    v_timed_out := v_timed_out + 1;
  end loop;

  for r in update public.approvals set status = 'expired', decided_at = now(), decision_note = 'expired without decision'
           where status = 'pending' and expires_at < now() returning task_id loop
    v_expired := v_expired + 1;
    update public.tasks set status = 'cancelled', completed_at = now(),
      error = jsonb_build_object('message', 'approval expired; silence is never treated as approval')
    where id = r.task_id and status = 'awaiting_approval';
  end loop;

  return jsonb_build_object('timed_out', v_timed_out, 'approvals_expired', v_expired);
end $$;

-- ---------------------------------------------------------------------------
-- Approvals
-- ---------------------------------------------------------------------------
create or replace function public.decide_approval(p_approval uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.approvals;
begin
  perform public.require_owner();
  select * into v from public.approvals where id = p_approval for update;
  if not found then raise exception 'approval not found' using errcode = 'P0002'; end if;
  if v.status <> 'pending' then raise exception 'approval already %', v.status using errcode = '55000'; end if;
  if v.expires_at < now() then raise exception 'approval has expired' using errcode = '55000'; end if;

  update public.approvals set status = case when p_approve then 'approved' else 'rejected' end::public.approval_status,
    decided_by = auth.uid(), decided_at = now(), decision_note = p_note
  where id = p_approval;

  if v.task_id is not null then
    if p_approve then
      update public.tasks set status = 'queued', run_after = now() where id = v.task_id and status = 'awaiting_approval';
    else
      update public.tasks set status = 'cancelled', completed_at = now(),
        error = jsonb_build_object('message', 'rejected by owner', 'note', p_note)
      where id = v.task_id and status = 'awaiting_approval';
    end if;
  end if;

  perform public.write_audit('user', case when p_approve then 'approve' else 'reject' end, 'approvals',
    p_approval::text, v.business_id, jsonb_build_object('action', v.action, 'note', p_note,
      'financial_impact_minor', v.financial_impact_minor));
end $$;

-- ---------------------------------------------------------------------------
-- Emergency stop
-- ---------------------------------------------------------------------------
create or replace function public.set_emergency_stop(p_active boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_owner();
  update public.system_controls set value = jsonb_build_object('active', p_active, 'reason', p_reason),
    updated_at = now(), updated_by = auth.uid()
  where key = 'emergency_stop';
  perform public.write_audit('user', case when p_active then 'emergency_stop_on' else 'emergency_stop_off' end,
    'system_controls', 'emergency_stop', null, jsonb_build_object('reason', p_reason));
  insert into public.notifications(category, priority, title, body)
  values ('security', 'critical',
          case when p_active then 'Emergency stop ACTIVATED' else 'Emergency stop released' end, p_reason);
end $$;

-- ---------------------------------------------------------------------------
-- Ledger: manual entries (Stripe entries arrive via verified webhook worker)
-- ---------------------------------------------------------------------------
create or replace function public.record_manual_ledger_entry(
  p_business uuid, p_entry_type public.ledger_entry_type, p_amount_minor bigint,
  p_occurred_at timestamptz, p_payment_status public.payment_status, p_category text default null,
  p_description text default null, p_reference text default null, p_currency char(3) default 'GBP',
  p_is_test boolean default false, p_corrects uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_manage(p_business);
  if p_entry_type = 'revenue' and not public.is_owner() then
    raise exception 'only the owner may record manual revenue' using errcode = '42501';
  end if;
  insert into public.ledger_entries(business_id, entry_type, amount_minor, currency, occurred_at, payment_status,
    source, reference, category, description, is_test, corrects_entry_id, recorded_by)
  values (p_business, p_entry_type, p_amount_minor, upper(p_currency), p_occurred_at, p_payment_status,
    'manual', p_reference, p_category, p_description, p_is_test, p_corrects, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Function privileges: deny by default, then grant explicitly.
-- ---------------------------------------------------------------------------
revoke execute on function public.require_owner() from public, anon, authenticated;
revoke execute on function public.require_manage(uuid) from public, anon, authenticated;
revoke execute on function public.is_service() from public, anon, authenticated;
revoke execute on function public.create_business(text,text,text,text,text,text) from public, anon;
revoke execute on function public.set_business_status(uuid, public.business_status, text) from public, anon;
revoke execute on function public.create_agent(uuid,text,text,text[],smallint,text) from public, anon;
revoke execute on function public.set_agent_state(uuid, public.agent_admin_state) from public, anon;
revoke execute on function public.enqueue_task(uuid,uuid,text,text,text,jsonb,smallint,boolean,uuid,timestamptz,text,smallint,bigint) from public, anon;
revoke execute on function public.cancel_task(uuid,text) from public, anon;
revoke execute on function public.claim_next_task(text,text) from public, anon, authenticated;
revoke execute on function public.complete_task(uuid,text,jsonb,jsonb) from public, anon, authenticated;
revoke execute on function public.fail_task(uuid,text,jsonb,boolean) from public, anon, authenticated;
revoke execute on function public.reap_stale_tasks() from public, anon, authenticated;
revoke execute on function public.decide_approval(uuid,boolean,text) from public, anon;
revoke execute on function public.set_emergency_stop(boolean,text) from public, anon;
revoke execute on function public.record_manual_ledger_entry(uuid, public.ledger_entry_type, bigint, timestamptz, public.payment_status, text, text, text, char, boolean, uuid) from public, anon;

-- Needed inside RLS policy expressions:
grant execute on function public.is_owner(), public.can_access_business(uuid), public.can_manage_business(uuid) to authenticated;
-- Owner / manager RPCs:
grant execute on function
  public.create_business(text,text,text,text,text,text),
  public.set_business_status(uuid, public.business_status, text),
  public.create_agent(uuid,text,text,text[],smallint,text),
  public.set_agent_state(uuid, public.agent_admin_state),
  public.enqueue_task(uuid,uuid,text,text,text,jsonb,smallint,boolean,uuid,timestamptz,text,smallint,bigint),
  public.cancel_task(uuid,text),
  public.decide_approval(uuid,boolean,text),
  public.set_emergency_stop(boolean,text),
  public.record_manual_ledger_entry(uuid, public.ledger_entry_type, bigint, timestamptz, public.payment_status, text, text, text, char, boolean, uuid)
to authenticated;
-- Worker-only RPCs:
grant execute on function
  public.claim_next_task(text,text), public.complete_task(uuid,text,jsonb,jsonb),
  public.fail_task(uuid,text,jsonb,boolean), public.reap_stale_tasks(),
  public.enqueue_task(uuid,uuid,text,text,text,jsonb,smallint,boolean,uuid,timestamptz,text,smallint,bigint),
  public.cancel_task(uuid,text)
to service_role;
