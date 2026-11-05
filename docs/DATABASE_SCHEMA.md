# Database schema

Source of truth: `supabase/migrations/` (applied in filename order). Money is stored as integer minor units (`*_minor`, pence) plus an ISO currency code.

| Table | Purpose | Client access |
|---|---|---|
| `system_controls` | emergency_stop, limits, ai_inference, owner_email (hidden) | owner read |
| `portfolio_owners` | who owns the portfolio | self read |
| `business_templates` | Business Factory templates and modules | owner read |
| `businesses` | registry (status: proposed, developing, active, paused, archived) | read by access; limited column updates by managers; create/status via RPC |
| `business_members` | per-business roles (manager, viewer) | read |
| `business_modules` | enabled modules per business | read; managers toggle |
| `objectives` | targets per business or portfolio | managers CRUD (no delete) |
| `agents` | AI workforce (scope, role, autonomy 1–4, model tier, admin_state) | read; RPC writes |
| `tasks` | persistent queue | read; RPC writes |
| `task_events` | status history per task | read |
| `approvals` | owner decisions | read; `decide_approval` |
| `products`, `customers`, `orders` | commerce | products/customers by managers; orders read-only |
| `ledger_entries` | append-only financial ledger | read; manual entries via RPC |
| `content_items` | marketing content (drafted → published) | managers; cannot set `published` |
| `knowledge_documents` | business memory (fact, assumption, recommendation, decision…; supersedable) | managers |
| `notifications` | in-app alerts | read; mark read |
| `audit_log` | append-only audit | owner read |
| `service_register` | live cost register | owner read |

Views (security_invoker, so RLS applies): `agent_status`, `business_financials`.
Function `portfolio_overview()` returns the dashboard JSON in one call.

## Invariants enforced by the database

- Completed task ⇒ has result and completed_at. Failed task ⇒ has error.
- Published content ⇒ has `published_at` and an external reference.
- Non-manual ledger entry ⇒ has a reference; `(business, source, reference, type)` unique (idempotent webhooks).
- Business slug format; agent scope matches business_id.
