import { test } from 'node:test';
import assert from 'node:assert/strict';
import { esc, money, parseMoneyToMinor, relativeTime, slugify, statusTone, label } from '../../web/dist/app/lib/format.js';

test('esc neutralises HTML injection', () => {
  assert.equal(esc('<img src=x onerror="alert(1)">'), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;');
  assert.equal(esc("it's"), 'it&#39;s');
  assert.equal(esc(null), '');
  assert.equal(esc(undefined), '');
});

test('money formats minor units and never invents values', () => {
  assert.equal(money(9999), '£99.99');
  assert.equal(money(0), '£0.00');
  assert.equal(money('150000'), '£1,500.00');
  assert.equal(money(null), '—');
  assert.equal(money(undefined), '—');
  assert.equal(money('abc'), '—');
  assert.equal(money(500, 'USD'), 'US$5.00');
});

test('parseMoneyToMinor is exact (no float drift)', () => {
  assert.equal(parseMoneyToMinor('99.99'), 9999);
  assert.equal(parseMoneyToMinor('0.1'), 10);
  assert.equal(parseMoneyToMinor('£1,250'), 125000);
  assert.equal(parseMoneyToMinor('19.995'), null);
  assert.equal(parseMoneyToMinor('-5'), null);
  assert.equal(parseMoneyToMinor('abc'), null);
  assert.equal(parseMoneyToMinor(''), null);
});

test('relativeTime', () => {
  const now = new Date('2026-11-05T12:00:00Z');
  assert.equal(relativeTime('2026-11-05T11:59:50Z', now), 'just now');
  assert.equal(relativeTime('2026-11-05T11:50:00Z', now), '10 min ago');
  assert.equal(relativeTime('2026-11-05T09:00:00Z', now), '3 h ago');
  assert.equal(relativeTime('2026-11-12T12:00:00Z', now), '7 d from now');
  assert.equal(relativeTime(null, now), '—');
  assert.equal(relativeTime('nonsense', now), '—');
});

test('slugify matches the database slug constraint', () => {
  const re = /^[a-z0-9][a-z0-9-]{1,62}$/;
  for (const name of ['PocketOS', 'Leeeko LTD', 'Café Crème!', '  Spaces  everywhere  ']) {
    assert.match(slugify(name), re, name);
  }
  assert.equal(slugify('Café Crème!'), 'cafe-creme');
});

test('status tones', () => {
  assert.equal(statusTone('completed'), 'good');
  assert.equal(statusTone('failed'), 'bad');
  assert.equal(statusTone('awaiting_approval'), 'warn');
  assert.equal(statusTone('working'), 'info');
  assert.equal(statusTone('something_new'), 'neutral');
  assert.equal(label('awaiting_approval'), 'Awaiting approval');
});
