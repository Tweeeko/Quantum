# Integrations & cost register

Budget: **£0**. Nothing paid is activated without owner approval. The live register is the `service_register` table (Integrations screen). This file mirrors it.

| Service | Purpose | Plan | Free allowance | Restrictions | Potential cost | Owner decision? |
|---|---|---|---|---|---|---|
| Supabase | DB, auth, RLS, pg_cron, future Edge Functions | Free | 500 MB DB, 50k MAU, 5 GB egress, 1 GB storage, 500k Edge Function calls/month | Pauses after ~7 days idle; 2 active projects; no PITR | Pro from $25/month | No (not yet) |
| GitHub | Code, CI, Pages | Free, public repo | Actions unlimited for public repos | Repo is public; private + Pages needs a paid plan | Pro ~$4/month | **Yes:** public vs private |
| Cloudflare | Alternative hosting, future webhooks | Free | Workers 100k requests/day | Deploy needs owner-created token or dashboard Git link | $5/month if exceeded | No |
| Stripe | PocketOS payments → ledger | Live account | No monthly fee | Live mode only; Quantum is read-only until a verified webhook exists | Per-transaction fees | **Yes:** before any write or webhook registration |
| n8n | Optional automation | Unknown | Unknown | Empty; not relied on | Plan-dependent | Yes, if used |
| AI inference | Agent reasoning and drafting | None | None | Claude subscription ≠ API access | Pay-per-token | **Yes:** blocks Phase 5 |
| Higgsfield / vidIQ / TikTok / Metricool | Marketing and creative | Connected | Varies | Generation and ads spend credits or money | Varies | **Yes** for any spend |

## Capability notes (verified this session)

- **Supabase MCP:** list/apply migrations, execute SQL, advisors, edge functions, keys. Some DDL triggers an interactive confirmation; in unattended sessions that confirmation is auto-cancelled.
- **Cloudflare MCP:** read/list Workers, KV, R2, D1; create/delete KV/R2/D1. **No Worker deploy.** Marked deprecated in favour of the Cloudflare API MCP.
- **Stripe MCP:** account listing confirmed (`PocketOS`, livemode). No other calls made.
- **n8n MCP:** instance reachable and empty.
