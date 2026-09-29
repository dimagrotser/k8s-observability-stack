import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import request from 'supertest';

import { buildTestApp, counterValue } from './helpers.js';

describe('RED metrics', () => {
  it('counts a successful request with the matched route template', async () => {
    const { app, metrics } = buildTestApp();

    await request(app).get('/api/items').expect(200);

    const value = await counterValue(metrics, 'http_requests_total', {
      route: '/api/items',
      method: 'GET',
      status: '200',
    });

    assert.equal(value, 1);
  });

  it('labels unmatched paths as "unmatched" instead of the raw URL', async () => {
    const { app, metrics } = buildTestApp();

    await request(app).get('/definitely/not/a/route').expect(404);

    const unmatched = await counterValue(metrics, 'http_requests_total', {
      route: 'unmatched',
      method: 'GET',
      status: '404',
    });
    assert.equal(unmatched, 1);

    const series = await metrics.registry.getMetricsAsJSON();
    const routes = series
      .find((m) => m.name === 'http_requests_total')
      .values.map((v) => v.labels.route);

    assert.ok(
      !routes.some((route) => route.includes('definitely')),
      'raw URL leaked into the route label',
    );
  });

  it('counts 5xx responses in http_request_errors_total', async () => {
    const { app, metrics } = buildTestApp({ env: { ERROR_RATE: '1' } });

    await request(app).get('/api/items').expect(500);

    const labels = { route: '/api/items', method: 'GET', status: '500' };
    assert.equal(await counterValue(metrics, 'http_request_errors_total', labels), 1);
    assert.equal(await counterValue(metrics, 'http_requests_total', labels), 1);
  });

  it('does not count successful responses as errors', async () => {
    const { app, metrics } = buildTestApp();

    await request(app).get('/api/items').expect(200);

    const all = await metrics.registry.getMetricsAsJSON();
    const errors = all.find((m) => m.name === 'http_request_errors_total');

    assert.equal(errors.values.length, 0);
  });

  it('records latency in the duration histogram', async () => {
    const { app, metrics } = buildTestApp();

    await request(app).get('/health').expect(200);

    const all = await metrics.registry.getMetricsAsJSON();
    const histogram = all.find((m) => m.name === 'http_request_duration_seconds');
    const count = histogram.values.find(
      (v) => v.metricName === 'http_request_duration_seconds_count' && v.labels.route === '/health',
    );

    assert.equal(count.value, 1);
  });

  it('exposes default process metrics for the USE dashboard', async () => {
    const { metrics } = buildTestApp();

    const text = await metrics.registry.metrics();
    assert.match(text, /process_resident_memory_bytes/);
    assert.match(text, /nodejs_eventloop_lag_seconds/);
  });
});
