# Runbook

One section per alert. Every alert in `monitoring/rules/` links here through its
`runbook_url` annotation, so the link in a Slack message lands on the right
section.

The commands below assume the dev overlay. Swap the namespace for prod.

```bash
NS=demo-dev
```

Useful URLs while working through any of these:

| What | URL |
|---|---|
| Alertmanager | http://alertmanager.localhost:8080 |
| Prometheus alerts | http://prometheus.localhost:8080/alerts |
| RED dashboard | http://grafana.localhost:8080/d/demo-api-red |
| USE dashboard | http://grafana.localhost:8080/d/demo-api-use |

---

## HighErrorRate

**Severity:** critical

**Fires when:** more than 5% of requests to `demo-api` return 5xx, measured over
a 5 minute window, and it stays that way for 5 minutes.

Probe and scrape endpoints (`/health`, `/ready`, `/metrics`) are excluded from
both sides of the ratio. A 503 from `/ready` during warm-up is not a service
error.

**Impact:** users are getting failures. This is the alert that means the service
is broken, not slow.

### First checks

```bash
kubectl -n $NS get pods -l app.kubernetes.io/name=demo-api
kubectl -n $NS logs -l app.kubernetes.io/name=demo-api --tail=200
```

Open the RED dashboard and look at "Rate: requests/sec by status". A single
status code dominating tells you a lot more than the ratio alone.

Find which route is failing:

```
sum by (route, status) (rate(http_requests_total{job="demo-api", status=~"5.."}[5m]))
```

### Likely causes

1. **The chaos knob is still on.** This is the most likely cause in this demo
   and the first thing to rule out.

   ```bash
   kubectl -n $NS get deploy demo-api \
     -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
   ```

   If `ERROR_RATE` is not `"0"`, reset it:

   ```bash
   make deploy    # reapplies the declared state
   ```

2. **A bad rollout.** Check whether the errors started at a deploy:

   ```bash
   kubectl -n $NS rollout history deploy/demo-api
   kubectl -n $NS rollout undo deploy/demo-api
   ```

3. **A dependency is failing.** The demo app has no dependencies, so in this
   project this cause does not apply. In a real service this is where you would
   check the database, the cache and the upstream APIs.

### Confirm recovery

The alert resolves on its own once the ratio drops below 5%. Because the rate
window is 5 minutes, expect the alert to clear a few minutes after the fix, not
immediately.

```bash
curl -sG http://prometheus.localhost:8080/api/v1/query --data-urlencode \
  'query=100 * sum(rate(http_request_errors_total{job="demo-api", route!~"/health|/ready|/metrics"}[5m])) / sum(rate(http_requests_total{job="demo-api", route!~"/health|/ready|/metrics"}[5m]))' \
  | jq -r '.data.result[0].value[1] // "no errors"'
```

### Reproduce it

```bash
make demo-alert
```

---

## HighLatencyP95

**Severity:** warning

**Fires when:** p95 latency across non-probe routes is above 500ms for 5 minutes.

The histogram has an explicit bucket boundary at 0.5s, so the quantile is
accurate at exactly the threshold that matters. Without that bucket
`histogram_quantile` would interpolate across a wide bucket and the alert would
fire on a guess.

**Impact:** the service works but feels slow. Warning rather than critical
because requests are still being served.

### First checks

Open the RED dashboard, panel "Duration: p95 by route". One slow route and a
generally slow service need different fixes.

```
histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{job="demo-api", route!~"/health|/ready|/metrics"}[5m])))
```

Then check whether the pod is resource starved. Look at the USE dashboard,
panels "Saturation: CPU throttling" and "Saturation: Node.js event loop lag
p99". CPU throttling above zero means the CPU limit is the bottleneck.

### Likely causes

1. **`EXTRA_LATENCY_MS` is set.** Same check as above:

   ```bash
   kubectl -n $NS get deploy demo-api \
     -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
   make deploy
   ```

2. **CPU throttling.** If `container_cpu_cfs_throttled_periods_total` is moving,
   raise the CPU limit in `k8s/base/deployment.yaml` or add replicas.

3. **Event loop saturation.** Node is single threaded. A rising
   `nodejs_eventloop_lag_p99_seconds` with low CPU usage means blocking work on
   the main thread, not a lack of CPU.

### Confirm recovery

p95 drops back under 0.5s on the RED dashboard and the alert resolves.

---

## PodCrashLooping

**Severity:** critical

**Fires when:** a `demo-api` container has been in `CrashLoopBackOff` for more
than 2 minutes.

The hold is short on purpose. The kubelet only reports `CrashLoopBackOff` after
several failed starts, so the state itself already carries the evidence and
there is no reason to wait longer.

**Impact:** capacity is reduced or gone. With one replica in dev, the service is
down.

### First checks

```bash
kubectl -n $NS get pods -l app.kubernetes.io/name=demo-api
kubectl -n $NS describe pod -l app.kubernetes.io/name=demo-api | tail -30
kubectl -n $NS logs -l app.kubernetes.io/name=demo-api --previous --tail=100
```

`--previous` is the important one: the current container may not have started
yet, and the reason lives in the log of the one that died.

### Likely causes

1. **OOM kill.** Exit code 137.

   ```bash
   kubectl -n $NS get pod -l app.kubernetes.io/name=demo-api \
     -o jsonpath='{.items[0].status.containerStatuses[0].lastState}' | jq .
   ```

   If `reason` is `OOMKilled`, raise the memory limit in
   `k8s/base/deployment.yaml`. This exact failure hit Grafana during phase 2 at
   a 256Mi limit, so it is worth checking before anything else.

2. **The image is missing from the cluster.** k3d has no registry; the image is
   side loaded. A `ErrImageNeverPull` or `ImagePullBackOff` means the import was
   skipped:

   ```bash
   make build load-image deploy
   ```

3. **The process exits at startup.** A bad env value or a syntax error. The
   previous container's log shows it.

### Confirm recovery

```bash
kubectl -n $NS rollout status deploy/demo-api
make smoke
```

---

## PodNotReady

**Severity:** warning

**Fires when:** a pod named `demo-api-*` has failed its readiness probe for 5
minutes.

The expression compares `kube_pod_status_ready{condition="true"}` to zero rather
than matching `condition="false"`, so a pod in the `unknown` condition is caught
too.

**Impact:** the pod is running but receives no traffic, because the Service has
taken it out of the endpoints list. With one replica that means an outage; with
several it means reduced capacity.

### First checks

```bash
kubectl -n $NS get pods -l app.kubernetes.io/name=demo-api -o wide
kubectl -n $NS describe pod -l app.kubernetes.io/name=demo-api | grep -A5 Readiness
curl -s -o /dev/null -w '%{http_code}\n' http://demo.localhost:8080/ready
```

### Likely causes

1. **Still warming up.** `READY_DELAY_MS` makes `/ready` return 503 for the first
   two seconds after start. If the alert fired, this is not it, but it explains
   short-lived not-ready states right after a deploy.

2. **The pod is draining.** On SIGTERM the app fails readiness first and only
   closes the listener after `SHUTDOWN_GRACE_MS`. A pod stuck terminating shows
   up here.

3. **The readiness probe cannot reach the container.** Check that the container
   port and the probe port still agree:

   ```bash
   kubectl -n $NS get deploy demo-api -o yaml | grep -A4 readinessProbe
   ```

4. **The process is alive but wedged.** Liveness uses `/health`, which has no
   dependencies and will keep answering. If `/health` is fine and `/ready` is
   not, the app has deliberately taken itself out of rotation.

### Confirm recovery

```bash
kubectl -n $NS get endpoints demo-api
```

The pod IP should be back in the list.

---

## HighMemoryUsage

**Severity:** warning

**Fires when:** a `demo-api` container is above 90% of its memory limit for 5
minutes.

Measured against the limit, not the node capacity. The limit is what the kernel
enforces, so a percentage of the limit is what predicts an OOM kill.

**Impact:** none yet. This alert exists to arrive before `PodCrashLooping` does,
while there is still time to act.

### First checks

Open the USE dashboard, panel "Utilisation: memory working set by pod". A flat
high line and a line climbing steadily mean different things: the first is a
limit that is simply too low, the second is a leak.

```
max by (pod) (container_memory_working_set_bytes{container="demo-api"})
```

```bash
curl -s http://demo.localhost:8080/metrics | grep -E 'nodejs_heap_size_(used|total)_bytes'
```

### Likely causes

1. **The limit is too low for the workload.** If usage is flat and high, raise
   `resources.limits.memory` in `k8s/base/deployment.yaml` and redeploy.

2. **A leak.** If `nodejs_heap_size_used_bytes` climbs and never comes down
   across a quiet period, the process is holding references. Restarting buys
   time; it does not fix it.

   ```bash
   kubectl -n $NS rollout restart deploy/demo-api
   ```

3. **Working set is not the same as heap.** `container_memory_working_set_bytes`
   includes page cache the container has touched. A large gap between it and the
   Node heap metrics points at file I/O rather than at application objects.

### Confirm recovery

Memory drops below 90% of the limit on the USE dashboard and the alert resolves.
