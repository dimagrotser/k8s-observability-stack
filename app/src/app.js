import express from 'express';

import { registerRoutes } from './routes.js';

export function createApp({ config, metrics, state }) {
  const app = express();

  app.disable('x-powered-by');
  app.use(metrics.middleware);

  registerRoutes(app, { config, metrics, state });

  app.use((_req, res) => {
    res.status(404).json({ error: 'not found' });
  });

  // eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity.
  app.use((err, _req, res, _next) => {
    console.error('unhandled error', err);
    res.status(500).json({ error: 'internal server error' });
  });

  return app;
}
