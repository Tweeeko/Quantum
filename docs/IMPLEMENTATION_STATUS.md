# Implementation status

States: Not started · In progress · Implemented · Tested · Deployed · Blocked.
"Deployed" means running in production, not "code exists".

## Production database (Supabase project `tbnhiznxuldicfspcroc`)

| Migration | State |
|---|---|
| 20261105083334_core_foundation | **Deployed** |
| 20261105083353_rls_policies | **Deployed** |
| 20261105083601_lock_core_helpers | **Deployed** |
| 20261105090100_rpc_and_queue | **Blocked**: the Supabase connector asks for interactive confirmation and the client auto-cancelled it (3 attempts) |
| 20261105090200_views_and_system_worker | Blocked (depends on the above) |
| 20261105090300_seed_reference_data | Blocked |
| 20261105090400_schedules | Blocked |
| 20261105090500_harden_privileges | Blocked |

Production is in a **safe** partial state: all tables exist with RLS on and client grants revoked; no RPCs exist yet, so the API exposes nothing usable. To finish: approve the prompt in a Claude session, or run the **Database migrate** GitHub Action (needs two secrets; see DEPLOYMENT.md).

`system_controls.owner_email` has **not** been set yet (it is set out-of-band so it never enters the public repo).

## Features

| Feature | State | Evidence |
|---|---|---|
| Schema (20 tables, enums, constraints) | Tested | tests/db |
| Business isolation via RLS | Tested | stranger/manager/anon cases |
| Owner bootstrap by configured email | Tested | |
| Business Factory (11 templates, modules) | Tested | |
| Agent registry, derived runtime status | Tested | idle → queued → working → failed |
| Task queue: claim, complete, retry with backoff, permanent failure | Tested | |
| Timeouts, approval expiry (silence ≠ approval) | Tested | |
| Delegation depth limit and loop guard | Tested | |
| Approvals (owner only, single decision, audited) | Tested | |
| Emergency stop (halts claiming, audited) | Tested | |
| Deterministic system worker (daily review, healthcheck) | Tested | pg_cron schedule untested locally (no pg_cron) |
| Append-only ledger; test data excluded from reporting | Tested | |
| Financial views (gross/net/fees/expenses/profit/pending) | Tested | |
| Privilege guard (no anon access, RPC allow-list) | Tested | |
| Command centre UI (9 screens) | Tested on mocked API | 11 routes × 3 viewports |
| Supabase client (auth, refresh, errors) | Tested | unit tests |
| CI workflow | Implemented | runs on first PR |
| GitHub Pages deploy | Implemented | runs on merge to main |
| Stripe webhook ingestion | Not started | |
| AI inference worker | Blocked | needs provider decision |
| Objectives / knowledge base UI | Not started | tables exist |
| Customers / orders UI | Not started | tables exist |
| Notification preferences, external alerts | Not started | |

## Session log — 5 Nov 2026

1. **Inspected:** empty repo; Supabase, Cloudflare, Stripe, n8n (read-only).
2. **Changed:** created the whole codebase; applied 3 migrations to production.
3. **Tests run:** 73 database assertions, 13 unit tests, 33 responsive page renders + login; typecheck on TS 6 and 7.
4. **Passed:** all. Failures found and fixed along the way: an anonymous-executable `portfolio_overview` (caught by the privilege guard), iPad-portrait nav overflow (caught by a stricter E2E check), and an ineffective CSP meta directive.
5. **Incomplete:** production migrations 4–8; web deployment; owner account.
6. **Needs owner:** see "Owner actions" in DEPLOYMENT.md.
7. **Next:** finish production migrations, then the Stripe webhook ingester.
