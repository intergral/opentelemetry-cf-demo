# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


# All documents to be used in spell check.
ALL_DOCS := $(shell find . -type f -name '*.md' -not -path './.github/*' -not -path '*/node_modules/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path */Pods/* -not -path */.expo/* | sort)
PWD := $(shell pwd)

TOOLS_DIR := ./internal/tools
MISSPELL_BINARY=bin/misspell
MISSPELL = $(TOOLS_DIR)/$(MISSPELL_BINARY)

DOCKER_COMPOSE_CMD ?= docker compose
DOCKER_COMPOSE_ENV=--env-file .env
DOCKER_COMPOSE_BUILD_ARGS=
DOCKER_COMPOSE_FILES=

# Java Workaround for macOS 15.2+ and Apple Silicon (see https://bugs.openjdk.org/browse/JDK-8345296)
ifeq ($(shell uname -m),arm64)
	ifeq ($(shell uname -s),Darwin)
		DOCKER_COMPOSE_ENV+= --env-file .env.arm64
		DOCKER_COMPOSE_BUILD_ARGS+= --build-arg=_JAVA_OPTIONS=-XX:UseSVE=0
	endif
endif

# .env.override holds the local OpsPilot destination and is gitignored, so it is
# optional: compose errors out on a missing --env-file. It is listed last so its
# values win. Copy .env.override.example to get started.
ifneq (,$(wildcard .env.override))
	DOCKER_COMPOSE_ENV+= --env-file .env.override
endif

# LOCAL ONLY. Building all 18 images at once makes each target open its own
# cache_from registry connection, which Docker Desktop rejects with
# "only one connection allowed"; that then cascades into DeadlineExceeded and
# Canceled on most targets. Serialising the build avoids it. On a machine that
# does not hit the limit, `make build BUILD_PARALLEL=0` restores the default
# behaviour, or set it to any other number.
BUILD_PARALLEL ?= 3
ifneq ($(BUILD_PARALLEL),0)
	DOCKER_BUILD_ENV=COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT=$(BUILD_PARALLEL)
endif

# LOCAL ONLY. Park jaeger, opensearch, prometheus and grafana behind an
# off-by-default profile; see the header of docker-compose.trim.yml. Use
# `make start TRIM=0` for the full upstream stack.
TRIM ?= 1
ifeq ($(TRIM),1)
	DOCKER_COMPOSE_FILES= -f docker-compose.yml -f docker-compose.trim.yml
endif

# see https://github.com/open-telemetry/build-tools/releases for semconvgen updates
# Keep links in semantic_conventions/README.md and .vscode/settings.json in sync!
SEMCONVGEN_VERSION=0.11.0
YAMLLINT_VERSION=1.30.0

.PHONY: all
all: install-tools markdownlint misspell yamllint

$(MISSPELL):
	cd $(TOOLS_DIR) && go build -o $(MISSPELL_BINARY) github.com/client9/misspell/cmd/misspell

.PHONY: misspell
misspell:	$(MISSPELL)
	$(MISSPELL) -error $(ALL_DOCS)

.PHONY: misspell-correction
misspell-correction:	$(MISSPELL)
	$(MISSPELL) -w $(ALL_DOCS)

.PHONY: markdownlint
markdownlint:
	@if ! npm ls markdownlint; then npm install; fi
	@for f in $(ALL_DOCS); do \
		echo $$f; \
		npx --no -p markdownlint-cli markdownlint -c .markdownlint.yaml $$f \
			|| exit 1; \
	done

.PHONY: install-yamllint
install-yamllint:
    # Using a venv is recommended
	yamllint --version >/dev/null 2>&1 || pip install -U yamllint~=$(YAMLLINT_VERSION)

.PHONY: yamllint
yamllint: install-yamllint
	yamllint .

.PHONY: checklicense
checklicense:
	@echo "Checking license headers..."
	@if ! npm ls @kt3k/license-checker; then npm install; fi
	npx @kt3k/license-checker -q

.PHONY: addlicense
addlicense:
	@echo "Adding license headers..."
	@if ! npm ls @kt3k/license-checker; then npm install; fi
	npx @kt3k/license-checker -q -i

.PHONY: checklinks
checklinks:
	@echo "Checking links..."
	@if ! npm ls @umbrelladocs/linkspector; then npm install; fi
	linkspector check

# Run all checks in order of speed / likely failure.
.PHONY: check
check: misspell markdownlint checklicense checklinks
	@echo "All checks complete"

# Attempt to fix issues / regenerate tables.
.PHONY: fix
fix: misspell-correction
	@echo "All autofixes complete"

.PHONY: install-tools
install-tools: $(MISSPELL)
	npm install
	@echo "All tools installed"

.PHONY: build
build:
	$(DOCKER_BUILD_ENV) $(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build $(DOCKER_COMPOSE_BUILD_ARGS)

.PHONY: build-and-push
build-and-push:
	$(DOCKER_BUILD_ENV) $(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build $(DOCKER_COMPOSE_BUILD_ARGS) --push

# Create multiplatform builder for buildx
.PHONY: create-multiplatform-builder
create-multiplatform-builder:
	docker buildx create --name otel-demo-builder --bootstrap --use --driver docker-container --config ./buildkitd.toml

# Remove multiplatform builder for buildx
.PHONY: remove-multiplatform-builder
remove-multiplatform-builder:
	docker buildx rm otel-demo-builder

# Build and push multiplatform images (linux/amd64, linux/arm64) using buildx.
# Requires docker with buildx enabled and a multi-platform capable builder in use.
# Docker needs to be configured to use containerd storage for images to be loaded into the local registry.
.PHONY: build-multiplatform
build-multiplatform:
	# Because buildx bake does not support --env-file yet, we need to load it into the environment first.
	set -a; . ./.env.override; set +a && docker buildx bake -f docker-compose.yml --load --set "*.platform=linux/amd64,linux/arm64"

.PHONY: build-multiplatform-and-push
build-multiplatform-and-push:
    # Because buildx bake does not support --env-file yet, we need to load it into the environment first.
	set -a; . ./.env.override; set +a && docker buildx bake -f docker-compose.yml --push --set "*.platform=linux/amd64,linux/arm64"

.PHONY: clean-images
clean-images:
	@docker rmi $(shell docker images --filter=reference="ghcr.io/open-telemetry/demo:latest-*" -q); \
    if [ $$? -ne 0 ]; \
    then \
    	echo; \
        echo "Failed to removed 1 or more OpenTelemetry Demo images."; \
        echo "Check to ensure the Demo is not running by executing: make stop"; \
        false; \
    fi

.PHONY: run-tests
run-tests:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml run frontendTests
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml run traceBasedTests

.PHONY: run-tracetesting
run-tracetesting:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml run traceBasedTests ${SERVICES_TO_TEST}

.PHONY: generate-protobuf
generate-protobuf:
	./ide-gen-proto.sh

.PHONY: generate-kubernetes-manifests
generate-kubernetes-manifests:
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo update
	echo "# Copyright The OpenTelemetry Authors" > kubernetes/opentelemetry-demo.yaml
	echo "# SPDX-License-Identifier: Apache-2.0" >> kubernetes/opentelemetry-demo.yaml
	echo "# This file is generated by 'make generate-kubernetes-manifests'" >> kubernetes/opentelemetry-demo.yaml
	echo "---" >> kubernetes/opentelemetry-demo.yaml
	echo "apiVersion: v1" >> kubernetes/opentelemetry-demo.yaml
	echo "kind: Namespace" >> kubernetes/opentelemetry-demo.yaml
	echo "metadata:" >> kubernetes/opentelemetry-demo.yaml
	echo "  name: otel-demo" >> kubernetes/opentelemetry-demo.yaml
	helm template opentelemetry-demo open-telemetry/opentelemetry-demo --namespace otel-demo | sed '/helm.sh\/chart\:/d' | sed '/helm.sh\/hook/d' | sed '/managed-by\: Helm/d' >> kubernetes/opentelemetry-demo.yaml

.PHONY: docker-generate-protobuf
docker-generate-protobuf:
	./docker-gen-proto.sh

.PHONY: clean
clean:
	rm -rf ./src/{checkout,product-catalog}/genproto/oteldemo/
	rm -rf ./src/recommendation/{demo_pb2,demo_pb2_grpc}.py
	rm -rf ./src/frontend/protos/demo.ts

.PHONY: check-clean-work-tree
check-clean-work-tree:
	@if ! git diff --quiet; then \
	  echo; \
	  echo 'Working tree is not clean, did you forget to run "make docker-generate-protobuf"?'; \
	  echo; \
	  git status; \
	  exit 1; \
	fi

.PHONY: start
start:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) up --force-recreate --remove-orphans --detach
#	Re-establish the permanent 4ms payment -> MySQL link latency. Toxics live
#	only in the toxiproxy container's memory, so --force-recreate (and any
#	`make stop`) wipes them; src/toxiproxy/toxiproxy.json seeds the proxy but
#	cannot express toxics. payment depends_on toxiproxy with condition
#	service_healthy, so by the time `up` returns the control API is ready and
#	there is no race here. Warn rather than fail: the stack is already up, and
#	aborting the target would be worse than a visible warning.
	@./demo.sh baseline-toxic || { \
	  echo ""; \
	  echo "WARNING: could not apply the 4ms baseline latency toxic."; \
	  echo "         Run './demo.sh baseline-toxic' once toxiproxy is healthy."; \
	}
	@echo ""
	@echo "OpenTelemetry Demo is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/feature/ to change feature flags."
	@if [ "$(TRIM)" = "1" ]; then \
	  echo ""; \
	  echo "Trimmed run: jaeger, opensearch, prometheus and grafana were not started,"; \
	  echo "so /jaeger/ui and /grafana/ return 503. Use 'make start TRIM=0' for all of them."; \
	else \
	  echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."; \
	  echo "Go to http://localhost:8080/grafana/ for the Grafana UI."; \
	fi

# Build with the right build args, then start. This is the local entry point.
.PHONY: start-build
start-build: build start

.PHONY: start-minimal
start-minimal:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose.minimal.yml up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo in minimal mode is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to https://opentelemetry.io/docs/demo/feature-flags/ to learn how to change feature flags."

.PHONY: stop
stop:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) down --remove-orphans --volumes
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml down --remove-orphans --volumes
	@echo ""
	@echo "OpenTelemetry Demo is stopped."

# Use to restart a single service component
# Example: make restart service=frontend
#
# DOCKER_COMPOSE_FILES must be included: without it the trim overlay is skipped,
# compose resolves the untrimmed depends_on chain, and recreating any one
# service silently starts jaeger and opensearch.
.PHONY: restart
restart:
# work with `service` or `SERVICE` as input
ifdef SERVICE
	service := $(SERVICE)
endif

ifdef service
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) stop $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) rm --force $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) create $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) start $(service)
else
	@echo "Please provide a service name using `service=[service name]` or `SERVICE=[service name]`"
endif

# Use to rebuild and restart (redeploy) a single service component
# Example: make redeploy service=frontend
.PHONY: redeploy
redeploy:
# work with `service` or `SERVICE` as input
ifdef SERVICE
	service := $(SERVICE)
endif

ifdef service
	$(DOCKER_BUILD_ENV) $(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build $(DOCKER_COMPOSE_BUILD_ARGS) $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) stop $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) rm --force $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) create $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) start $(service)
else
	@echo "Please provide a service name using `service=[service name]` or `SERVICE=[service name]`"
endif

.PHONY: build-react-native-android
build-react-native-android:
	docker build -f src/react-native-app/android.Dockerfile --platform=linux/amd64 --output=. src/react-native-app
