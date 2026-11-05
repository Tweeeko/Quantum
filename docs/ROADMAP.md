# Roadmap

Each phase must produce working, tested functionality. Status lives in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).

| Phase | Scope | State |
|---|---|---|
| 0 | Audit repo and integrations | **Done** |
| 1 | Core foundation: schema, auth bootstrap, RLS isolation, secure config, CI, deploy pipeline | **Deployed** (database); web app awaiting Pages |
| 2 | Command centre: overview, portfolio, business detail, platform status | **Implemented** (UI tested on mocked API); needs live DB |
| 3 | Business Factory: templates, dynamic creation, modules, objectives, knowledge | Templates, creation and modules done; objectives/knowledge UI pending |
| 4 | AI workforce: registry, roles, permissions, execution records, management UI | Registry, derived status and UI done; per-agent permission scopes pending |
| 5 | Execution engine: AI worker, inference adapters, delegation, usage budgets | Queue, retries, timeouts, scheduling, loop and depth guards done; **AI worker blocked on an inference provider (owner decision)** |
| 6 | Commercial: catalogue, customers, orders, Stripe webhook → ledger, reconciliation, P&L | Tables, ledger and P&L view done; Stripe webhook ingester next |
| 7 | Marketing: content calendar, campaigns, publishing via connected tools | `content_items` with publish-integrity rule done; rest pending |
| 8 | Owner control & safety: approvals, audit, emergency stop, alerts | Core done and tested; notification preferences and external alerts pending |
| 9 | Intelligence: portfolio analysis, forecasting with explicit assumptions | Not started |
| 10 | PocketOS as first real business | Not started. Will use only verified facts and real Stripe data |

## Next highest-priority tasks

1. Owner enables GitHub Pages (Actions source) and merges PR #1 → command centre live.
2. Owner signs up with the configured email; sign-ups then disabled.
3. Stripe webhook ingester (Edge Function, signature-verified, idempotent) → `orders` + `ledger_entries`.
4. Owner adds Anthropic credits and API key secret → Phase 5 AI worker.
5. Create PocketOS in Quantum from verified information.

## Known operational risk

Supabase Free pauses a project after a week of inactivity, which would stop the scheduler. `keepalive.yml` pings daily, but GitHub disables scheduled workflows after 60 days without commits. Check the Supabase dashboard if Quantum seems idle.
