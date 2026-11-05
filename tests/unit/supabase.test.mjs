import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SupabaseClient, ApiError } from '../../web/dist/app/lib/supabase.js';

function memStorage() { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: (k) => m.delete(k), m }; }
function mockFetch(handler) {
  const calls = [];
  const fn = async (url, init = {}) => { calls.push({ url, init, headers: new Headers(init.headers) }); return handler(url, init, calls.length); };
  fn.calls = calls; return fn;
}
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const URL_ = 'https://x.supabase.co', KEY = 'sb_publishable_test';

test('signIn stores session and sends only the publishable key', async () => {
  const f = mockFetch(() => json({ access_token: 'A', refresh_token: 'R', expires_in: 3600, user: { id: 'u1', email: 'o@x' } }));
  const st = memStorage();
  const c = new SupabaseClient(URL_, KEY, st, f);
  await c.signIn('o@x', 'pw123456');
  assert.equal(f.calls[0].url, URL_ + '/auth/v1/token?grant_type=password');
  assert.equal(f.calls[0].headers.get('apikey'), KEY);
  assert.equal(f.calls[0].headers.get('Authorization'), null);
  assert.equal(c.currentSession.user.id, 'u1');
  assert.ok(st.getItem('quantum.session'));
});

test('authenticated requests carry the user token; expired tokens refresh once', async () => {
  const st = memStorage();
  st.setItem('quantum.session', JSON.stringify({ access_token: 'OLD', refresh_token: 'R1', expires_at: 1, user: { id: 'u1' } }));
  const f = mockFetch((url) => url.includes('refresh_token')
    ? json({ access_token: 'NEW', refresh_token: 'R2', expires_in: 3600, user: { id: 'u1' } })
    : json([{ id: 1 }]));
  const c = new SupabaseClient(URL_, KEY, st, f);
  await Promise.all([c.select('businesses'), c.select('tasks')]);
  const refreshes = f.calls.filter((x) => x.url.includes('refresh_token'));
  assert.equal(refreshes.length, 1, 'concurrent requests share one refresh');
  const data = f.calls.filter((x) => x.url.includes('/rest/v1/'));
  assert.ok(data.every((x) => x.headers.get('Authorization') === 'Bearer NEW'));
});

test('failed refresh signs the user out instead of using a stale token', async () => {
  const st = memStorage();
  st.setItem('quantum.session', JSON.stringify({ access_token: 'OLD', refresh_token: 'R1', expires_at: 1, user: { id: 'u1' } }));
  const f = mockFetch((url) => url.includes('refresh_token') ? json({ error: 'invalid_grant' }, 400) : json([]));
  const c = new SupabaseClient(URL_, KEY, st, f);
  let changed = 0; c.onAuthChange(() => changed++);
  await c.select('businesses');
  assert.equal(c.currentSession, null);
  assert.equal(st.getItem('quantum.session'), null);
  assert.equal(changed, 1);
  assert.equal(f.calls.at(-1).headers.get('Authorization'), null);
});

test('PostgREST errors surface message and code', async () => {
  const f = mockFetch(() => json({ code: '42501', message: 'permission denied: portfolio owner required' }, 403));
  const c = new SupabaseClient(URL_, KEY, memStorage(), f);
  await assert.rejects(c.rpc('create_business', {}), (e) => e instanceof ApiError && e.status === 403 && e.code === '42501' && /owner required/.test(e.message));
});

test('rpc posts JSON args and handles empty (void) responses', async () => {
  const f = mockFetch(() => new Response(null, { status: 204 }));
  const c = new SupabaseClient(URL_, KEY, memStorage(), f);
  assert.equal(await c.rpc('set_emergency_stop', { p_active: true }), null);
  assert.equal(f.calls[0].url, URL_ + '/rest/v1/rpc/set_emergency_stop');
  assert.deepEqual(JSON.parse(f.calls[0].init.body), { p_active: true });
});

test('email-confirmation redirect fragment becomes a session', () => {
  const payload = Buffer.from(JSON.stringify({ sub: 'u9', email: 'o@x' })).toString('base64url');
  const c = new SupabaseClient(URL_, KEY, memStorage(), mockFetch(() => json({})));
  assert.equal(c.consumeRedirectFragment(`#access_token=h.${payload}.s&refresh_token=R&expires_in=3600&type=signup`), true);
  assert.equal(c.currentSession.user.id, 'u9');
  assert.equal(c.consumeRedirectFragment('#/businesses'), false);
});

test('corrupt stored session is ignored', () => {
  const st = memStorage(); st.setItem('quantum.session', '{not json');
  assert.equal(new SupabaseClient(URL_, KEY, st, mockFetch(() => json({}))).currentSession, null);
});
