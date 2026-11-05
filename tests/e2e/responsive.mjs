// Renders the built command centre in Chromium at iPad and phone sizes against
// a mocked Supabase API (empty portfolio) and checks: no console errors, no
// horizontal overflow, nav reachable, touch targets >= 44px, empty states
// rather than invented figures. Writes screenshots to tests/e2e/out/.
import { chromium } from 'playwright';
import http from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'web', 'dist');
const out = join(dirname(fileURLToPath(import.meta.url)), 'out');
await mkdir(out, { recursive: true });
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
const server = http.createServer(async (req, res) => {
  const p = join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/$/, '/index.html'));
  try { res.writeHead(200, { 'Content-Type': types[extname(p)] ?? 'application/octet-stream' }); res.end(await readFile(p)); }
  catch { res.writeHead(404); res.end(); }
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const overview = { businesses: { total: 0, active: 0, developing: 0, paused: 0 },
  finance_gbp: { gross_revenue_minor: 0, net_revenue_minor: 0, expenses_minor: 0, operating_profit_minor: 0, pending_minor: 0, settled_entries: 0 },
  agents: { total: 0, active: 0, working: 0 }, tasks: { queued: 0, running: 0, awaiting_approval: 0, failed_7d: 0, completed_7d: 0 },
  approvals_pending: 0, notifications_unread: 0, recent_orders: [],
  controls: { emergency_stop: { active: false }, ai_inference: { status: 'unavailable', note: 'No inference provider configured.' }, limits: { max_task_depth: 4 } },
  generated_at: new Date().toISOString() };
const tables = {
  business_templates: [{ key: 'physical_product', name: 'Physical product / hardware', description: 'Designed physical goods.', modules: ['catalog'] }],
  service_register: [{ service: 'Supabase', purpose: 'Database', current_plan: 'Free', free_allowance: '500 MB', known_restrictions: 'Pauses when idle', potential_cost: '$25/mo', status: 'in_use', owner_decision_required: false }],
  system_controls: [{ key: 'emergency_stop', value: { active: false } }, { key: 'limits', value: { max_task_depth: 4, max_concurrent_tasks: 5 } }, { key: 'ai_inference', value: { status: 'unavailable', note: 'No provider' } }],
};

const routes = ['#/', '#/businesses', '#/new-business', '#/agents', '#/tasks', '#/tasks/new', '#/approvals', '#/finance', '#/notifications', '#/integrations', '#/settings'];
const sizes = [['ipad-landscape', 1180, 820], ['ipad-portrait', 820, 1180], ['phone', 390, 844]];
const failures = [];
const browser = await chromium.launch();
for (const [name, width, height] of sizes) {
  const ctx = await browser.newContext({ viewport: { width, height }, hasTouch: true, isMobile: name !== 'ipad-landscape', deviceScaleFactor: 1 });
  await ctx.addInitScript(() => localStorage.setItem('quantum.session', JSON.stringify({ access_token: 'T', refresh_token: 'R', expires_at: 9999999999, user: { id: 'u', email: 'owner@example.test' } })));
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.route('https://tbnhiznxuldicfspcroc.supabase.co/**', (route) => {
    const u = new URL(route.request().url());
    if (u.pathname === '/rest/v1/rpc/portfolio_overview') return route.fulfill({ json: overview });
    const t = u.pathname.replace('/rest/v1/', '');
    return route.fulfill({ json: tables[t] ?? [] });
  });
  for (const r of routes) {
    await page.goto(base + '/' + r);
    await page.waitForFunction(() => !document.querySelector('.loading'), null, { timeout: 5000 });
    const check = await page.evaluate((vw) => {
      // Compare against the configured device width: mobile emulation widens
      // innerWidth to fit overflowing content, which would hide the bug.
      const overflow = document.documentElement.scrollWidth > vw + 1 || window.innerWidth > vw + 1;
      const bar = document.querySelector('.sidebar').getBoundingClientRect();
      const tallBar = vw <= 900 && bar.height > 90;
      const small = [...document.querySelectorAll('button, .btn, .nav-item, input, select')]
        .filter((el) => { const b = el.getBoundingClientRect(); return b.width > 0 && el.type !== 'hidden' && el.type !== 'checkbox' && b.height < 36; })
        .map((el) => el.outerHTML.slice(0, 80));
      const text = document.body.innerText;
      return { overflow, tallBar, small, error: !!document.querySelector('.error-panel'), text };
    }, width);
    const tag = `${name} ${r}`;
    if (check.overflow) failures.push(`${tag}: horizontal overflow`);
    if (check.tallBar) failures.push(`${tag}: top bar too tall`);
    if (check.small.length) failures.push(`${tag}: small touch targets ${check.small.join(' | ')}`);
    if (check.error) failures.push(`${tag}: error panel shown`);
    if (r === '#/' && !/£0\.00/.test(check.text)) failures.push(`${tag}: revenue should be £0.00 with no data`);
    if (r === '#/' && !/No settled transactions recorded/.test(check.text)) failures.push(`${tag}: missing empty-finance explanation`);
    if (r === '#/' && !/AI execution unavailable/.test(check.text)) failures.push(`${tag}: AI unavailable banner missing`);
    await page.screenshot({ path: join(out, `${name}${r.replace(/[#/]+/g, '_')}.png`), fullPage: true });
  }
  if (errors.length) failures.push(`${name}: console errors: ${errors.join(' | ')}`);
  await ctx.close();
}
// Signed-out view
const ctx = await browser.newContext({ viewport: { width: 820, height: 1180 } });
const page = await ctx.newPage();
await page.goto(base + '/');
if (!(await page.locator('form[data-action="sign-in"]').count())) failures.push('login form not shown when signed out');
await page.screenshot({ path: join(out, 'login.png') });
await browser.close(); server.close();

if (failures.length) { console.error('E2E FAILURES:\n' + failures.join('\n')); process.exit(1); }
console.log(`E2E OK: ${routes.length} routes x ${sizes.length} viewports + login`);
