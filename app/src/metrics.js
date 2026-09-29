import { Counter, Histogram, Registry, collectDefaultMetrics } from 'prom-client';

/**
 * Latency buckets in seconds. The 0.5 boundary exists on purpose: the
 * HighLatencyP95 alert fires above 500ms, and histogram_quantile is only as
 * accurate as the bucket nearest the threshold.
 */
const LATENCY_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];

const LABELS = ['route', 'method', 'status'];

/**
 * The route label must be the matched route template, never the raw URL.
 * `/api/items?id=1` and a 404 from a vulnerability scanner would otherwise
 * each create their own time series and blow up Prometheus cardinality.
 */
function routeLabel(req) {
  const template = req.route?.path;
  if (!template) {
    return 'unmatched';
  }

  const base = req.baseUrl ?? '';
  const suffix = template === '/' ? '' : template;
  return `${base}${suffix}` || '/';
}

export function createMetrics() {
  const registry = new Registry();
  collectDefaultMetrics({ register: registry });

  const requestsTotal = new Counter({
    name: 'http_requests_total',
    help: 'Total number of HTTP requests, by route, method and response status.',
    labelNames: LABELS,
    registers: [registry],
  });

  const errorsTotal = new Counter({
    name: 'http_request_errors_total',
    help: 'Total number of HTTP requests that returned a 5xx response.',
    labelNames: LABELS,
    registers: [registry],
  });

  const requestDuration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request latency in seconds, by route, method and response status.',
    labelNames: LABELS,
    buckets: LATENCY_BUCKETS,
    registers: [registry],
  });

  function middleware(req, res, next) {
    const stopTimer = requestDuration.startTimer();

    res.on('finish', () => {
      const labels = {
        route: routeLabel(req),
        method: req.method,
        status: String(res.statusCode),
      };

      stopTimer(labels);
      requestsTotal.inc(labels);

      if (res.statusCode >= 500) {
        errorsTotal.inc(labels);
      }
    });

    next();
  }

  return { registry, requestsTotal, errorsTotal, requestDuration, middleware };
}
