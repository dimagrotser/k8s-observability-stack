# k8s-observability-stack
#
# Every target is safe to run repeatedly. `make` on its own prints this list.

CLUSTER_NAME  ?= obs
IMAGE         ?= demo-api
TAG           ?= 0.1.0
NAMESPACE     ?= demo-dev
OVERLAY       ?= k8s/overlays/dev
APP_HOST      ?= demo.localhost
APP_PORT      ?= 8080
BASE_URL      := http://$(APP_HOST):$(APP_PORT)

MONITORING_NS ?= monitoring
HELM_RELEASE  ?= kube-prometheus-stack
CHART         ?= prometheus-community/kube-prometheus-stack
CHART_VERSION ?= 91.8.1
CHART_REPO    ?= https://prometheus-community.github.io/helm-charts

# Optional extra values file layered on top of monitoring/values.yaml. Use it to
# point Alertmanager at a real webhook without putting the URL in the repo:
#   make monitoring-up HELM_EXTRA_VALUES=monitoring/secrets/alertmanager-webhook.yaml
HELM_EXTRA_VALUES ?=

# Chaos settings used by `make demo-alert`.
DEMO_ERROR_RATE ?= 0.5
DEMO_TIMEOUT    ?= 600

# Generated locally, never committed. See .gitignore.
GRAFANA_PASSWORD_FILE := monitoring/secrets/grafana-admin-password.txt

# Upstream JSON schemas for the Prometheus operator CRDs, which kubeconform
# does not ship with.
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.DEFAULT_GOAL := help
.PHONY: help cluster-up load cluster-down build load-image deploy undeploy test lint validate smoke up logs \
        monitoring-up monitoring-down grafana-secret grafana-password dashboards urls \
        rules rules-check rules-test demo-alert

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## --- cluster -------------------------------------------------------------

cluster-up: ## Create the k3d cluster (no-op if it already exists)
	@if k3d cluster list $(CLUSTER_NAME) >/dev/null 2>&1; then \
		echo "cluster '$(CLUSTER_NAME)' already exists"; \
	else \
		k3d cluster create --config k3d/cluster.yaml; \
	fi
	@kubectl cluster-info --context k3d-$(CLUSTER_NAME) >/dev/null
	@echo "waiting for the bundled Traefik ingress controller"
	@until kubectl -n kube-system get deploy traefik >/dev/null 2>&1; do sleep 2; done
	@kubectl -n kube-system rollout status deploy/traefik --timeout=180s

cluster-down: ## Delete the k3d cluster
	k3d cluster delete $(CLUSTER_NAME)

## --- monitoring ----------------------------------------------------------

grafana-secret: ## Generate the Grafana admin Secret (local file, never committed)
	@mkdir -p monitoring/secrets
	@if [ ! -s $(GRAFANA_PASSWORD_FILE) ]; then \
		LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24 > $(GRAFANA_PASSWORD_FILE); \
		echo "generated a new Grafana admin password in $(GRAFANA_PASSWORD_FILE)"; \
	fi
	@kubectl create namespace $(MONITORING_NS) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@kubectl -n $(MONITORING_NS) create secret generic grafana-admin \
		--from-literal=admin-user=admin \
		--from-file=admin-password=$(GRAFANA_PASSWORD_FILE) \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@echo "secret/grafana-admin is in place"

monitoring-up: grafana-secret ## Install kube-prometheus-stack and the dashboards
	helm repo add prometheus-community $(CHART_REPO) >/dev/null
	helm repo update prometheus-community >/dev/null
	helm upgrade --install $(HELM_RELEASE) $(CHART) \
		--version $(CHART_VERSION) \
		--namespace $(MONITORING_NS) --create-namespace \
		--values monitoring/values.yaml \
		$(if $(HELM_EXTRA_VALUES),--values $(HELM_EXTRA_VALUES),) \
		--wait --timeout 10m
	@$(MAKE) --no-print-directory dashboards
	@$(MAKE) --no-print-directory rules

monitoring-down: ## Uninstall kube-prometheus-stack (CRDs are left in place)
	helm uninstall $(HELM_RELEASE) --namespace $(MONITORING_NS)

dashboards: ## Apply the Grafana dashboards as ConfigMaps
	kubectl apply -k monitoring/dashboards

rules: ## Apply the PrometheusRule alert definitions
	kubectl apply -k monitoring/rules

grafana-password: ## Print the generated Grafana admin password
	@cat $(GRAFANA_PASSWORD_FILE) && echo

## --- app -----------------------------------------------------------------

build: ## Build the app container image
	docker build -t $(IMAGE):$(TAG) app/

load-image: ## Side-load the image into the cluster (no registry involved)
	k3d image import $(IMAGE):$(TAG) --cluster $(CLUSTER_NAME)

deploy: ## Apply the dev overlay and wait for the rollout
	kustomize build $(OVERLAY) | kubectl apply -f -
	kubectl -n $(NAMESPACE) rollout status deploy/demo-api --timeout=120s

deploy-prod: ## Apply the prod overlay (3 replicas, HPA, PDB) to the same cluster
	@$(MAKE) --no-print-directory deploy OVERLAY=k8s/overlays/prod NAMESPACE=demo-prod

undeploy-prod: ## Remove everything the prod overlay created
	@$(MAKE) --no-print-directory undeploy OVERLAY=k8s/overlays/prod

smoke-prod: ## Smoke test the prod overlay through its own ingress host
	@$(MAKE) --no-print-directory smoke APP_HOST=demo-prod.localhost

undeploy: ## Remove everything the dev overlay created
	kustomize build $(OVERLAY) | kubectl delete --ignore-not-found -f -

# monitoring-up comes before deploy because the ServiceMonitor in k8s/base
# needs the Prometheus operator CRDs to exist first.
up: cluster-up monitoring-up build load-image deploy urls ## Everything, end to end

logs: ## Tail the app logs
	kubectl -n $(NAMESPACE) logs -l app.kubernetes.io/name=demo-api --tail=100 -f

urls: ## Print the local URLs
	@echo "app          $(BASE_URL)"
	@echo "grafana      http://grafana.localhost:$(APP_PORT)      (admin / \`make grafana-password\`)"
	@echo "prometheus   http://prometheus.localhost:$(APP_PORT)"
	@echo "alertmanager http://alertmanager.localhost:$(APP_PORT)"

demo-alert: ## Drive the error rate up until HighErrorRate fires (takes ~6 min)
	@DEMO_ERROR_RATE=$(DEMO_ERROR_RATE) TIMEOUT=$(DEMO_TIMEOUT) NAMESPACE=$(NAMESPACE) \
		BASE_URL=$(BASE_URL) scripts/demo-alert.sh

load: ## Send traffic at the app (DURATION and CONCURRENCY are overridable)
	@URL=$(BASE_URL)/api/items scripts/load.sh

## --- checks --------------------------------------------------------------

test: ## Run unit tests
	cd app && npm test

lint: ## Run the linter
	cd app && npm run lint

validate: ## Validate every rendered overlay against the Kubernetes and CRD schemas
	@set -e; \
	for overlay in k8s/overlays/*/; do \
		echo "--- $$overlay"; \
		kustomize build "$$overlay" | kubeconform -strict -summary \
			-schema-location default -schema-location '$(CRD_SCHEMAS)' -; \
	done
	@echo "--- monitoring/dashboards"
	@kustomize build monitoring/dashboards | kubeconform -strict -summary -
	@echo "--- monitoring/rules"
	@kustomize build monitoring/rules | kubeconform -strict -summary \
		-schema-location default -schema-location '$(CRD_SCHEMAS)' -

rules-check: ## Check the alert rules with promtool and verify their annotations
	scripts/check-rules.sh monitoring/rules

rules-test: ## Run the promtool unit tests for the alert rules
	scripts/test-rules.sh monitoring/rules monitoring/rules/tests

# Retries each endpoint. Straight after a rollout the ingress can still route to
# the old pod while it drains, and that pod answers /ready with 503. On a fresh
# cluster the ingress controller may not be accepting connections yet, which is
# why a curl that fails outright feeds 000 into the loop instead of aborting it.
smoke: ## Hit every endpoint through the ingress
	@set -e; \
	for path in /health /ready /api/items /metrics; do \
		code=""; \
		for attempt in $$(seq 1 20); do \
			code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $(CURL_RESOLVE) $(BASE_URL)$$path \
				|| true); \
			code=$${code:-000}; \
			[ "$$code" = "200" ] && break; \
			sleep 2; \
		done; \
		if [ "$$code" != "200" ]; then \
			echo "FAIL $$path -> $$code"; exit 1; \
		fi; \
		echo "ok   $$path -> $$code"; \
	done; \
	curl -s --max-time 5 $(CURL_RESOLVE) $(BASE_URL)/metrics | grep -q 'http_requests_total' \
		|| { echo "FAIL /metrics has no http_requests_total"; exit 1; }; \
	echo "ok   /metrics exposes RED metrics"
