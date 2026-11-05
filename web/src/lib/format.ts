// Pure formatting helpers. No DOM access; unit-tested in tests/unit.

const ESCAPES: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

/** Escape any value for safe interpolation into HTML text or attributes. */
export function esc(value: unknown): string {
  if (value === null || value === undefined) return '';
  return String(value).replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

/** Format integer minor units (e.g. pence) as currency. Never invents a value. */
export function money(minor: number | string | null | undefined, currency = 'GBP'): string {
  if (minor === null || minor === undefined || minor === '') return '—';
  const n = typeof minor === 'string' ? Number(minor) : minor;
  if (!Number.isFinite(n)) return '—';
  return new Intl.NumberFormat('en-GB', { style: 'currency', currency }).format(n / 100);
}

/** Parse a user-typed amount like "99.99" or "£1,250" into integer minor units. */
export function parseMoneyToMinor(input: string): number | null {
  const cleaned = input.replace(/[£$€,\s]/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(cleaned)) return null;
  const [whole, frac = ''] = cleaned.split('.');
  return Number(whole) * 100 + Number(frac.padEnd(2, '0'));
}

export function relativeTime(iso: string | null | undefined, now: Date = new Date()): string {
  if (!iso) return '—';
  const then = new Date(iso);
  const s = Math.round((now.getTime() - then.getTime()) / 1000);
  if (!Number.isFinite(s)) return '—';
  const abs = Math.abs(s);
  const suffix = s >= 0 ? 'ago' : 'from now';
  if (abs < 45) return s >= 0 ? 'just now' : 'in a moment';
  if (abs < 3600) return `${Math.round(abs / 60)} min ${suffix}`;
  if (abs < 86400) return `${Math.round(abs / 3600)} h ${suffix}`;
  if (abs < 86400 * 30) return `${Math.round(abs / 86400)} d ${suffix}`;
  return then.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

export function slugify(name: string): string {
  return name.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 63);
}

export type Tone = 'neutral' | 'good' | 'warn' | 'bad' | 'info';

/** Map any Quantum status to a visual tone. Unknown statuses are neutral. */
export function statusTone(status: string | null | undefined): Tone {
  switch (status) {
    case 'active': case 'completed': case 'approved': case 'settled': case 'reconciled': case 'published': case 'enabled': case 'in_use':
      return 'good';
    case 'working': case 'running': case 'queued': case 'scheduled': case 'developing': case 'proposed': case 'available':
      return 'info';
    case 'awaiting_approval': case 'pending': case 'paused': case 'drafted': case 'unreconciled':
      return 'warn';
    case 'failed': case 'rejected': case 'expired': case 'disabled': case 'blocked': case 'disputed': case 'reversed':
      return 'bad';
    default:
      return 'neutral';
  }
}

export function label(status: string | null | undefined): string {
  if (!status) return '—';
  return status.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
}
