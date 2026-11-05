# Architecture

```
 iPad Safari ──HTTPS──▶ Static command centre (web/dist, GitHub Pages or Cloudflare Pages)
                              │  publishable key + user JWT
                              ▼
                    Supabase (Postgres 17, eu-west-1)
        ┌───────────────────────────────────────────────────────┐
        │ Auth ── RLS (per-business isolation) ── PostgREST API │
        │ RPCs: create_business, enqueue_task, decide_approval… │
        │ Queue: tasks + task_events (persistent, retry/backoff) │
        │ pg_cron: system worker (1 min), reaper (1 min),        │
        │          daily review (07:00 UTC)                      │
        └───────────────────────────────────────────────────────┘
                              ▲
         Phase 5: AI worker (Edge Function or Worker) claims non-system
         tasks via claim_next_task / complete_task / fail_task with the
         service-role key, through a provider-independent inference adapter.
```

## Why this shape

- **The database is the operating system.** State, isolation, queue, scheduling, approvals and audit all live in Postgres, so nothing depends on a browser tab or a Claude session staying open. pg_cron runs inside Supabase on the free plan.
- **Thin client.** The web app has no runtime dependencies and no secrets. It renders data and calls RPCs; every rule is enforced server-side, so a compromised or buggy client cannot bypass isolation.
- **Deterministic first.** `system.*` tasks (health checks, daily review) run as SQL with zero AI cost. AI tasks wait in the queue until a provider is approved, and are never faked.

## Key components

| Component | Location |
|---|---|
| Tenancy and RLS | `public.is_owner()`, `can_access_business()`, `can_manage_business()`, plus policies in the RLS migration |
| Business Factory | `business_templates` (11 templates), `create_business()` enables template modules |
| Agent registry | `agents` + `agent_status` view (runtime status derived from tasks) |
| Execution engine | `enqueue_task` (depth limit, loop guard, agent/business match), `claim_next_task` (SKIP LOCKED, concurrency cap, honours emergency stop and paused agents/businesses), `complete_task`, `fail_task` (exponential backoff), `reap_stale_tasks` (timeouts, approval expiry) |
| Approvals | `approvals` + `decide_approval` (owner only, audited, single decision) |
| Finance | Append-only `ledger_entries`; `business_financials` view; `portfolio_overview()` |
| Safety | `system_controls.emergency_stop`, `set_emergency_stop()`, `audit_log` |

## Phase 5 inference layer (planned)

A worker with an adapter interface `{ id, complete(request) → { output, usage, cost } }`, mapping model tiers (`lightweight`, `economical`, `reasoning`, `strategic`, `writing`) to configured providers. On provider error it calls `fail_task`, so tasks are never marked complete without real output. External content is passed as data, never as instructions.
