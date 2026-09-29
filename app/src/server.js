import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { createMetrics } from './metrics.js';

const config = loadConfig();
const metrics = createMetrics();
const state = { ready: config.readyDelayMs === 0 };

const app = createApp({ config, metrics, state });
const server = app.listen(config.port, () => {
  console.log(
    `demo-api listening on :${config.port} ` +
      `(errorRate=${config.errorRate}, extraLatencyMs=${config.extraLatencyMs})`,
  );
});

if (!state.ready) {
  setTimeout(() => {
    state.ready = true;
    console.log('warm-up finished, /ready is green');
  }, config.readyDelayMs).unref();
}

let shuttingDown = false;

/**
 * Fail readiness first, then wait before closing the listener. Endpoint removal
 * propagates to kube-proxy and the ingress asynchronously, so a pod that closes
 * its socket the instant it gets SIGTERM still drops in-flight requests.
 */
function shutdown(signal) {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;

  console.log(`${signal} received, draining for ${config.shutdownGraceMs}ms`);
  state.ready = false;

  setTimeout(() => {
    server.close((err) => {
      if (err) {
        console.error('error while closing server', err);
        process.exit(1);
      }

      console.log('server closed');
      process.exit(0);
    });
  }, config.shutdownGraceMs);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
