/**
 * Environment parsing for the demo API.
 *
 * Every knob is optional and every invalid value falls back to a safe default
 * instead of crashing the process: a typo in a manifest should not take the
 * pod down, it should show up as "chaos is off".
 */

function parseNumber(raw, { fallback, min, max, integer }) {
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return fallback;
  }

  const value = integer ? Number.parseInt(raw, 10) : Number.parseFloat(raw);
  if (!Number.isFinite(value)) {
    return fallback;
  }

  return Math.min(Math.max(value, min), max);
}

export function loadConfig(env = process.env) {
  return {
    port: parseNumber(env.PORT, { fallback: 8080, min: 1, max: 65535, integer: true }),

    // Chaos knobs. Applied to the business endpoints only, never to the probes.
    errorRate: parseNumber(env.ERROR_RATE, { fallback: 0, min: 0, max: 1, integer: false }),
    extraLatencyMs: parseNumber(env.EXTRA_LATENCY_MS, {
      fallback: 0,
      min: 0,
      max: 60_000,
      integer: true,
    }),

    // How long the pod pretends to warm up before /ready turns green.
    readyDelayMs: parseNumber(env.READY_DELAY_MS, {
      fallback: 0,
      min: 0,
      max: 60_000,
      integer: true,
    }),

    // Grace period between SIGTERM and closing the HTTP server, so the ingress
    // has time to notice the pod is out of the endpoints list.
    shutdownGraceMs: parseNumber(env.SHUTDOWN_GRACE_MS, {
      fallback: 5_000,
      min: 0,
      max: 60_000,
      integer: true,
    }),
  };
}
