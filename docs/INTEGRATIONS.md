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

## AI provider recommendation (researched 5 Nov 2026; awaiting owner approval)

**Recommended: Anthropic API**, with two tiers mapped to Quantum's model tiers:

| Quantum tier | Model | Price per 1M tokens (in / out) | Used for |
|---|---|---|---|
| lightweight, economical, writing | Claude Haiku 5.5 | $0.10 / $0.50 (prompts ≤100K tokens; $0.50 / $2.50 above) | classification, drafting, routine reports. Most tasks. |
| reasoning, strategic | Claude Sonnet 5.5 | $2 / $10 | market research, business analysis, strategy |
| web research tool | Anthropic web search | $10 per 1,000 searches | research agents (capped per task with `max_uses`) |

Why: Haiku 5.5 matches the cheapest mainstream small models on price. The Console uses prepaid credits, so API calls stop at £0 when auto-reload is off: a hard spending cap. API data isn't used for training by default. One account covers both tiers plus web search.

Alternatives considered:
- **Google Gemini**: 2.5 Flash-Lite $0.10 / $0.40, with a free tier. But free-tier content is used to improve Google's products, so it isn't suitable for customer or business data. A possible later fallback for public-web research only. Pay-as-you-go billing is post-paid (budget alerts, not hard caps).
- **OpenAI**: competitive mini/nano pricing and prepaid credits; no advantage over Haiku 5.5 here.
- **DeepSeek**: cheapest, but jurisdiction and data-handling concerns make it unsuitable for customer data.

Estimated starting cost (illustrative): 1,000 routine Haiku tasks (~8K in / 1.5K out) ≈ $1.55; 100 Sonnet research tasks (~20K in / 3K out) ≈ $7; 500 searches ≈ $5. That's about **$14/month (~£11)**, enforced by a prepaid balance plus Quantum's own per-task limits.

Owner setup (iPad): Claude Console → Billing → buy a small credit amount, auto-reload **off** → Settings → Limits: set a monthly spend limit → create an API key → Supabase dashboard → Edge Functions → Secrets → add `ANTHROPIC_API_KEY`. Never paste the key into chat.
