import { createApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { createMetrics } from '../src/metrics.js';

/**
 * Builds an isolated app instance. Each test gets its own metrics registry so
 * counters from one test never leak into the assertions of another.
 */
export function buildTestApp({ env = {}, ready = true } = {}) {
  const config = loadConfig({ ...env });
  const metrics = createMetrics();
  const state = { ready };
  const app = createApp({ config, metrics, state });

  return { app, config, metrics, state };
}

/** Reads a single counter sample out of the registry by name and labels. */
export async function counterValue(metrics, name, labels) {
  const all = await metrics.registry.getMetricsAsJSON();
  const metric = all.find((m) => m.name === name);
  if (!metric) {
    return 0;
  }

  const sample = metric.values.find((v) =>
    Object.entries(labels).every(([key, value]) => v.labels[key] === value),
  );

  return sample ? sample.value : 0;
}
