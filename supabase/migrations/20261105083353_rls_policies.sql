-- Row-level security: business isolation.
-- Default deny. Clients (role `authenticated`) see only businesses they own
-- or are members of. Portfolio-scoped rows (business_id null) are owner-only.
-- Mutations of queue, approvals, ledger corrections and controls go through
-- SECURITY DEFINER RPCs (see the rpc_and_queue migration) rather than direct table writes.

do $$
declare t text;
begin
  foreach t in array array[
    'system_controls','portfolio_owners','business_templates','businesses','business_members',
    'business_modules','objectives','agents','tasks','task_events','approvals','products',
    'customers','orders','ledger_entries','content_items','knowledge_documents',
    'notifications','audit_log','service_register']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Reference data readable by any signed-in owner.
create policy templates_read on public.business_templates for select to authenticated using (public.is_owner());
create policy register_read on public.service_register for select to authenticated using (public.is_owner());
grant select on public.business_templates, public.service_register to authenticated;

-- System controls: owners read; writes via RPC only. owner_email is hidden.
create policy controls_read on public.system_controls for select to authenticated
  using (public.is_owner() and key <> 'owner_email');
grant select on public.system_controls to authenticated;

create policy owners_self on public.portfolio_owners for select to authenticated using (user_id = auth.uid());
grant select on public.portfolio_owners to authenticated;

-- Businesses
create policy businesses_read on public.businesses for select to authenticated using (public.can_access_business(id));
create policy businesses_update on public.businesses for update to authenticated
  using (public.can_manage_business(id)) with check (public.can_manage_business(id));
grant select, update (name, description, category, business_model, branding, settings) on public.businesses to authenticated;
-- Creation, status changes and archive go through create_business / set_business_status RPCs.

create policy members_read on public.business_members for select to authenticated using (public.can_access_business(business_id));
grant select on public.business_members to authenticated;

create policy modules_read on public.business_modules for select to authenticated using (public.can_access_business(business_id));
create policy modules_write on public.business_modules for update to authenticated
  using (public.can_manage_business(business_id)) with check (public.can_manage_business(business_id));
grant select, update (enabled, config) on public.business_modules to authenticated;

-- Tables with business_id that managers may read/write directly.
do $$
declare t text;
begin
  foreach t in array array['objectives','products','customers','content_items','knowledge_documents'] loop
    execute format($f$create policy %1$s_read on public.%1$I for select to authenticated
      using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end)$f$, t);
    execute format($f$create policy %1$s_insert on public.%1$I for insert to authenticated
      with check (case when business_id is null then public.is_owner() else public.can_manage_business(business_id) end)$f$, t);
    execute format($f$create policy %1$s_update on public.%1$I for update to authenticated
      using (case when business_id is null then public.is_owner() else public.can_manage_business(business_id) end)
      with check (case when business_id is null then public.is_owner() else public.can_manage_business(business_id) end)$f$, t);
    execute format('grant select, insert, update on public.%I to authenticated', t);
  end loop;
end $$;

-- content 'published' may only be set by the system (service integrations), not clients.
create policy content_no_client_publish on public.content_items as restrictive for update to authenticated
  with check (status <> 'published');
create policy content_no_client_publish_ins on public.content_items as restrictive for insert to authenticated
  with check (status <> 'published');

-- Read-only to clients
create policy agents_read on public.agents for select to authenticated
  using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end);
create policy tasks_read on public.tasks for select to authenticated
  using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end);
create policy task_events_read on public.task_events for select to authenticated
  using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end);
create policy approvals_read on public.approvals for select to authenticated
  using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end);
create policy orders_read on public.orders for select to authenticated using (public.can_access_business(business_id));
create policy ledger_read on public.ledger_entries for select to authenticated using (public.can_access_business(business_id));
create policy notifications_read on public.notifications for select to authenticated
  using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end);
create policy notifications_mark_read on public.notifications for update to authenticated
  using (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end)
  with check (case when business_id is null then public.is_owner() else public.can_access_business(business_id) end);
create policy audit_read on public.audit_log for select to authenticated using (public.is_owner());

grant select on public.agents, public.tasks, public.task_events, public.approvals, public.orders,
  public.ledger_entries, public.notifications, public.audit_log to authenticated;
grant update (read_at) on public.notifications to authenticated;
