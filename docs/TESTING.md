# Testing

| Suite | Command | What it proves |
|---|---|---|
| Database | `npm run test:db` | Applies every migration to a fresh Postgres with a Supabase shim (roles, `auth.users`, `auth.uid()`), then runs 73 assertions as owner, manager, stranger, anon and service role, connected through `authenticator` exactly like PostgREST |
| Unit | `npm test` | Money parsing/formatting (exact pence), HTML escaping, slug rules, the API client's auth/refresh/error behaviour against a mocked fetch |
| Responsive E2E | `npm run test:e2e` | Chromium at iPad landscape, iPad portrait and phone: every screen renders with no console errors, no horizontal overflow, compact top bar, ≥36 px controls (most 44 px), £0.00 and empty states with no data, AI-unavailable banner |
| Typecheck | `npm run typecheck` | strict TypeScript |

Required coverage from the brief, and where it lives: business isolation, agent permissions, task retries, failed tasks never "completed", approval requirements, emergency stop, test data excluded from finance, and webhook verification (**pending**, Phase 6). All but the last are in `tests/db/test_core.sql`.

The assertion helpers fail loudly. Flipping one expected value makes the suite exit non-zero, which was checked when the suite was written.

Test vs production: tests run only against throwaway local or CI databases. Never point `test:db` at production.
