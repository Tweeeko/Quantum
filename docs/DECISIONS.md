# Decisions

**D1 — Build fresh inside the existing repo (5 Nov 2026).** The repo was empty, so there was nothing to preserve or migrate.

**D2 — Supabase as the operating core.** An empty project named "Quantum" already existed on the free plan with pg_cron available. Postgres gives RLS isolation, transactional queue semantics (`FOR UPDATE SKIP LOCKED`) and in-database scheduling for £0, without a separate worker host. Alternatives (Cloudflare D1 + Workers cron, n8n) were rejected: the Cloudflare connector cannot deploy Workers, and n8n's plan and cost are unknown.

**D3 — Zero-dependency TypeScript front end instead of Next.js/React.** The cloud workspace cannot reach npm, so a framework app couldn't be built or tested here. A dependency-free app is fully verifiable, static-hostable for free, has no supply-chain surface, and loads fast on iPad. Revisit if the UI outgrows it. Migration would be screen by screen; the API layer is reusable.

**D4 — Derived agent status.** Runtime status is computed from tasks, so "working" can't drift from reality (brief §6.3).

**D5 — Append-only ledger with adjustments**, integer pence, `is_test` flag, and revenue only when settled.

**D6 — Owner identity via an out-of-band email.** The repo is public, so the owner's email is stored only in the database.

**D7 — GitHub Pages hosting** for the command centre (free for public repos, deployable without dashboard setup). Cloudflare Pages remains a drop-in alternative (`_headers` is included).

**D8 — AI execution left honestly unavailable** until the owner approves a provider and budget. System tasks run deterministically in SQL in the meantime.

**D9 — Small migrations with explicit statements.** The Supabase connector asks for interactive confirmation on some SQL (bulk status changes to `approvals`), and this client auto-cancels that prompt. Migrations are therefore applied in small pieces with explicit `revoke`s, and approval expiry is isolated in `expire_approvals()`.

**D10 — AI provider: Anthropic API recommended (pending owner approval).** Haiku 5.5 for most work, Sonnet 5.5 for research and strategy; prepaid credits give a hard cap. See INTEGRATIONS.md. The adapter stays provider-independent.
