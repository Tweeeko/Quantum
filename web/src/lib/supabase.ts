// Minimal, dependency-free Supabase client: Auth (password), PostgREST, RPC.
// Only the publishable key is used client-side. Every data rule is enforced
// by Postgres RLS, so this client is deliberately thin.

export interface Session {
  access_token: string;
  refresh_token: string;
  expires_at: number; // epoch seconds
  user: { id: string; email?: string };
}

export class ApiError extends Error {
  constructor(message: string, readonly status: number, readonly code?: string) { super(message); }
}

type Fetch = typeof fetch;

export interface StorageLike {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
  removeItem(k: string): void;
}

const SESSION_KEY = 'quantum.session';

export class SupabaseClient {
  private session: Session | null = null;
  private listeners = new Set<(s: Session | null) => void>();

  constructor(readonly url: string, private readonly key: string,
              private readonly storage: StorageLike, private readonly fetchImpl: Fetch = fetch.bind(globalThis)) {
    try {
      const raw = storage.getItem(SESSION_KEY);
      this.session = raw ? (JSON.parse(raw) as Session) : null;
    } catch { this.session = null; }
  }

  onAuthChange(fn: (s: Session | null) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  get currentSession(): Session | null { return this.session; }

  private setSession(s: Session | null): void {
    this.session = s;
    try {
      if (s) this.storage.setItem(SESSION_KEY, JSON.stringify(s)); else this.storage.removeItem(SESSION_KEY);
    } catch { /* storage unavailable: session lives in memory only */ }
    this.listeners.forEach((fn) => fn(s));
  }

  private async raw(path: string, init: RequestInit & { auth?: boolean } = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set('apikey', this.key);
    if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
    if (init.auth !== false) {
      const token = await this.accessToken();
      if (token) headers.set('Authorization', `Bearer ${token}`);
    }
    return this.fetchImpl(this.url + path, { ...init, headers });
  }

  private static async fail(res: Response): Promise<never> {
    let msg = `${res.status} ${res.statusText}`;
    let code: string | undefined;
    try {
      const body = await res.json() as Record<string, string>;
      msg = body.message || body.msg || body.error_description || body.error || msg;
      code = body.code || body.error_code;
    } catch { /* non-JSON error body */ }
    throw new ApiError(msg, res.status, code);
  }

  // ---------------- Auth ----------------
  private toSession(body: any): Session {
    return {
      access_token: body.access_token,
      refresh_token: body.refresh_token,
      expires_at: body.expires_at ?? Math.floor(Date.now() / 1000) + (body.expires_in ?? 3600),
      user: { id: body.user?.id, email: body.user?.email },
    };
  }

  async signIn(email: string, password: string): Promise<Session> {
    const res = await this.raw('/auth/v1/token?grant_type=password', {
      method: 'POST', auth: false, body: JSON.stringify({ email, password }),
    });
    if (!res.ok) await SupabaseClient.fail(res);
    const s = this.toSession(await res.json());
    this.setSession(s);
    return s;
  }

  /** Returns 'session' if signed in immediately, or 'confirm' if email confirmation is required. */
  async signUp(email: string, password: string, redirectTo?: string): Promise<'session' | 'confirm'> {
    const q = redirectTo ? `?redirect_to=${encodeURIComponent(redirectTo)}` : '';
    const res = await this.raw('/auth/v1/signup' + q, { method: 'POST', auth: false, body: JSON.stringify({ email, password }) });
    if (!res.ok) await SupabaseClient.fail(res);
    const body = await res.json();
    if (body.access_token) { this.setSession(this.toSession(body)); return 'session'; }
    return 'confirm';
  }

  /** Handle the #access_token=... fragment Supabase appends after email confirmation. */
  consumeRedirectFragment(hash: string): boolean {
    if (!hash.includes('access_token=')) return false;
    const p = new URLSearchParams(hash.replace(/^#/, ''));
    const access = p.get('access_token'); const refresh = p.get('refresh_token');
    if (!access || !refresh) return false;
    let user = { id: '', email: undefined as string | undefined };
    try { const claims = JSON.parse(atob(access.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); user = { id: claims.sub, email: claims.email }; } catch { /* ignore */ }
    this.setSession({ access_token: access, refresh_token: refresh,
      expires_at: Number(p.get('expires_at')) || Math.floor(Date.now() / 1000) + Number(p.get('expires_in') || 3600), user });
    return true;
  }

  async signOut(): Promise<void> {
    const s = this.session;
    this.setSession(null);
    if (s) { try { await this.fetchImpl(this.url + '/auth/v1/logout', { method: 'POST', headers: { apikey: this.key, Authorization: `Bearer ${s.access_token}` } }); } catch { /* best effort */ } }
  }

  private refreshing: Promise<void> | null = null;
  async accessToken(): Promise<string | null> {
    const s = this.session;
    if (!s) return null;
    if (s.expires_at - 60 > Date.now() / 1000) return s.access_token;
    this.refreshing ??= (async () => {
      const res = await this.fetchImpl(this.url + '/auth/v1/token?grant_type=refresh_token', {
        method: 'POST', headers: { apikey: this.key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: s.refresh_token }) });
      if (!res.ok) { this.setSession(null); return; }
      this.setSession(this.toSession(await res.json()));
    })().finally(() => { this.refreshing = null; });
    await this.refreshing;
    return this.session?.access_token ?? null;
  }

  // ---------------- Data ----------------
  /** GET /rest/v1/<table>?<query>. Query is a PostgREST query string. */
  async select<T = any>(table: string, query = 'select=*'): Promise<T[]> {
    const res = await this.raw(`/rest/v1/${encodeURIComponent(table)}?${query}`);
    if (!res.ok) await SupabaseClient.fail(res);
    return res.json() as Promise<T[]>;
  }

  async insert<T = any>(table: string, row: Record<string, unknown>): Promise<T> {
    const res = await this.raw(`/rest/v1/${encodeURIComponent(table)}`, {
      method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify(row) });
    if (!res.ok) await SupabaseClient.fail(res);
    return (await res.json() as T[])[0];
  }

  async update(table: string, filter: string, patch: Record<string, unknown>): Promise<void> {
    const res = await this.raw(`/rest/v1/${encodeURIComponent(table)}?${filter}`, {
      method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(patch) });
    if (!res.ok) await SupabaseClient.fail(res);
  }

  async rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    const res = await this.raw(`/rest/v1/rpc/${encodeURIComponent(fn)}`, { method: 'POST', body: JSON.stringify(args) });
    if (!res.ok) await SupabaseClient.fail(res);
    const text = await res.text();
    return (text ? JSON.parse(text) : null) as T;
  }
}
