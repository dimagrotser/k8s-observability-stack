import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  it('uses safe defaults when nothing is set', () => {
    const config = loadConfig({});

    assert.equal(config.port, 8080);
    assert.equal(config.errorRate, 0);
    assert.equal(config.extraLatencyMs, 0);
    assert.equal(config.readyDelayMs, 0);
  });

  it('clamps ERROR_RATE into the 0..1 range', () => {
    assert.equal(loadConfig({ ERROR_RATE: '0.25' }).errorRate, 0.25);
    assert.equal(loadConfig({ ERROR_RATE: '-1' }).errorRate, 0);
    assert.equal(loadConfig({ ERROR_RATE: '2' }).errorRate, 1);
  });

  it('falls back to the default on unparseable values', () => {
    assert.equal(loadConfig({ ERROR_RATE: 'abc' }).errorRate, 0);
    assert.equal(loadConfig({ EXTRA_LATENCY_MS: '' }).extraLatencyMs, 0);
    assert.equal(loadConfig({ PORT: 'not-a-port' }).port, 8080);
  });

  it('parses EXTRA_LATENCY_MS as a non-negative integer', () => {
    assert.equal(loadConfig({ EXTRA_LATENCY_MS: '150' }).extraLatencyMs, 150);
    assert.equal(loadConfig({ EXTRA_LATENCY_MS: '-5' }).extraLatencyMs, 0);
  });
});
