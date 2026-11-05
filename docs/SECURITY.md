# Security

## Model

- **Server-side enforcement only.** All access rules are Postgres RLS policies and SECURITY DEFINER RPCs with explicit permission checks. The client holds only the publishable key and the user's JWT.
- **Isolation:** a user sees a business only as portfolio owner or as a listed member. Portfolio-scoped rows (`business_id` null) are owner-only. A business agent cannot be assigned work for another business (`enqueue_task` check).
- **Least privilege:** `anon` has no access to anything. `authenticated` may execute only an allow-listed set of 13 functions; queue mutation (`claim/complete/fail/reap`) is `service_role` only. A test fails if any future migration leaks access.
- **Owner bootstrap:** only the email in `system_controls.owner_email` (never in the repo, hidden from the API) becomes owner on sign-up. Others get accounts with no access.
- **Financial integrity:** ledger is append-only (trigger blocks update/delete except reconciliation status); non-manual entries need a reference; managers cannot record revenue; test data is flagged and excluded.
- **Approvals:** owner only; single decision; expiry cancels the task; every decision audited.
- **Emergency stop:** one switch halts all task claiming; audited and notified.
- **Audit log:** businesses, agents, products, ledger, approvals, status changes, emergency stop.
- **Web app:** CSP (`script-src 'self'`, connect only to the Supabase project), no inline scripts or styles, all interpolated values HTML-escaped, frame guard. `_headers` adds `frame-ancestors`/`X-Frame-Options` on Cloudflare Pages.

## Secrets

- Never committed. The service-role key, Stripe secret and DB password go in Supabase secrets or GitHub Actions secrets only.
- Never paste secrets into chat.

## Prompt-injection stance (for Phase 5 agents)

External content (web pages, emails, customer messages) is passed to models as quoted data, never as instructions. Agents have no tool that can disclose secrets, change permissions, move money or alter security settings; those paths require owner approval through RPCs that agents can't call.

## Owner hardening checklist

- [ ] After registering, disable new sign-ups in Supabase (Authentication → Sign In / Providers → turn off "Allow new users to sign up").
- [ ] Decide public vs private repository.
- [ ] Enable MFA on GitHub and Supabase accounts.
