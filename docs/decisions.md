# Decisions

Short notes on the choices that a reviewer is most likely to question. Each one
says what was decided, why, and what it costs.

---

## 1. k3d for the cluster

**Context.** The project has to run on a laptop, for free, and be reproducible
from a clean machine.

**Decision.** k3d, which runs k3s inside Docker containers.

**Why not the alternatives.** kind is equally good but ships no ingress
controller, so an ingress would be extra setup. minikube is heavier and its VM
drivers vary by platform. A managed cluster costs money and needs an account.

**Cost.** k3s is not identical to upstream Kubernetes. The clearest example bit
this project in phase 2: k3s runs the scheduler, controller manager and
kube-proxy in a single process, so the per-component scrape targets that
kube-prometheus-stack expects do not exist. See decision 3.

---

## 2. Kustomize for this repository's manifests, Helm only for third-party charts

**Context.** The app needs a dev and a prod variant. The monitoring stack is a
large third-party component.

**Decision.** Kustomize for everything this repository owns. Helm for
kube-prometheus-stack only.

**Why.** A Helm chart for a four-manifest application means writing a templating
layer and a values schema to express two differences. Kustomize overlays show
the difference itself: `k8s/overlays/prod/patch-deployment.yaml` is a short file
that reads as "here is what prod changes". `kustomize build` also renders
without a cluster, which is what makes the CI validation job cheap.

Helm earns its place for a chart with hundreds of options that somebody else
maintains. Rendering that by hand would be worse.

**Cost.** No packaging story. Nobody can `helm install` this app. For a demo
service deployed from its own repository, that was never needed.

---

## 3. kube-prometheus-stack rather than assembling Prometheus by hand

**Context.** The project needs Prometheus, Alertmanager, Grafana,
kube-state-metrics and node-exporter, wired together and pointed at each other.

**Decision.** Install the community chart, pinned to 91.8.1.

**Why.** Assembling those five components by hand is a week of yak shaving that
demonstrates patience rather than judgement. The chart also brings the
Prometheus operator, which is what makes `ServiceMonitor` work, so the app is
never named in a Prometheus config file.

**Cost.** A large surface area that has to be understood before it can be
trimmed. Two examples are in the values file: the control plane scrape targets
are disabled because k3s does not expose them the way the chart expects, and the
Grafana memory limit had to be raised after the container was OOM killed at
256Mi.

---

## 4. Two dashboards, RED and USE, rather than one combined view

**Context.** Dashboards drift into a wall of panels that nobody reads.

**Decision.** `demo-api / RED` for request rate, errors and duration.
`demo-api / USE` for utilisation, saturation and errors of the workload.

**Why.** They answer different questions. RED answers "is the service healthy
for its users" and is what you open when someone complains. USE answers "is the
workload healthy" and is what you open when RED looks bad and you want to know
why. Mixing them produces a dashboard that is wrong for both jobs.

**Cost.** Two files to keep in step. The panel thresholds have to match the
alert thresholds by hand: 5% errors, 500ms p95, 90% of the memory limit.

---

## 5. Probe traffic is filtered in the queries, not dropped from the metrics

**Context.** `/ready` returns 503 while a pod warms up. That is a 5xx response
and the middleware counts it, which inflates the error rate on every restart.

**Decision.** Keep instrumenting the probe endpoints. Exclude
`/health`, `/ready` and `/metrics` in the dashboard and alert queries instead.

**Why.** A 503 from `/ready` genuinely happened and the metric should say so.
Dropping it at the source would make `/metrics` lie, and the data would be gone
when someone later wants to know how long pods take to become ready. Filtering
at query time keeps the raw data honest and puts the interpretation where it
belongs.

**Cost.** The same `route!~"/health|/ready|/metrics"` clause is repeated in every
RED query and both service alerts. A promtool unit test feeds nothing but 503s
from `/ready` and asserts `HighErrorRate` stays silent, so the filter cannot
regress unnoticed.

---

## 6. Chaos knobs affect only the business endpoints

**Context.** `ERROR_RATE` and `EXTRA_LATENCY_MS` exist to make alerts fire on
demand.

**Decision.** They apply to `/api/items` and never to `/health` or `/ready`.

**Why.** If a high `ERROR_RATE` also broke the liveness probe, the kubelet would
restart the pod and the demo would show `PodCrashLooping` instead of
`HighErrorRate`. The knob would demonstrate the wrong alert.

**Cost.** The chaos is less realistic than a genuinely sick process. That is the
right trade for a knob whose only job is to make a specific alert fire.

---

## 7. Node.js instead of Go

**Context.** Go was the first choice. It is not installed on the machine this
was built on.

**Decision.** Node.js 24, with the runtime image built on
`gcr.io/distroless/nodejs24-debian12:nonroot`.

**Why.** The project brief allowed Node as the fallback, and the observability
story does not depend on the language. Distroless keeps the security properties
that matter: no shell, no package manager, uid 65532 by default. All
dependencies are pure JavaScript, so nothing needs to compile.

**Cost.** The image is 223MB against roughly 15MB for a static Go binary. Node
is also single threaded, which is why the USE dashboard carries an event loop
lag panel: a saturated event loop does not show up in container CPU numbers.

---

## 8. Alertmanager ships without a webhook URL

**Context.** The brief asks for a configurable webhook receiver. A Slack webhook
URL is a credential.

**Decision.** The `critical` and `warning` receivers are declared with no
notifier. A receiver with only a name is valid Alertmanager configuration and
drops the notification silently. A real URL is layered on from a gitignored file
with `make monitoring-up HELM_EXTRA_VALUES=...`.

**Why.** The alternative, a placeholder URL such as `http://localhost:5001/`,
produces a steady stream of delivery failures in the Alertmanager logs of every
fresh install. A repository whose default state logs errors teaches the reader
to ignore errors.

**Cost.** Out of the box nothing is delivered anywhere and alerts are visible
only in the Alertmanager UI. `monitoring/alertmanager-webhook.example.yaml`
exists so that the shape of the missing piece is obvious.
