# Deployment

Everything below works from Safari on an iPad.

## Components

| Part | Where | How it deploys |
|---|---|---|
| Database | Supabase project `tbnhiznxuldicfspcroc` | Migrations via the Supabase connector in Claude, or the manual **Database migrate** GitHub Action |
| Command centre | GitHub Pages (static `web/dist`) | `deploy-pages.yml` on every merge to `main` |
| Scheduler | pg_cron inside Supabase | Installed by the `schedules` migration: system worker and reaper every minute, daily review at 07:00 UTC |
| Keepalive | GitHub Actions cron | `keepalive.yml`, daily |

## Environment / config

- `web/public/config.js`: Supabase URL and **publishable** key (public by design). No other client config.
- Secrets (never in the repo): `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD` (GitHub Actions, only for db-migrate); later `STRIPE_WEBHOOK_SECRET` and the inference provider key (Supabase Edge Function secrets).

## Owner actions (one-time)

1. **Finish database migrations** (choose one):
   - In a Claude session, ask to "apply the pending Quantum migrations" and **approve** the Supabase confirmation prompts; or
   - GitHub → Settings → Secrets and variables → Actions: add `SUPABASE_ACCESS_TOKEN` (supabase.com/dashboard/account/tokens) and `SUPABASE_DB_PASSWORD`. Then Actions → *Database migrate (production)* → Run workflow → type `migrate`.
2. **Set the owner email** (Claude does this via SQL so it never lands in the public repo), then sign up in the command centre with that email.
3. Supabase → Authentication → URL Configuration: set Site URL to the Pages URL (`https://tweeeko.github.io/Quantum/`) so confirmation emails link back correctly.
4. Disable new sign-ups after registering.
5. Merge the PR → Pages deploys automatically. (GitHub Pages must be set to "GitHub Actions" as its source: Settings → Pages.)

## Backup & recovery

Supabase Free has daily backups that are **not downloadable** and no point-in-time recovery. Until there is real data worth protecting, the migrations are the recovery path for schema. Once revenue data exists, add a scheduled `pg_dump` export (GitHub Action to a private location), or decide on Pro (owner decision).

## Rollback

- Web: revert the merge commit; Pages redeploys.
- Database: write a new forward migration. The ledger is append-only by design, so never delete financial rows.
