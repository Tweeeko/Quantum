// Quantum command centre — entry point, router, auth gate.
import { SupabaseClient } from './lib/supabase.js';
import { esc } from './lib/format.js';
import { views, errorPanel, type Ctx } from './views.js';

declare global { interface Window { QUANTUM_CONFIG?: { supabaseUrl: string; supabaseKey: string } } }

const cfg = window.QUANTUM_CONFIG;
const app = document.getElementById('app')!;

// Clickjacking guard for hosts that cannot send frame-ancestors headers.
if (window.top !== window.self) {
  app.textContent = 'Quantum cannot be displayed inside a frame.';
  throw new Error('framed');
}

if (!cfg?.supabaseUrl || !cfg?.supabaseKey) {
  app.innerHTML = `<div class="center-card"><h1>Quantum</h1><p class="muted">Missing config.js (Supabase URL / publishable key).</p></div>`;
  throw new Error('missing config');
}

let storage: Storage | { getItem(): null; setItem(): void; removeItem(): void };
try { localStorage.setItem('q.t', '1'); localStorage.removeItem('q.t'); storage = localStorage; }
catch { storage = { getItem: () => null, setItem: () => {}, removeItem: () => {} }; }

const db = new SupabaseClient(cfg.supabaseUrl, cfg.supabaseKey, storage);
if (db.consumeRedirectFragment(location.hash)) history.replaceState(null, '', location.pathname + '#/');

const NAV: Array<[string, string, string]> = [
  ['#/', 'Overview', '◎'],
  ['#/businesses', 'Businesses', '▦'],
  ['#/agents', 'AI Workforce', '◈'],
  ['#/tasks', 'Tasks', '☰'],
  ['#/approvals', 'Approvals', '✓'],
  ['#/finance', 'Finance', '£'],
  ['#/notifications', 'Notifications', '◉'],
  ['#/integrations', 'Integrations', '⇄'],
  ['#/settings', 'System', '⚙'],
];

function shell(active: string, body: string, email?: string): string {
  const nav = NAV.map(([href, name, icon]) => {
    const on = href === '#/' ? active === '' : active.startsWith(href.slice(2));
    return `<a href="${href}" class="nav-item${on ? ' active' : ''}"><span class="nav-icon" aria-hidden="true">${icon}</span><span>${name}</span></a>`;
  }).join('');
  return `
  <div class="layout">
    <aside class="sidebar">
      <div class="brand"><span class="brand-mark">Q</span><span class="brand-name">Quantum</span></div>
      <nav class="nav">${nav}</nav>
      <div class="sidebar-foot">
        <div class="muted small">${esc(email ?? '')}</div>
        <button class="btn ghost small" data-action="sign-out">Sign out</button>
      </div>
    </aside>
    <main class="main" id="main">${body}</main>
  </div>`;
}

let renderToken = 0;
async function render(): Promise<void> {
  const token = ++renderToken;
  const session = db.currentSession;
  const route = location.hash.replace(/^#\/?/, '');
  if (!session) { app.innerHTML = views.login(); return; }

  const [name, ...params] = route.split('/');
  const view = (views.routes as Record<string, ((c: Ctx, ...p: string[]) => Promise<string>) | undefined>)[name || 'overview'];
  app.innerHTML = shell(route, `<div class="loading">Loading…</div>`, session.user.email);
  const ctx: Ctx = { db, rerender: render };
  let html: string;
  try {
    html = view ? await view(ctx, ...params) : `<div class="empty"><h2>Not found</h2><p><a href="#/">Back to overview</a></p></div>`;
  } catch (e) {
    html = errorPanel(e);
  }
  if (token !== renderToken) return; // a newer navigation won
  const main = document.getElementById('main');
  if (main) { main.innerHTML = html; main.focus({ preventScroll: true }); }
}

// ---------- Global event delegation ----------
document.addEventListener('submit', async (ev) => {
  const form = ev.target as HTMLFormElement;
  const action = form.dataset.action;
  if (!action) return;
  ev.preventDefault();
  // Safari does not focus buttons on tap, so read the submitter from the event.
  form.dataset.mode = ((ev as SubmitEvent).submitter as HTMLButtonElement | null)?.value ?? '';
  const handler = (views.forms as Record<string, ((c: Ctx, f: FormData, el: HTMLFormElement) => Promise<string | void>) | undefined>)[action];
  if (!handler) return;
  const btn = form.querySelector<HTMLButtonElement>('button[type=submit]');
  const out = form.querySelector<HTMLElement>('.form-msg');
  if (btn) btn.disabled = true;
  if (out) { out.textContent = ''; out.className = 'form-msg'; }
  try {
    const msg = await handler({ db, rerender: render }, new FormData(form), form);
    if (msg && out) { out.textContent = msg; out.classList.add('ok'); }
  } catch (e) {
    if (out) { out.textContent = (e as Error).message; out.classList.add('bad'); }
  } finally { if (btn) btn.disabled = false; }
});

document.addEventListener('click', async (ev) => {
  const el = (ev.target as HTMLElement).closest<HTMLElement>('[data-action]');
  if (!el || el.tagName === 'FORM') return;
  const action = el.dataset.action!;
  if (action === 'sign-out') { await db.signOut(); location.hash = '#/'; render(); return; }
  const handler = (views.clicks as Record<string, ((c: Ctx, el: HTMLElement) => Promise<void>) | undefined>)[action];
  if (!handler) return;
  ev.preventDefault();
  if (el.dataset.confirm && !window.confirm(el.dataset.confirm)) return;
  (el as HTMLButtonElement).disabled = true;
  try { await handler({ db, rerender: render }, el); }
  catch (e) { window.alert((e as Error).message); }
  finally { (el as HTMLButtonElement).disabled = false; }
});

db.onAuthChange(() => render());
window.addEventListener('hashchange', render);
render();
