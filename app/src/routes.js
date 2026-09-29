const ITEMS = [
  { id: 1, name: 'widget', price: 9.99 },
  { id: 2, name: 'gadget', price: 24.5 },
  { id: 3, name: 'gizmo', price: 149.0 },
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Chaos is applied to business endpoints only. If it also hit /health, a high
 * ERROR_RATE would restart the pod and the demo would show PodCrashLooping
 * instead of the HighErrorRate alert we actually want to demonstrate.
 */
async function applyChaos(config) {
  if (config.extraLatencyMs > 0) {
    await sleep(config.extraLatencyMs);
  }

  return config.errorRate > 0 && Math.random() < config.errorRate;
}

export function registerRoutes(app, { config, metrics, state }) {
  // Liveness: answers as long as the event loop is alive. Deliberately has no
  // dependencies, so a liveness failure always means "restart me".
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok' });
  });

  // Readiness: gates traffic. Goes red during warm-up and during shutdown.
  app.get('/ready', (_req, res) => {
    if (!state.ready) {
      res.status(503).json({ status: 'not-ready' });
      return;
    }

    res.json({ status: 'ready' });
  });

  app.get('/api/items', async (_req, res, next) => {
    try {
      const shouldFail = await applyChaos(config);

      if (shouldFail) {
        res.status(500).json({ error: 'injected failure' });
        return;
      }

      res.json({ items: ITEMS });
    } catch (err) {
      next(err);
    }
  });

  app.get('/metrics', async (_req, res, next) => {
    try {
      res.set('Content-Type', metrics.registry.contentType);
      res.send(await metrics.registry.metrics());
    } catch (err) {
      next(err);
    }
  });
}
