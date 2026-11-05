-- Quantum core foundation
-- Tenancy, businesses, agents, tasks (persistent queue), approvals, ledger,
-- audit log, notifications, knowledge, system controls.
--
-- Design rules enforced here (see SECURITY.md / DECISIONS.md):
--  * Every business row is isolated by RLS. Portfolio-scoped rows
--    (business_id IS NULL) are visible to portfolio owners only.
--  * Agent runtime status is DERIVED from tasks, never stored, so an agent can
--    never be shown "working" when nothing is executing.
--  * Ledger is append-only. Corrections are adjustment entries.
--  * Test/sample financial data is flagged is_test and excluded from reporting.
--  * Queue mutation functions are service_role only; owners act via RPCs that
--    check permissions and write to the audit log.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.business_status as enum ('proposed','developing','active','paused','archived');
create type public.agent_admin_state as enum ('enabled','paused','disabled');
create type public.agent_scope as enum ('portfolio','business');
create type public.task_status as enum ('queued','running','awaiting_approval','completed','failed','cancelled');
create type public.approval_status as enum ('pending','approved','rejected','expired');
create type public.ledger_entry_type as enum ('revenue','refund','expense','software_cost','advertising_cost','payment_fee','tax','adjustment');
create type public.payment_status as enum ('pending','settled','failed','reversed');
create type public.reconciliation_status as enum ('unreconciled','reconciled','disputed');
create type public.content_status as enum ('drafted','approved','scheduled','published','failed');
create type public.knowledge_kind as enum ('fact','assumption','recommendation','decision','policy','procedure');

-- ---------------------------------------------------------------------------
-- System controls (emergency stop, limits, owner bootstrap email)
-- ---------------------------------------------------------------------------
create table public.system_controls (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

insert into public.system_controls(key, value) values
  ('emergency_stop', '{"active": false, "reason": null}'),
  ('limits', '{"max_task_depth": 4, "default_max_attempts": 3, "default_timeout_seconds": 300, "max_concurrent_tasks": 5, "retry_base_seconds": 30}'),
  ('ai_inference', '{"provider": null, "status": "unavailable", "note": "No inference provider configured. AI tasks stay queued; nothing is simulated."}');
-- 'owner_email' is inserted out-of-band (never committed to the public repo).

-- ---------------------------------------------------------------------------
-- Identity & tenancy
-- ---------------------------------------------------------------------------
create table public.portfolio_owners (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.business_templates (
  key            text primary key,
  name           text not null,
  description    text not null,
  modules        text[] not null,
  suggested_agents jsonb not null default '[]'
);

create table public.businesses (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  name          text not null check (length(name) between 1 and 120),
  description   text,
  category      text,
  business_model text,
  template_key  text references public.business_templates(key),
  status        public.business_status not null default 'proposed',
  branding      jsonb not null default '{}',
  settings      jsonb not null default '{}',
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.business_members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null default 'viewer' check (role in ('manager','viewer')),
  primary key (business_id, user_id)
);

create table public.business_modules (
  business_id uuid not null references public.businesses(id) on delete cascade,
  module_key  text not null,
  enabled     boolean not null default true,
  config      jsonb not null default '{}',
  primary key (business_id, module_key)
);

create table public.objectives (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid references public.businesses(id) on delete cascade,
  title        text not null,
  metric       text,
  target_value numeric,
  due_date     date,
  status       text not null default 'open' check (status in ('open','met','missed','dropped')),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Access helpers (SECURITY DEFINER so they can read membership tables
-- without recursive RLS evaluation)
-- ---------------------------------------------------------------------------
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.portfolio_owners where user_id = auth.uid());
$$;

create or replace function public.can_access_business(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_owner()
      or (bid is not null and exists (
            select 1 from public.business_members
            where business_id = bid and user_id = auth.uid()));
$$;

create or replace function public.can_manage_business(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_owner()
      or (bid is not null and exists (
            select 1 from public.business_members
            where business_id = bid and user_id = auth.uid() and role = 'manager'));
$$;

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------
create table public.agents (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid references public.businesses(id) on delete cascade,
  scope            public.agent_scope not null,
  name             text not null,
  role             text not null,
  responsibilities text[] not null default '{}',
  autonomy_level   smallint not null default 1 check (autonomy_level between 1 and 4),
  model_tier       text not null default 'economical' check (model_tier in ('lightweight','economical','reasoning','strategic','writing')),
  admin_state      public.agent_admin_state not null default 'enabled',
  config           jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  check ((scope = 'portfolio' and business_id is null) or (scope = 'business' and business_id is not null))
);

-- ---------------------------------------------------------------------------
-- Tasks: persistent queue
-- ---------------------------------------------------------------------------
create table public.tasks (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid references public.businesses(id) on delete cascade,
  agent_id         uuid references public.agents(id) on delete set null,
  parent_task_id   uuid references public.tasks(id) on delete set null,
  depth            smallint not null default 0,
  kind             text not null check (kind ~ '^[a-z_]+\.[a-z_.]+$'),
  title            text not null,
  description      text,
  priority         smallint not null default 50 check (priority between 0 and 100),
  status           public.task_status not null default 'queued',
  requires_approval boolean not null default false,
  input            jsonb not null default '{}',
  result           jsonb,
  error            jsonb,
  attempts         smallint not null default 0,
  max_attempts     smallint not null default 3,
  timeout_seconds  integer not null default 300,
  run_after        timestamptz not null default now(),
  locked_by        text,
  locked_at        timestamptz,
  usage            jsonb not null default '{}',
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  completed_at     timestamptz,
  -- A completed task must have a result and no error; a failed task must have an error.
  check (status <> 'completed' or (result is not null and completed_at is not null)),
  check (status <> 'failed' or error is not null)
);
create index tasks_claim_idx on public.tasks (status, run_after, priority desc) where status = 'queued';
create index tasks_business_idx on public.tasks (business_id, created_at desc);
create index tasks_agent_idx on public.tasks (agent_id, created_at desc);

create table public.task_events (
  id          bigint generated always as identity primary key,
  task_id     uuid not null references public.tasks(id) on delete cascade,
  business_id uuid,
  from_status public.task_status,
  to_status   public.task_status not null,
  detail      jsonb,
  created_at  timestamptz not null default now()
);
create index task_events_task_idx on public.task_events (task_id, id);

-- ---------------------------------------------------------------------------
-- Approvals
-- ---------------------------------------------------------------------------
create table public.approvals (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid references public.businesses(id) on delete cascade,
  task_id            uuid references public.tasks(id) on delete cascade,
  requested_by_agent uuid references public.agents(id) on delete set null,
  action             text not null,
  reason             text not null,
  autonomy_level     smallint not null check (autonomy_level between 1 and 4),
  financial_impact_minor bigint,
  currency           char(3),
  risks              text,
  evidence           jsonb not null default '{}',
  status             public.approval_status not null default 'pending',
  decided_by         uuid references auth.users(id),
  decided_at         timestamptz,
  decision_note      text,
  expires_at         timestamptz not null default now() + interval '7 days',
  created_at         timestamptz not null default now()
);
create index approvals_pending_idx on public.approvals (status, created_at) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Commerce: products, customers, orders
-- ---------------------------------------------------------------------------
create table public.products (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  name          text not null,
  description   text,
  product_type  text not null check (product_type in ('physical','digital','service','subscription')),
  price_minor   bigint check (price_minor >= 0),
  currency      char(3) not null default 'GBP',
  cost_minor    bigint check (cost_minor >= 0),
  status        text not null default 'draft' check (status in ('draft','preorder','available','paused','retired')),
  sales_channel text,
  fulfilment    jsonb not null default '{}',
  assets        jsonb not null default '[]',
  external_ref  text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.customers (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  name              text,
  email             text,
  marketing_consent boolean not null default false,
  consent_recorded_at timestamptz,
  status            text not null default 'active' check (status in ('lead','active','inactive','erased')),
  external_ref      text,
  created_at        timestamptz not null default now(),
  unique (business_id, email)
);

create table public.orders (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  customer_id    uuid references public.customers(id) on delete set null,
  status         text not null default 'open' check (status in ('open','paid','fulfilled','cancelled','refunded')),
  payment_status public.payment_status not null default 'pending',
  total_minor    bigint not null check (total_minor >= 0),
  currency       char(3) not null default 'GBP',
  source         text not null,
  external_ref   text,
  is_test        boolean not null default false,
  created_at     timestamptz not null default now(),
  unique (business_id, source, external_ref)
);

-- ---------------------------------------------------------------------------
-- Ledger (append-only)
-- ---------------------------------------------------------------------------
create table public.ledger_entries (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references public.businesses(id) on delete restrict,
  entry_type            public.ledger_entry_type not null,
  amount_minor          bigint not null check (amount_minor >= 0 or entry_type = 'adjustment'),
  currency              char(3) not null default 'GBP' check (currency ~ '^[A-Z]{3}$'),
  occurred_at           timestamptz not null,
  payment_status        public.payment_status not null,
  source                text not null check (source in ('stripe','manual','bank','other')),
  reference             text,
  category              text,
  description           text,
  order_id              uuid references public.orders(id) on delete restrict,
  reconciliation_status public.reconciliation_status not null default 'unreconciled',
  corrects_entry_id     uuid references public.ledger_entries(id),
  is_test               boolean not null default false,
  recorded_by           uuid references auth.users(id),
  recorded_at           timestamptz not null default now(),
  -- Traceability: anything not entered by hand must carry an external reference.
  check (source = 'manual' or reference is not null),
  unique (business_id, source, reference, entry_type)
);
create index ledger_business_idx on public.ledger_entries (business_id, occurred_at desc);

create or replace function public.forbid_ledger_mutation() returns trigger
language plpgsql as $$
begin
  -- reconciliation_status is the only field that may change after recording.
  if tg_op = 'UPDATE'
     and (to_jsonb(new) - 'reconciliation_status') = (to_jsonb(old) - 'reconciliation_status') then
    return new;
  end if;
  raise exception 'ledger_entries is append-only; record an adjustment instead' using errcode = 'P0001';
end $$;
create trigger ledger_append_only before update or delete on public.ledger_entries
  for each row execute function public.forbid_ledger_mutation();

-- ---------------------------------------------------------------------------
-- Marketing content, knowledge, notifications, audit, service register
-- ---------------------------------------------------------------------------
create table public.content_items (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  channel       text not null,
  title         text,
  body          text,
  status        public.content_status not null default 'drafted',
  scheduled_for timestamptz,
  published_at  timestamptz,
  external_ref  text,
  -- 'published' requires confirmation from the external service.
  check (status <> 'published' or (published_at is not null and external_ref is not null)),
  created_at    timestamptz not null default now()
);

create table public.knowledge_documents (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid references public.businesses(id) on delete cascade,
  kind          public.knowledge_kind not null,
  title         text not null,
  body          text not null,
  source        text,
  status        text not null default 'current' check (status in ('current','superseded','outdated')),
  superseded_by uuid references public.knowledge_documents(id),
  created_at    timestamptz not null default now()
);

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,
  category    text not null,
  priority    text not null default 'normal' check (priority in ('low','normal','high','critical')),
  title       text not null,
  body        text,
  link        text,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create table public.audit_log (
  id          bigint generated always as identity primary key,
  actor_type  text not null check (actor_type in ('user','agent','system')),
  actor_id    text,
  action      text not null,
  entity      text not null,
  entity_id   text,
  business_id uuid,
  details     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index audit_log_created_idx on public.audit_log (created_at desc);

create table public.service_register (
  service           text primary key,
  purpose           text not null,
  current_plan      text not null,
  free_allowance    text,
  known_restrictions text,
  potential_cost    text,
  payment_required  boolean not null default false,
  owner_decision_required boolean not null default false,
  status            text not null default 'in_use' check (status in ('in_use','available','not_used','blocked')),
  updated_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
create or replace function public.write_audit(p_actor_type text, p_action text, p_entity text,
  p_entity_id text, p_business uuid, p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into public.audit_log(actor_type, actor_id, action, entity, entity_id, business_id, details)
  values (p_actor_type,
          case when p_actor_type = 'user' then auth.uid()::text else null end,
          p_action, p_entity, p_entity_id, p_business, coalesce(p_details,'{}'));
$$;

create or replace function public.limit_value(p_key text) returns integer
language sql stable security definer set search_path = public as $$
  select (value ->> p_key)::int from public.system_controls where key = 'limits';
$$;

create or replace function public.emergency_stop_active() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((value ->> 'active')::boolean, true) from public.system_controls where key = 'emergency_stop';
$$;

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger businesses_touch before update on public.businesses for each row execute function public.touch_updated_at();
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();

-- Task status history
create or replace function public.log_task_event() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.task_events(task_id, business_id, from_status, to_status, detail)
    values (new.id, new.business_id, null, new.status, jsonb_build_object('kind', new.kind));
  elsif new.status is distinct from old.status then
    insert into public.task_events(task_id, business_id, from_status, to_status, detail)
    values (new.id, new.business_id, old.status, new.status,
            jsonb_strip_nulls(jsonb_build_object('attempts', new.attempts, 'error', new.error, 'locked_by', new.locked_by)));
  end if;
  return new;
end $$;
create trigger tasks_history after insert or update on public.tasks
  for each row execute function public.log_task_event();

-- Generic audit trigger for sensitive tables
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb := to_jsonb(coalesce(new, old));
begin
  insert into public.audit_log(actor_type, actor_id, action, entity, entity_id, business_id, details)
  values (case when auth.uid() is null then 'system' else 'user' end,
          auth.uid()::text, lower(tg_op), tg_table_name, r ->> 'id',
          nullif(r ->> 'business_id','')::uuid,
          case when tg_table_name = 'ledger_entries'
               then jsonb_build_object('entry_type', r->'entry_type', 'amount_minor', r->'amount_minor', 'currency', r->'currency', 'source', r->'source')
               else '{}'::jsonb end);
  return coalesce(new, old);
end $$;
create trigger audit_businesses after insert or update or delete on public.businesses for each row execute function public.audit_row();
create trigger audit_ledger after insert on public.ledger_entries for each row execute function public.audit_row();
create trigger audit_agents after insert or update or delete on public.agents for each row execute function public.audit_row();
create trigger audit_products after insert or update or delete on public.products for each row execute function public.audit_row();

-- Owner bootstrap: a new auth user becomes portfolio owner only if their
-- email matches system_controls.owner_email (set out-of-band). Anyone else who
-- signs up gets an account with no access to anything.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner_email text;
begin
  select lower(value #>> '{}') into owner_email from public.system_controls where key = 'owner_email';
  if owner_email is not null and lower(new.email) = owner_email then
    insert into public.portfolio_owners(user_id) values (new.id) on conflict do nothing;
    perform public.write_audit('system', 'owner_bootstrap', 'portfolio_owners', new.id::text, null, '{}');
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
