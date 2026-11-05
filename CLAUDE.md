# Quantum — notes for future Claude sessions

Read `docs/IMPLEMENTATION_STATUS.md` first (production state, blockers, next task), then `docs/ROADMAP.md`.

## Ground rules (from the owner's master directive)
- Real functionality only; never invent sales, customers, figures, or agent activity. Empty data → £0.00 or an empty state.
- No spending, paid upgrades, Stripe writes, ad spend or paid AI generation without explicit owner approval.
- Never commit secrets. The repo is **public**. The owner email lives only in `system_controls.owner_email` in the DB.
- Test before claiming anything works; "deployed" means running in production.
- Owner works from an iPad: no local-machine steps; every UI must work in Safari at iPad sizes.
- Update `docs/IMPLEMENTATION_STATUS.md` (including the session log) at the end of every session.

## Stack
- Supabase project `tbnhiznxuldicfspcroc` (Free, eu-west-1). All logic in `supabase/migrations/`. Migration filenames must match the versions recorded in production (`list_migrations`).
- `web/`: zero-dependency TypeScript (see DECISIONS D3), built by `scripts/build.mjs` to `web/dist`.
- Tests: `tests/db/run.sh` (needs a local Postgres superuser), `npm test`, `npm run test:e2e`.

## Gotchas
- Every new public function must be explicitly revoked from `public, anon` (and `authenticated` unless intended), or the privilege-guard test fails. Add allowed RPCs to the guard's allow-list.
- The Supabase connector may require interactive confirmation for some migrations; unattended sessions get auto-cancelled. Don't retry in a loop. Use the `db-migrate` workflow or ask the owner.
- This workspace cannot reach the npm registry; use what's installed (tsc, Playwright, Postgres 16 at `/usr/lib/postgresql/16`).
