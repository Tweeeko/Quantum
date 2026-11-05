# Phase 0 audit — 5 November 2026

## Repository

`Tweeeko/Quantum` (public, default branch `main`) was created on 4 Nov 2026 at 22:00 UTC and was **empty**: size 0, no commits, no branches, no files. There was no existing framework, code, configuration, tests, documentation or history to preserve. Every item in the brief's audit checklist (framework, frontend, backend, database, auth, integrations, automation, AI, API routes, deployment, env vars, security, dashboard, business/financial features, tests) is therefore **"not present"**, with no broken features and no technical debt.

**Implication:** the "audit before changing" rule did not constrain the architecture. Quantum was built fresh *inside* the existing repository, not as a replacement project.

## Connected services (tested with read-only calls)

| Service | Finding | Usable for Quantum? |
|---|---|---|
| **Supabase** | Org "Leeeko", **Free** plan. Project **"Quantum"** (`tbnhiznxuldicfspcroc`, eu-west-1, Postgres 17, healthy) created 4 Nov, **empty**: no tables, migrations, edge functions or auth users. `pg_cron`, `pg_net`, `pgmq`, `vector` available. MCP can apply migrations and run SQL. | **Yes, primary backend.** Some migrations need an interactive confirmation (see blockers). |
| **Cloudflare** | One unrelated Worker (`squelchlife-rooms`); no D1 databases. The connector can list and read Workers, KV, R2 and D1 but **cannot deploy Workers** (and is marked deprecated). | Alternative static hosting via owner dashboard setup; not required now. |
| **Stripe** | One account, "PocketOS", **live mode only**; no test-mode context exposed. | Read-only until a verified webhook ingester exists. **No writes made.** Live-only access means integration testing needs care. |
| **n8n** | Connected instance with nothing built. Plan/billing not verifiable via the connector. | Not used by the core, so the platform doesn't depend on a possibly paid service. |
| **Zapier** | Connected; not used. | Not needed for Phase 1. |
| **TikTok for Business, Metricool, Higgsfield, vidIQ** | Connected marketing and creative tools. Not probed in depth. | Phase 7 candidates. Higgsfield generation spends credits and **needs approval**. |
| **GitHub** | Push access to `Tweeeko/Quantum`. Actions free for public repos. | Source control, CI, Pages hosting. |

## Environment constraints discovered

- The cloud workspace **cannot reach the npm registry** (blocked by egress policy). The build therefore uses no runtime npm dependencies. CI (GitHub Actions) installs TypeScript normally.
- No AI inference API key exists. A Claude subscription does not provide unattended API usage, so AI execution is honestly marked **unavailable**.

## Gaps vs. the brief (all were missing)

Everything. Phase 1 built the foundation that the other phases depend on: schema, isolation, queue, approvals, ledger, audit, emergency stop, command centre shell. See [ROADMAP.md](ROADMAP.md).

## Security notes

- The repository is **public**. No secrets are committed. The only client value, the Supabase publishable key, is designed to be public; access is enforced by RLS.
- The owner's email is not committed. It is stored in the database (`system_controls.owner_email`, hidden from the API) and decides who becomes portfolio owner on sign-up.
- Supabase Auth sign-ups are open by default. Any stranger who signs up gets **no access** (tested), but disabling sign-ups after the owner registers is recommended.
