# Architecture

Everything runs on one local k3d cluster. There is no cloud account, no managed
service and no paid tier anywhere in this diagram.

## Runtime

```mermaid
flowchart LR
    dev["Developer<br/>make"]

    subgraph cluster["k3d cluster (k3s v1.36.4)"]
        traefik["Traefik<br/>ingress controller"]

        subgraph appns["namespace: demo-dev / demo-prod"]
            ing["Ingress<br/>demo.localhost"]
            svc["Service<br/>ClusterIP :80"]
            pods["demo-api pods<br/>Node.js, distroless, non-root"]
            sm["ServiceMonitor"]
        end

        subgraph monns["namespace: monitoring"]
            operator["Prometheus operator"]
            prom["Prometheus"]
            am["Alertmanager"]
            graf["Grafana"]
            ksm["kube-state-metrics"]
            nodeexp["node-exporter"]
        end
    end

    webhook["Webhook receiver<br/>Slack, optional"]

    dev -->|"kubectl, helm"| cluster
    dev -->|"http :8080"| traefik
    traefik --> ing --> svc --> pods

    sm -.->|"discovered by"| operator
    operator -->|"generates scrape config"| prom
    prom -->|"GET /metrics every 15s"| pods
    prom --> ksm
    prom --> nodeexp

    prom -->|"evaluates PrometheusRules"| am
    am -->|"routes by severity"| webhook
    graf -->|"queries"| prom
```

The app is never named in a Prometheus configuration file. The `ServiceMonitor`
in `k8s/base` is what the operator turns into a scrape target, which is the
whole point of running the operator instead of hand-editing config.

## Signals

```mermaid
flowchart TD
    app["demo-api"]

    app -->|"http_requests_total<br/>http_request_errors_total<br/>http_request_duration_seconds"| red["RED dashboard<br/>+ HighErrorRate, HighLatencyP95"]
    app -->|"process and nodejs<br/>default metrics"| use1["USE dashboard<br/>event loop saturation"]

    cadvisor["kubelet / cAdvisor"] -->|"container_cpu_usage_seconds_total<br/>container_memory_working_set_bytes"| use2["USE dashboard<br/>+ HighMemoryUsage"]
    ksm["kube-state-metrics"] -->|"kube_pod_status_ready<br/>kube_pod_container_status_waiting_reason"| use3["USE dashboard<br/>+ PodNotReady, PodCrashLooping"]
```

Application metrics answer "is the service healthy for its users". Container and
cluster metrics answer "is the workload healthy". Both dashboards exist because
those are different questions and they fail in different ways.

## Delivery

```mermaid
flowchart LR
    push["push or pull request"]

    push --> app["app<br/>eslint + unit tests"]
    push --> man["manifests<br/>kustomize + kubeconform"]
    push --> rules["rules<br/>promtool check + test"]
    push --> img["image<br/>buildx"]
    app --> e2e["e2e<br/>real k3d cluster"]

    img -->|"push events only"| ghcr["GHCR<br/>tagged by commit SHA"]
```

The five jobs run in parallel. `e2e` waits for `app`, because there is no point
burning a cluster on code that does not lint.

## Request path in detail

```mermaid
sequenceDiagram
    participant C as curl
    participant T as Traefik
    participant S as Service
    participant P as demo-api pod
    participant M as metrics middleware

    C->>T: GET /api/items<br/>Host: demo.localhost
    T->>S: route by host and path
    S->>P: forward to a ready endpoint
    P->>M: start timer
    Note over P: chaos knobs applied here:<br/>EXTRA_LATENCY_MS, then ERROR_RATE
    P-->>M: response finished
    M->>M: record route, method, status
    P-->>C: 200 or injected 500
```

The metrics middleware labels the request with the matched route template, not
the raw URL. `/api/items?id=1` and a 404 from a scanner would otherwise each
create their own time series.
