import { test } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import Database from 'better-sqlite3';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ownerMetricsRoutes, ownerSighting } from '../server/owner-metrics.js';

const KEY = 'k'.repeat(40);
async function serve(t, env) {
  const app = express(); ownerMetricsRoutes(app, env);
  const server = app.listen(0, '127.0.0.1'); await new Promise(r => server.once('listening', r));
  t.after(() => server.close());
  return (q = '', key) => fetch(`http://127.0.0.1:${server.address().port}/api/owner/metrics${q}`, { headers: key ? { 'X-Metrics-Key': key } : {} });
}

test('metrics are hidden without the right key and served by range with it', async t => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mm-')), file = path.join(dir, 'm.json');
  writeFileSync(file, JSON.stringify({ generated_at: 'g', search_models: { last7: { s0: 2, s4: 1 } },
    ranges: { all: { app: { devices: 3 } }, today: { app: { devices: 1 } } } }));
  const get = await serve(t, { METRICS_KEY: KEY, METRICS_FILE: file });
  assert.equal((await get('', null)).status, 404);
  assert.equal((await get('', 'wrong')).status, 404);
  const today = await (await get('?range=today', KEY)).json();
  assert.equal(today.app.devices, 1);
  assert.equal(today.search_models.last7.s0, 2, 'S0/S4 devices ride along whatever the range');
  const bogus = await (await get('?range=__proto__', KEY)).json();
  assert.equal(bogus.range, 'all'); assert.equal(bogus.app.devices, 3);
});

test('a short or missing key disables the route entirely', async t => {
  for (const METRICS_KEY of [undefined, '', 'short']) {
    const get = await serve(t, { METRICS_KEY, METRICS_FILE: '/nonexistent' });
    assert.equal((await get('', METRICS_KEY || '')).status, 404);
  }
});

test('only the owner account leaves a sighting', () => {
  const db = new Database(':memory:'), saw = ownerSighting(db, { OWNER_EMAILS: 'Owner@Example.test' });
  saw('someone@example.test', '1.1.1.1'); saw('owner@example.test', '2.2.2.2'); saw('owner@example.test', '2.2.2.2');
  assert.deepEqual(db.prepare('SELECT ip FROM owner_sightings').all(), [{ ip: '2.2.2.2' }]);
});

test('the shopper roster needs the same key as the metrics', async t => {
  const dir = mkdtempSync(path.join(tmpdir(), 'mm-')), file = path.join(dir, 'm.json');
  writeFileSync(file, JSON.stringify({ generated_at: 'g', ranges: {}, users: [{ email: 'a@example.test', orders: 1 }] }));
  const app = express(); ownerMetricsRoutes(app, { METRICS_KEY: KEY, METRICS_FILE: file });
  const server = app.listen(0, '127.0.0.1'); await new Promise(r => server.once('listening', r));
  t.after(() => server.close());
  const get = key => fetch(`http://127.0.0.1:${server.address().port}/api/owner/users`, { headers: key ? { 'X-Metrics-Key': key } : {} });
  assert.equal((await get(null)).status, 404);
  assert.equal((await get('wrong')).status, 404);
  const ok = await get(KEY);
  assert.equal(ok.headers.get('cache-control'), 'no-store');
  assert.deepEqual((await ok.json()).users, [{ email: 'a@example.test', orders: 1 }]);
});
