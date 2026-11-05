# Quantum

Autonomous business portfolio operating system. One owner, many businesses, each with its own specialist AI workforce, ledger, products and workflows, run from a single command centre that works on an iPad.

Created by **Leeko**.

> **Status (5 Nov 2026):** Phase 0 (audit) and Phase 1 (core foundation) are complete in the repo. The database schema, isolation and scheduler are tested locally (73 database assertions). Production Supabase is **partially migrated**: see [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md). Nothing is deployed to the web yet.

## What is here

| Part | Where | What it does |
|---|---|---|
| Database & backend | `supabase/migrations/` | Postgres schema, row-level security per business, task queue, approvals, append-only ledger, audit log, emergency stop, in-database scheduler (pg_cron) |
| Command centre | `web/` | Zero-dependency TypeScript web app (Safari/iPad-first) talking to Supabase |
| Tests | `tests/` | Database tests on real Postgres, unit tests, responsive browser tests |
| Docs | `docs/` | Audit, architecture, roadmap, status, security, schema, deployment, decisions |

## Principles

- Real data only. No sample figures in dashboards; empty means £0.00 or an empty state.
- Revenue counts only when **settled, non-test and traceable**. Pending, failed and test entries never appear as revenue.
- An agent is shown as working **only** while one of its tasks is actually running (derived, never stored).
- Spending money, launching a business and other consequential actions need explicit owner approval. Silence is never approval; requests expire.
- £0 starting budget: every service and its limits are in the live cost register (`service_register` table, Integrations screen).

## Develop

```bash
npm install            # TypeScript only
npm run build          # -> web/dist (static, deployable as-is)
npm test               # build + unit tests
npm run test:db        # needs a local PostgreSQL superuser (PGHOST/PGPORT/PGUSER)
npm run test:e2e       # needs Playwright + Chromium
```

CI runs all of these on every pull request (`.github/workflows/ci.yml`).

## Docs

[Audit](docs/AUDIT.md) · [Architecture](docs/ARCHITECTURE.md) · [Roadmap](docs/ROADMAP.md) · [Implementation status](docs/IMPLEMENTATION_STATUS.md) · [Integrations & costs](docs/INTEGRATIONS.md) · [Security](docs/SECURITY.md) · [Database schema](docs/DATABASE_SCHEMA.md) · [Deployment](docs/DEPLOYMENT.md) · [Testing](docs/TESTING.md) · [Decisions](docs/DECISIONS.md)
