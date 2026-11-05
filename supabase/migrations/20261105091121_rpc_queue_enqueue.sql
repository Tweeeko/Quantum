-- Applied to production as one of several smaller migrations (see DECISIONS D9).

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

revoke execute on function public.enqueue_task(uuid,uuid,text,text,text,jsonb,smallint,boolean,uuid,timestamptz,text,smallint,bigint) from public, anon;
revoke execute on function public.cancel_task(uuid,text) from public, anon;
grant execute on function
  public.enqueue_task(uuid,uuid,text,text,text,jsonb,smallint,boolean,uuid,timestamptz,text,smallint,bigint),
  public.cancel_task(uuid,text)
to authenticated, service_role;
