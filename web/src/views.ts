// Screens. Every number shown comes from the database; empty data renders an
// explicit empty state, never placeholder figures.
import type { SupabaseClient } from './lib/supabase.js';
import { esc, money, relativeTime, label, statusTone, slugify, parseMoneyToMinor } from './lib/format.js';

export interface Ctx { db: SupabaseClient; rerender: () => Promise<void> }

const badge = (s: string | null | undefined) => `<span class="badge ${statusTone(s)}">${esc(label(s))}</span>`;
const stat = (title: string, value: string, sub = '') =>
  `<div class="stat"><div class="stat-label">${esc(title)}</div><div class="stat-value">${value}</div>${sub ? `<div class="stat-sub">${sub}</div>` : ''}</div>`;
const empty = (title: string, body: string) => `<div class="empty"><h3>${esc(title)}</h3><p class="muted">${body}</p></div>`;
const header = (title: string, sub = '', actions = '') =>
  `<header class="page-head"><div><h1>${esc(title)}</h1>${sub ? `<p class="muted">${sub}</p>` : ''}</div><div class="page-actions">${actions}</div></header>`;
const n = (v: unknown) => Number(v ?? 0);

const TASK_KINDS: Array<[string, string]> = [
  ['research.market', 'Research a market or opportunity'],
  ['research.competitors', 'Investigate competitors'],
  ['analysis.performance', 'Analyse business performance'],
  ['proposal.business', 'Create a new business proposal'],
  ['product.idea', 'Generate a product idea'],
  ['marketing.campaign', 'Prepare a marketing campaign'],
  ['support.review', 'Review customer enquiries'],
  ['finance.report', 'Produce a financial report'],
  ['operations.issues', 'Identify operational problems'],
  ['system.healthcheck', 'System healthcheck (runs now, no AI)'],
  ['system.daily_review', 'Daily review (runs now, no AI)'],
];

function table(cols: string[], rows: string[][], cls = ''): string {
  return `<div class="table-wrap"><table class="${cls}"><thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}

export function errorPanel(e: unknown): string {
  const err = e as { message?: string; status?: number; code?: string };
  let hint = '';
  if (err?.status === 404 || /Could not find the function|does not exist|schema cache/i.test(err?.message ?? '')) {
    hint = 'The database functions for this screen are not deployed yet. See IMPLEMENTATION_STATUS.md.';
  } else if (err?.status === 401 || err?.status === 403 || err?.code === '42501') {
    hint = 'Your account does not have access to this. Only the configured portfolio owner can use Quantum.';
  }
  return `<div class="panel error-panel"><h2>Couldn’t load this</h2><p>${esc(err?.message ?? String(e))}</p>${hint ? `<p class="muted">${esc(hint)}</p>` : ''}</div>`;
}

async function safe<T>(p: Promise<T>, fallback: T): Promise<[T, unknown]> {
  try { return [await p, null]; } catch (e) { return [fallback, e]; }
}

// ======================================================================
// Routes
// ======================================================================
async function overview({ db }: Ctx): Promise<string> {
  const o = await db.rpc<any>('portfolio_overview');
  const f = o.finance_gbp ?? {};
  const stop = o.controls?.emergency_stop?.active;
  const ai = o.controls?.ai_inference;
  const [notes] = await safe(db.select('notifications', 'select=id,title,body,priority,created_at,link&read_at=is.null&order=created_at.desc&limit=6'), []);
  const noFinance = n(f.settled_entries) === 0;
  return `
  ${header('Overview', `Updated ${esc(relativeTime(o.generated_at))}`, `<a class="btn" href="#/tasks/new">New command</a>`)}
  ${stop ? `<div class="banner bad"><strong>Emergency stop is active.</strong> No tasks are being executed. <a href="#/settings">Manage</a></div>` : ''}
  ${ai?.status !== 'available' ? `<div class="banner warn"><strong>AI execution unavailable.</strong> ${esc(ai?.note ?? 'No inference provider configured.')} System tasks still run.</div>` : ''}
  <section class="grid stats">
    ${stat('Businesses', String(n(o.businesses?.total)), `${n(o.businesses?.active)} active · ${n(o.businesses?.developing)} in development · ${n(o.businesses?.paused)} paused`)}
    ${stat('Verified revenue', money(f.gross_revenue_minor), noFinance ? 'No settled transactions recorded' : `Net ${money(f.net_revenue_minor)}`)}
    ${stat('Verified expenses', money(f.expenses_minor), 'Settled costs and fees')}
    ${stat('Operating profit', money(f.operating_profit_minor), 'Not the same as cash available')}
    ${stat('Pending payments', money(f.pending_minor), 'Not counted as revenue')}
    ${stat('Agents', String(n(o.agents?.total)), `${n(o.agents?.working)} working now · ${n(o.agents?.active)} enabled`)}
    ${stat('Tasks', String(n(o.tasks?.queued) + n(o.tasks?.running)), `${n(o.tasks?.running)} running · ${n(o.tasks?.queued)} queued`)}
    ${stat('Failed (7 days)', String(n(o.tasks?.failed_7d)), `${n(o.tasks?.completed_7d)} completed`)}
    ${stat('Pending approvals', String(n(o.approvals_pending)), `<a href="#/approvals">Review</a>`)}
  </section>
  <section class="grid two">
    <div class="panel"><h2>Unread notifications</h2>
      ${notes.length ? `<ul class="list">${notes.map((x: any) => `<li><div>${badge(x.priority === 'critical' || x.priority === 'high' ? 'pending' : 'neutral')} <strong>${esc(x.title)}</strong></div><div class="muted small">${esc(x.body ?? '')} · ${esc(relativeTime(x.created_at))}</div></li>`).join('')}</ul>`
        : empty('All clear', 'Nothing needs your attention.')}
    </div>
    <div class="panel"><h2>Recent orders</h2>
      ${(o.recent_orders ?? []).length ? table(['When', 'Status', 'Payment', 'Total'], o.recent_orders.map((r: any) => [esc(relativeTime(r.created_at)), badge(r.status), badge(r.payment_status), money(r.total_minor, r.currency)]))
        : empty('No orders yet', 'Orders appear here once a sales channel is connected and real orders arrive.')}
    </div>
  </section>`;
}

async function businesses({ db }: Ctx): Promise<string> {
  const [list, fin] = await Promise.all([
    db.select('businesses', 'select=id,name,slug,status,category,template_key,created_at&order=created_at.asc'),
    db.select('business_financials', 'select=business_id,currency,gross_revenue_minor,operating_profit_minor'),
  ]);
  const finBy = new Map(fin.map((f: any) => [f.business_id, f]));
  const cards = list.map((b: any) => {
    const f: any = finBy.get(b.id);
    return `<a class="card biz" href="#/business/${esc(b.id)}">
      <div class="card-top"><span class="biz-mark">${esc(b.name.slice(0, 1).toUpperCase())}</span>${badge(b.status)}</div>
      <h3>${esc(b.name)}</h3><p class="muted small">${esc(b.category ?? b.template_key ?? '')}</p>
      <div class="card-figs"><div><span class="muted small">Revenue</span><br>${money(f?.gross_revenue_minor ?? 0, f?.currency)}</div>
      <div><span class="muted small">Profit</span><br>${money(f?.operating_profit_minor ?? 0, f?.currency)}</div></div></a>`;
  }).join('');
  return `${header('Businesses', 'Every business in the portfolio, isolated from the others.', `<a class="btn" href="#/new-business">New business</a>`)}
    ${list.length ? `<section class="grid cards">${cards}</section>` : empty('No businesses yet', 'Create your first business with the Business Factory. It starts as a proposal; nothing launches without your approval.') + `<p class="center"><a class="btn" href="#/new-business">Create a business</a></p>`}`;
}

async function newBusiness({ db }: Ctx): Promise<string> {
  const templates = await db.select('business_templates', 'select=key,name,description,modules&order=name.asc');
  return `${header('New business', 'Business Factory: pick a template, and its modules are enabled automatically.')}
  <form class="panel form" data-action="create-business">
    <label>Business name<input name="name" required maxlength="120" autocomplete="off" placeholder="e.g. PocketOS"></label>
    <label>Short ID (URL-safe)<input name="slug" pattern="[a-z0-9][a-z0-9-]{1,62}" placeholder="auto from name"></label>
    <label>Template<select name="template" required>${templates.map((t: any) => `<option value="${esc(t.key)}">${esc(t.name)} — ${esc(t.description)}</option>`).join('')}</select></label>
    <label>Category<input name="category" placeholder="e.g. Consumer hardware"></label>
    <label>Description<textarea name="description" rows="3"></textarea></label>
    <p class="muted small">New businesses start as <strong>proposed</strong>. Launching is a separate, audited owner decision.</p>
    <div class="form-row"><button class="btn" type="submit">Create business</button><span class="form-msg" role="status"></span></div>
  </form>`;
}

async function business({ db }: Ctx, id: string): Promise<string> {
  const q = `business_id=eq.${encodeURIComponent(id)}`;
  const [[b], modules, agents, tasks, products, [fin], ledger] = await Promise.all([
    db.select('businesses', `select=*&id=eq.${encodeURIComponent(id)}`),
    db.select('business_modules', `select=module_key,enabled&${q}&order=module_key`),
    db.select('agent_status', `select=id,name,role,runtime_status,autonomy_level&${q}&order=name`),
    db.select('tasks', `select=id,title,kind,status,created_at&${q}&order=created_at.desc&limit=10`),
    db.select('products', `select=id,name,product_type,price_minor,currency,status&${q}&order=created_at`),
    db.select('business_financials', `select=*&${q}`),
    db.select('ledger_entries', `select=id,entry_type,amount_minor,currency,occurred_at,payment_status,source,category,description,is_test&${q}&order=occurred_at.desc&limit=20`),
  ]);
  if (!b) return empty('Business not found', 'It may not exist, or you may not have access to it.');
  const statuses = ['proposed', 'developing', 'active', 'paused', 'archived'];
  return `${header(b.name, `${esc(b.category ?? b.template_key)} · created ${esc(relativeTime(b.created_at))}`, badge(b.status))}
  ${b.description ? `<p class="lead">${esc(b.description)}</p>` : ''}
  <section class="grid stats">
    ${stat('Verified revenue', money(fin?.gross_revenue_minor ?? 0, fin?.currency))}
    ${stat('Expenses & fees', money(n(fin?.operating_expenses_minor) + n(fin?.payment_fees_minor), fin?.currency))}
    ${stat('Operating profit', money(fin?.operating_profit_minor ?? 0, fin?.currency))}
    ${stat('Pending', money(fin?.pending_minor ?? 0, fin?.currency), 'Not counted as revenue')}
  </section>
  <section class="grid two">
    <div class="panel"><h2>Status</h2>
      <p class="muted small">Changing status is an owner decision and is recorded in the audit log.</p>
      <div class="chip-row">${statuses.map((s) => `<button class="chip${s === b.status ? ' on' : ''}" data-action="set-status" data-id="${esc(b.id)}" data-status="${s}" ${s === b.status ? 'disabled' : ''}
        data-confirm="Change ${esc(b.name)} to ${s}?">${esc(label(s))}</button>`).join('')}</div>
      <h3>Modules</h3><div class="chip-row">${modules.map((m: any) => `<span class="chip static${m.enabled ? ' on' : ''}">${esc(m.module_key)}</span>`).join('')}</div>
    </div>
    <div class="panel"><h2>AI workforce</h2>
      ${agents.length ? `<ul class="list">${agents.map((a: any) => `<li><a href="#/agent/${esc(a.id)}"><strong>${esc(a.name)}</strong></a> <span class="muted small">${esc(a.role)}</span> ${badge(a.runtime_status)}</li>`).join('')}</ul>` : empty('No agents', 'Add only agents with a clear purpose.')}
      <form class="form compact" data-action="create-agent" data-business="${esc(b.id)}">
        <div class="form-grid"><label>Name<input name="name" required></label><label>Role<input name="role" required placeholder="e.g. Marketing"></label></div>
        <label>Responsibilities (one per line)<textarea name="resp" rows="2"></textarea></label>
        <div class="form-grid"><label>Model tier<select name="tier"><option>economical</option><option>lightweight</option><option>reasoning</option><option>writing</option><option>strategic</option></select></label>
        <label>Autonomy<select name="level"><option value="1">1 — internal work</option><option value="2">2 — low-risk reversible</option></select></label></div>
        <div class="form-row"><button class="btn small" type="submit">Add agent</button><span class="form-msg" role="status"></span></div>
      </form>
    </div>
  </section>
  <section class="grid two">
    <div class="panel"><h2>Products & services</h2>
      ${products.length ? table(['Name', 'Type', 'Price', 'Status'], products.map((p: any) => [esc(p.name), esc(p.product_type), money(p.price_minor, p.currency), badge(p.status)])) : empty('No products', 'Add the real products or services this business sells.')}
      <form class="form compact" data-action="create-product" data-business="${esc(b.id)}">
        <div class="form-grid"><label>Name<input name="name" required></label>
        <label>Type<select name="type"><option>physical</option><option>digital</option><option>service</option><option>subscription</option></select></label></div>
        <div class="form-grid"><label>Price (£)<input name="price" inputmode="decimal" placeholder="99.99"></label>
        <label>Status<select name="status"><option>draft</option><option>preorder</option><option>available</option><option>paused</option></select></label></div>
        <div class="form-row"><button class="btn small" type="submit">Add product</button><span class="form-msg" role="status"></span></div>
      </form>
    </div>
    <div class="panel"><h2>Recent tasks</h2>
      ${tasks.length ? `<ul class="list">${tasks.map((t: any) => `<li><a href="#/task/${esc(t.id)}">${esc(t.title)}</a> ${badge(t.status)} <span class="muted small">${esc(relativeTime(t.created_at))}</span></li>`).join('')}</ul>` : empty('No tasks', 'Issue a command for this business from Tasks.')}
    </div>
  </section>
  <section class="panel"><h2>Ledger</h2>
    ${ledger.length ? table(['Date', 'Type', 'Amount', 'Payment', 'Source', 'Note'], ledger.map((e: any) => [esc(new Date(e.occurred_at).toLocaleDateString('en-GB')), esc(label(e.entry_type)) + (e.is_test ? ' <span class="badge neutral">test</span>' : ''), money(e.amount_minor, e.currency), badge(e.payment_status), esc(e.source), esc(e.description ?? e.category ?? '')]))
      : empty('No transactions', 'Nothing has been recorded. Revenue appears only from settled, traceable transactions.')}
    <details><summary>Record a manual transaction</summary>
    <form class="form compact" data-action="ledger-entry" data-business="${esc(b.id)}">
      <div class="form-grid"><label>Type<select name="type"><option value="expense">Expense</option><option value="software_cost">Software cost</option><option value="advertising_cost">Advertising cost</option><option value="payment_fee">Payment fee</option><option value="revenue">Revenue</option><option value="refund">Refund</option><option value="tax">Tax</option></select></label>
      <label>Amount (£)<input name="amount" required inputmode="decimal"></label></div>
      <div class="form-grid"><label>Date<input name="date" type="date" required value="${new Date().toISOString().slice(0, 10)}"></label>
      <label>Payment status<select name="pstatus"><option value="settled">Settled</option><option value="pending">Pending</option></select></label></div>
      <div class="form-grid"><label>Reference (receipt / invoice no.)<input name="reference"></label><label>Description<input name="description" required></label></div>
      <label class="check"><input type="checkbox" name="is_test"> This is test data (excluded from all reports)</label>
      <p class="muted small">Ledger entries cannot be edited or deleted. Mistakes are corrected with an adjustment.</p>
      <div class="form-row"><button class="btn small" type="submit">Record</button><span class="form-msg" role="status"></span></div>
    </form></details>
  </section>`;
}

async function agents({ db }: Ctx): Promise<string> {
  const [list, biz] = await Promise.all([
    db.select('agent_status', 'select=id,name,role,scope,business_id,runtime_status,admin_state,model_tier,tasks_completed,tasks_failed,last_activity_at&order=scope,name'),
    db.select('businesses', 'select=id,name'),
  ]);
  const bn = new Map(biz.map((b: any) => [b.id, b.name]));
  return `${header('AI Workforce', 'Status is derived from real task execution: an agent only shows “working” while a task is running.')}
  ${list.length ? table(['Agent', 'Role', 'Scope', 'Status', 'Done', 'Failed', 'Last activity'], list.map((a: any) => [
      `<a href="#/agent/${esc(a.id)}"><strong>${esc(a.name)}</strong></a>`, esc(a.role), esc(a.business_id ? bn.get(a.business_id) ?? '—' : 'Portfolio'),
      badge(a.runtime_status), String(n(a.tasks_completed)), String(n(a.tasks_failed)), esc(relativeTime(a.last_activity_at))]))
    : empty('No agents yet', 'Agents are created per business (or at portfolio level) when there is real work for them. Open a business to add one.')}
  <details class="panel"><summary>Add a portfolio-level agent</summary>
  <form class="form compact" data-action="create-agent" data-business="">
    <div class="form-grid"><label>Name<input name="name" required placeholder="Chief Executive"></label><label>Role<input name="role" required placeholder="Chief Executive"></label></div>
    <label>Responsibilities (one per line)<textarea name="resp" rows="2"></textarea></label>
    <div class="form-grid"><label>Model tier<select name="tier"><option>strategic</option><option>reasoning</option><option>economical</option><option>lightweight</option><option>writing</option></select></label>
    <label>Autonomy<select name="level"><option value="1">1 — internal work</option><option value="2">2 — low-risk reversible</option></select></label></div>
    <div class="form-row"><button class="btn small" type="submit">Add agent</button><span class="form-msg" role="status"></span></div>
  </form></details>`;
}

async function agent({ db }: Ctx, id: string): Promise<string> {
  const [[a], tasks] = await Promise.all([
    db.select('agent_status', `select=*&id=eq.${encodeURIComponent(id)}`),
    db.select('tasks', `select=id,title,kind,status,attempts,created_at,completed_at,error&agent_id=eq.${encodeURIComponent(id)}&order=created_at.desc&limit=50`),
  ]);
  if (!a) return empty('Agent not found', '');
  const states = ['enabled', 'paused', 'disabled'];
  return `${header(a.name, `${esc(a.role)} · ${a.scope === 'portfolio' ? 'Portfolio scope' : 'Business scope'} · model tier ${esc(a.model_tier)} · autonomy level ${esc(a.autonomy_level)}`, badge(a.runtime_status))}
  <section class="panel"><h2>Responsibilities</h2>${(a.responsibilities ?? []).length ? `<ul>${a.responsibilities.map((r: string) => `<li>${esc(r)}</li>`).join('')}</ul>` : '<p class="muted">None defined.</p>'}
    <div class="chip-row">${states.map((s) => `<button class="chip${s === a.admin_state ? ' on' : ''}" data-action="agent-state" data-id="${esc(a.id)}" data-state="${s}" ${s === a.admin_state ? 'disabled' : ''}>${esc(label(s))}</button>`).join('')}</div></section>
  <section class="panel"><h2>Task history</h2>
  ${tasks.length ? table(['Task', 'Status', 'Attempts', 'Created', 'Finished', 'Error'], tasks.map((t: any) => [`<a href="#/task/${esc(t.id)}">${esc(t.title)}</a>`, badge(t.status), String(t.attempts), esc(relativeTime(t.created_at)), esc(relativeTime(t.completed_at)), esc(t.error?.message ?? '')]))
    : empty('No tasks yet', 'This agent has not been given any work.')}</section>`;
}

async function tasks({ db }: Ctx, sub?: string): Promise<string> {
  if (sub === 'new') return newTask({ db } as Ctx);
  const list = await db.select('tasks', 'select=id,title,kind,status,priority,attempts,business_id,created_at,completed_at&order=created_at.desc&limit=100');
  return `${header('Tasks', 'Every command and delegation is a persistent, traceable task.', `<a class="btn" href="#/tasks/new">New command</a>`)}
  ${list.length ? table(['Task', 'Kind', 'Status', 'Priority', 'Attempts', 'Created'], list.map((t: any) => [`<a href="#/task/${esc(t.id)}">${esc(t.title)}</a>`, `<code>${esc(t.kind)}</code>`, badge(t.status), String(t.priority), String(t.attempts), esc(relativeTime(t.created_at))]))
    : empty('No tasks yet', 'Issue a command to create the first task.')}`;
}

async function newTask({ db }: Ctx): Promise<string> {
  const [biz, ags] = await Promise.all([
    db.select('businesses', 'select=id,name&status=neq.archived&order=name'),
    db.select('agents', 'select=id,name,business_id&admin_state=eq.enabled&order=name'),
  ]);
  return `${header('Command', 'Tell Quantum what to do. It becomes a queued task with full history.')}
  <form class="panel form" data-action="enqueue">
    <label>Instruction<input name="title" required maxlength="200" placeholder="e.g. Research UK demand for smart-home gadgets"></label>
    <label>Type of work<select name="kind">${TASK_KINDS.map(([k, d]) => `<option value="${k}">${esc(d)}</option>`).join('')}</select></label>
    <div class="form-grid">
      <label>Business<select name="business"><option value="">Whole portfolio</option>${biz.map((b: any) => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('')}</select></label>
      <label>Assign to agent<select name="agent"><option value="">Unassigned</option>${ags.map((a: any) => `<option value="${esc(a.id)}" data-business="${esc(a.business_id ?? '')}">${esc(a.name)}</option>`).join('')}</select></label>
    </div>
    <label>Details<textarea name="description" rows="3"></textarea></label>
    <div class="form-grid"><label>Priority<select name="priority"><option value="50">Normal</option><option value="80">High</option><option value="20">Low</option></select></label>
    <label class="check"><input type="checkbox" name="approval"> Require my approval before it runs</label></div>
    <p class="muted small">System tasks run within a minute on the database scheduler. AI tasks stay queued until an inference provider is approved and connected; they are never simulated.</p>
    <div class="form-row"><button class="btn" type="submit">Queue task</button><span class="form-msg" role="status"></span></div>
  </form>`;
}

async function task({ db }: Ctx, id: string): Promise<string> {
  const [[t], events] = await Promise.all([
    db.select('tasks', `select=*&id=eq.${encodeURIComponent(id)}`),
    db.select('task_events', `select=from_status,to_status,detail,created_at&task_id=eq.${encodeURIComponent(id)}&order=id.asc`),
  ]);
  if (!t) return empty('Task not found', '');
  const open = !['completed', 'failed', 'cancelled'].includes(t.status);
  return `${header(t.title, `<code>${esc(t.kind)}</code> · priority ${esc(t.priority)} · attempt ${esc(t.attempts)}/${esc(t.max_attempts)}`,
    badge(t.status) + (open ? ` <button class="btn ghost small" data-action="cancel-task" data-id="${esc(t.id)}" data-confirm="Cancel this task?">Cancel</button>` : ''))}
  ${t.description ? `<p class="lead">${esc(t.description)}</p>` : ''}
  <section class="grid two">
    <div class="panel"><h2>Result</h2>${t.result ? `<pre>${esc(JSON.stringify(t.result, null, 2))}</pre>` : '<p class="muted">No result yet.</p>'}
      ${t.error ? `<h3>Error</h3><pre class="bad">${esc(JSON.stringify(t.error, null, 2))}</pre>` : ''}</div>
    <div class="panel"><h2>History</h2><ol class="timeline">${events.map((e: any) => `<li>${badge(e.to_status)} <span class="muted small">${esc(new Date(e.created_at).toLocaleString('en-GB'))}</span></li>`).join('')}</ol></div>
  </section>`;
}

async function approvals({ db }: Ctx): Promise<string> {
  const list = await db.select('approvals', 'select=*&order=created_at.desc&limit=100');
  const pending = list.filter((a: any) => a.status === 'pending');
  const done = list.filter((a: any) => a.status !== 'pending');
  const card = (a: any) => `<div class="panel approval">
    <div class="card-top"><h3>${esc(a.action)}</h3>${badge(a.status)}</div>
    <p>${esc(a.reason)}</p>
    <dl class="meta"><dt>Level</dt><dd>${esc(a.autonomy_level)}</dd>
      <dt>Financial impact</dt><dd>${a.financial_impact_minor != null ? money(a.financial_impact_minor, a.currency ?? 'GBP') : 'None stated'}</dd>
      ${a.risks ? `<dt>Risks</dt><dd>${esc(a.risks)}</dd>` : ''}
      <dt>Expires</dt><dd>${esc(relativeTime(a.expires_at))}</dd></dl>
    ${a.task_id ? `<p class="small"><a href="#/task/${esc(a.task_id)}">View task</a></p>` : ''}
    <div class="form-row"><button class="btn good" data-action="decide" data-id="${esc(a.id)}" data-approve="1" data-confirm="Approve: ${esc(a.action)}?">Approve</button>
    <button class="btn bad" data-action="decide" data-id="${esc(a.id)}" data-approve="0">Reject</button></div></div>`;
  return `${header('Approvals', 'Consequential actions wait here. Silence is never treated as approval; requests expire.')}
  ${pending.length ? `<section class="grid two">${pending.map(card).join('')}</section>` : empty('Nothing waiting', 'No actions need your decision.')}
  ${done.length ? `<section class="panel"><h2>History</h2>${table(['Action', 'Decision', 'When', 'Note'], done.map((a: any) => [esc(a.action), badge(a.status), esc(relativeTime(a.decided_at)), esc(a.decision_note ?? '')]))}</section>` : ''}`;
}

async function finance({ db }: Ctx): Promise<string> {
  const fin = await db.select('business_financials', 'select=*&order=name');
  const withData = fin.filter((f: any) => n(f.settled_entries) > 0 || n(f.pending_minor) > 0);
  return `${header('Finance', 'Actuals only: settled, non-test, traceable ledger entries. Forecasts are never mixed in.')}
  ${fin.length ? table(['Business', 'Gross revenue', 'Refunds', 'Net revenue', 'Fees', 'Expenses', 'Operating profit', 'Pending'],
      fin.map((f: any) => [`<a href="#/business/${esc(f.business_id)}">${esc(f.name)}</a>`, money(f.gross_revenue_minor, f.currency), money(f.refunds_minor, f.currency), money(f.net_revenue_minor, f.currency),
        money(f.payment_fees_minor, f.currency), money(f.operating_expenses_minor, f.currency), `<strong>${money(f.operating_profit_minor, f.currency)}</strong>`, money(f.pending_minor, f.currency)]), 'num')
    : empty('No businesses', 'Create a business first.')}
  ${fin.length && !withData.length ? `<p class="muted">No transactions have been recorded yet, so every figure is £0.00.</p>` : ''}
  <p class="muted small">Operating profit is not cash in the bank. Tax entries are recorded but not netted here.</p>`;
}

async function notifications({ db }: Ctx): Promise<string> {
  const list = await db.select('notifications', 'select=*&order=created_at.desc&limit=100');
  return `${header('Notifications', '', list.some((x: any) => !x.read_at) ? `<button class="btn ghost" data-action="read-all">Mark all read</button>` : '')}
  ${list.length ? `<ul class="list panel">${list.map((x: any) => `<li class="${x.read_at ? 'read' : ''}"><div>${badge(x.priority === 'critical' ? 'failed' : x.priority === 'high' ? 'pending' : 'neutral')} <strong>${esc(x.title)}</strong> <span class="muted small">${esc(x.category)} · ${esc(relativeTime(x.created_at))}</span></div>${x.body ? `<div class="small">${esc(x.body)}</div>` : ''}</li>`).join('')}</ul>`
    : empty('No notifications', 'Failures, approvals, sales and security events will appear here.')}`;
}

async function integrations({ db }: Ctx): Promise<string> {
  const list = await db.select('service_register', 'select=*&order=service');
  return `${header('Integrations & costs', 'Live register of every service Quantum uses or could use. Starting budget: £0.')}
  <section class="panel">${table(['Service', 'Purpose', 'Plan', 'Free allowance', 'Restrictions', 'Potential cost', 'Status'], list.map((s: any) => [
    `<strong>${esc(s.service)}</strong>${s.owner_decision_required ? '<br><span class="badge warn">Owner decision</span>' : ''}`, esc(s.purpose), esc(s.current_plan),
    esc(s.free_allowance ?? '—'), esc(s.known_restrictions ?? '—'), esc(s.potential_cost ?? '—'), badge(s.status)]))}</section>`;
}

async function settings({ db }: Ctx): Promise<string> {
  const [controls, audit] = await Promise.all([
    db.select('system_controls', 'select=key,value,updated_at'),
    db.select('audit_log', 'select=actor_type,action,entity,entity_id,created_at&order=created_at.desc&limit=30'),
  ]);
  const c = Object.fromEntries(controls.map((x: any) => [x.key, x.value]));
  const stop = c.emergency_stop?.active === true;
  return `${header('System')}
  <section class="panel ${stop ? 'danger' : ''}"><h2>Emergency stop</h2>
    <p>${stop ? `<strong>Active.</strong> ${esc(c.emergency_stop?.reason ?? '')} No background tasks are being claimed.` : 'Inactive. Background execution is running normally.'}</p>
    <form class="form-row" data-action="emergency">
      <input type="hidden" name="active" value="${stop ? '0' : '1'}">
      ${stop ? '' : '<input name="reason" placeholder="Reason (optional)">'}
      <button class="btn ${stop ? 'good' : 'bad'}" type="submit">${stop ? 'Release emergency stop' : 'Activate emergency stop'}</button><span class="form-msg" role="status"></span>
    </form></section>
  <section class="grid two">
    <div class="panel"><h2>Execution limits</h2><dl class="meta">${Object.entries(c.limits ?? {}).map(([k, v]) => `<dt>${esc(label(k))}</dt><dd>${esc(v)}</dd>`).join('')}</dl></div>
    <div class="panel"><h2>AI inference</h2><p>${badge(c.ai_inference?.status)}</p><p class="muted small">${esc(c.ai_inference?.note ?? '')}</p></div>
  </section>
  <section class="panel"><h2>Audit log</h2>${audit.length ? table(['When', 'Actor', 'Action', 'Entity'], audit.map((a: any) => [esc(relativeTime(a.created_at)), esc(a.actor_type), esc(a.action), `${esc(a.entity)} <span class="muted small">${esc((a.entity_id ?? '').slice(0, 8))}</span>`])) : empty('Empty', 'No audited actions yet.')}</section>`;
}

function login(): string {
  return `<div class="center-card">
    <div class="brand big"><span class="brand-mark">Q</span><span class="brand-name">Quantum</span></div>
    <p class="muted">Portfolio command centre</p>
    <form class="form" data-action="sign-in">
      <label>Email<input name="email" type="email" required autocomplete="username"></label>
      <label>Password<input name="password" type="password" required minlength="8" autocomplete="current-password"></label>
      <div class="form-row"><button class="btn" type="submit">Sign in</button><button class="btn ghost" type="submit" name="mode" value="signup" formnovalidate>Create owner account</button></div>
      <span class="form-msg" role="status"></span>
    </form>
    <p class="muted small">Only the configured owner email receives access. Other accounts see nothing.</p>
  </div>`;
}

// ======================================================================
// Form & click handlers
// ======================================================================
const forms = {
  async 'sign-in'({ db }: Ctx, f: FormData, el: HTMLFormElement) {
    const email = String(f.get('email') ?? '').trim(); const password = String(f.get('password') ?? '');
    if (el.dataset.mode === 'signup') {
      if (password.length < 8) throw new Error('Use a password of at least 8 characters.');
      const r = await db.signUp(email, password, location.origin + location.pathname);
      return r === 'confirm' ? 'Check your email to confirm the account, then sign in.' : undefined;
    }
    await db.signIn(email, password);
    return undefined;
  },
  async 'create-business'({ db }: Ctx, f: FormData) {
    const name = String(f.get('name')).trim();
    const slug = String(f.get('slug') || '').trim() || slugify(name);
    const id = await db.rpc<string>('create_business', { p_name: name, p_slug: slug, p_template_key: f.get('template'),
      p_description: f.get('description') || null, p_category: f.get('category') || null });
    location.hash = `#/business/${id}`;
  },
  async 'create-agent'({ db, rerender }: Ctx, f: FormData, el: HTMLFormElement) {
    const resp = String(f.get('resp') ?? '').split('\n').map((s) => s.trim()).filter(Boolean);
    await db.rpc('create_agent', { p_business: el.dataset.business || null, p_name: f.get('name'), p_role: f.get('role'),
      p_responsibilities: resp, p_autonomy_level: Number(f.get('level') ?? 1), p_model_tier: f.get('tier') });
    await rerender();
  },
  async 'create-product'({ db, rerender }: Ctx, f: FormData, el: HTMLFormElement) {
    const priceRaw = String(f.get('price') ?? '').trim();
    const price = priceRaw ? parseMoneyToMinor(priceRaw) : null;
    if (priceRaw && price === null) throw new Error('Enter a price like 99.99');
    await db.insert('products', { business_id: el.dataset.business, name: f.get('name'), product_type: f.get('type'), price_minor: price, status: f.get('status') });
    await rerender();
  },
  async 'ledger-entry'({ db, rerender }: Ctx, f: FormData, el: HTMLFormElement) {
    const amount = parseMoneyToMinor(String(f.get('amount') ?? ''));
    if (amount === null) throw new Error('Enter an amount like 12.50');
    await db.rpc('record_manual_ledger_entry', { p_business: el.dataset.business, p_entry_type: f.get('type'), p_amount_minor: amount,
      p_occurred_at: new Date(String(f.get('date'))).toISOString(), p_payment_status: f.get('pstatus'),
      p_description: f.get('description'), p_reference: f.get('reference') || null, p_is_test: f.get('is_test') === 'on' });
    await rerender();
  },
  async enqueue({ db }: Ctx, f: FormData) {
    const approval = f.get('approval') === 'on';
    const id = await db.rpc<string>('enqueue_task', { p_business: f.get('business') || null, p_agent: f.get('agent') || null,
      p_kind: f.get('kind'), p_title: String(f.get('title')).trim(), p_description: f.get('description') || null,
      p_priority: Number(f.get('priority') ?? 50), p_requires_approval: approval,
      p_approval_reason: approval ? 'Owner requested approval before execution' : null });
    location.hash = `#/task/${id}`;
  },
  async emergency({ db, rerender }: Ctx, f: FormData) {
    const active = f.get('active') === '1';
    if (!window.confirm(active ? 'Stop all background execution now?' : 'Resume background execution?')) return;
    await db.rpc('set_emergency_stop', { p_active: active, p_reason: f.get('reason') || null });
    await rerender();
  },
};

const clicks = {
  async 'set-status'({ db, rerender }: Ctx, el: HTMLElement) {
    await db.rpc('set_business_status', { p_business: el.dataset.id, p_status: el.dataset.status }); await rerender();
  },
  async 'agent-state'({ db, rerender }: Ctx, el: HTMLElement) {
    await db.rpc('set_agent_state', { p_agent: el.dataset.id, p_state: el.dataset.state }); await rerender();
  },
  async 'cancel-task'({ db, rerender }: Ctx, el: HTMLElement) {
    await db.rpc('cancel_task', { p_task: el.dataset.id, p_reason: 'cancelled by owner' }); await rerender();
  },
  async decide({ db, rerender }: Ctx, el: HTMLElement) {
    const approve = el.dataset.approve === '1';
    const note = approve ? null : window.prompt('Reason for rejecting (optional)') ?? null;
    await db.rpc('decide_approval', { p_approval: el.dataset.id, p_approve: approve, p_note: note }); await rerender();
  },
  async 'read-all'({ db, rerender }: Ctx) {
    await db.update('notifications', 'read_at=is.null', { read_at: new Date().toISOString() }); await rerender();
  },
};

export const views = {
  login,
  routes: { overview, businesses, 'new-business': newBusiness, business, agents, agent, tasks, task, approvals, finance, notifications, integrations, settings },
  forms, clicks,
};
