export PATH := $(CURDIR)/bin:$(PATH)

TARGETS := $(shell ls scripts|grep -ve "^util-")

# Default behavior for targets
$(TARGETS):
	./scripts/$@

.DEFAULT_GOAL := default

# Charts Build Scripts
pull-scripts:
	@command -v dep-fetch >/dev/null 2>&1 || { echo "WARNING: dep-fetch not found, skipping pull-scripts (expected in ci-image/charts environments)"; exit 0; }; dep-fetch sync

remove:
	./scripts/remove-asset

rebase:
	./scripts/charts-build-scripts/rebase

dev-prepare: pull-scripts
	@charts-build-scripts prepare --soft-errors --debug

dev-prepare-cached: pull-scripts
	@charts-build-scripts prepare --soft-errors --debug --useCache

prepare-cached: pull-scripts
	@charts-build-scripts prepare --useCache

patch-cached: pull-scripts
	@charts-build-scripts patch --useCache

charts-cached: pull-scripts
	@charts-build-scripts charts --useCache

CHARTS_BUILD_SCRIPTS_TARGETS := prepare patch clean clean-cache charts list index unzip zip standardize template

$(CHARTS_BUILD_SCRIPTS_TARGETS): pull-scripts
	@charts-build-scripts $@

.PHONY: $(TARGETS) $(CHARTS_BUILD_SCRIPTS_TARGETS) list

CI_IMAGE ?= ghcr.io/rancher/ci-image/charts:latest
CLUSTER  ?= default

# Render chart packages into charts/ using the ci-image container.
# Works on macOS — GNU patch is inside the Linux container.
render:
	docker run --rm -v $(CURDIR):/repo -w /repo $(CI_IMAGE) make charts

# Run the smoke test against the latest rendered local SUSE chart.
# Reads image tags from .envrc if present; override via env vars.
# Usage: make dev-test [CLUSTER=default]
dev-test:
	@CHART=$(shell ls -d charts/rancher-logging/4.10.0-rancher.*-suse1 2>/dev/null | sort -V | tail -1); \
	if [ -z "$$CHART" ]; then echo "ERROR: no rendered suse chart found — run 'make render' first" >&2; exit 1; fi; \
	echo "Using chart: $$CHART"; \
	[ -f .envrc ] && . ./.envrc; \
	CREATE_CRD=false SKIP_LOG_FLOW_TEST=1 \
	CLUSTER=$(CLUSTER) \
	CHART_REF=$$CHART \
	CHART_VERSION="" \
	./dev-scripts/smoke-test-rancher-logging.sh

.PHONY: render dev-test

list-make:
	@LC_ALL=C $(MAKE) -pRrq -f $(firstword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/(^|\n)# Files(\n|$$)/,/(^|\n)# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | grep -E -v -e '^[^[:alnum:]]' -e '^$@$$'
# IMPORTANT: The line above must be indented by (at least one)
#            *actual TAB character* - *spaces* do *not* work.
