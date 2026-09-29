import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import request from 'supertest';

import { buildTestApp } from './helpers.js';

describe('routes', () => {
  it('GET /health always returns 200', async () => {
    const { app } = buildTestApp({ ready: false });

    const res = await request(app).get('/health').expect(200);
    assert.deepEqual(res.body, { status: 'ok' });
  });

  it('GET /ready returns 503 while warming up and 200 once ready', async () => {
    const { app, state } = buildTestApp({ ready: false });

    await request(app).get('/ready').expect(503);

    state.ready = true;
    const res = await request(app).get('/ready').expect(200);
    assert.deepEqual(res.body, { status: 'ready' });
  });

  it('GET /api/items returns the item list', async () => {
    const { app } = buildTestApp();

    const res = await request(app).get('/api/items').expect(200);
    assert.equal(res.body.items.length, 3);
    assert.equal(res.body.items[0].name, 'widget');
  });

  it('GET /api/items fails when ERROR_RATE is 1', async () => {
    const { app } = buildTestApp({ env: { ERROR_RATE: '1' } });

    const res = await request(app).get('/api/items').expect(500);
    assert.equal(res.body.error, 'injected failure');
  });

  it('GET /api/items waits for EXTRA_LATENCY_MS', async () => {
    const { app } = buildTestApp({ env: { EXTRA_LATENCY_MS: '120' } });

    const startedAt = Date.now();
    await request(app).get('/api/items').expect(200);

    assert.ok(Date.now() - startedAt >= 110, 'response came back too fast');
  });

  it('GET /metrics exposes the Prometheus text format', async () => {
    const { app } = buildTestApp();

    const res = await request(app).get('/metrics').expect(200);
    assert.match(res.headers['content-type'], /text\/plain/);
    assert.match(res.text, /# HELP http_requests_total/);
  });

  it('unknown paths return a JSON 404', async () => {
    const { app } = buildTestApp();

    const res = await request(app).get('/nope').expect(404);
    assert.deepEqual(res.body, { error: 'not found' });
  });
});
