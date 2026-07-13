#!/usr/bin/env bash
# Evaluate whether the freshly-pushed bot commit on $BRANCH is eligible for
# auto-merge. Implements gate criteria 1-4 from auto-merge-chart-pr-prompt.md:
#
#   1. author/label   PR authored by github-actions[bot] + carries `automated`
#   2. input scope    only the two expected files change, and within
#                     values.yaml.patch only tag: lines (or the one-time
#                     fluentd mirror->SUSE repo string)
#   3. tag validity   client_payload.tag is well-formed, non-prerelease, and
#                     (best-effort) resolves to a real manifest in GHCR
#   4. reproducibility re-running the generators from the base branch produces
#                     a byte-identical result to what was committed
#
# "CI green" (criterion 5) is NOT checked here -- it is the separate `verify`
# job (chart render + k3d smoke test), because PRs opened with GITHUB_TOKEN do
# not trigger on: pull_request checks, so there is no PR status check to read.
#
# Writes gate_ok=(true|false) and gate_reason=<text> to $GITHUB_OUTPUT. Never
# exits non-zero for a failed gate -- a failed gate leaves the PR open for a
# human, it does not fail the workflow run.
set -uo pipefail

PATCH="packages/rancher-logging/4.10/generated-changes/patch/values.yaml.patch"
PKG="packages/rancher-logging/4.10/package.yaml"
SCRIPTS=".github/workflows/image-update"

fail() {
  echo "GATE FAILED: $1"
  {
    echo "gate_ok=false"
    echo "gate_reason=$1"
  } >> "$GITHUB_OUTPUT"
  exit 0
}

pass() {
  echo "GATE PASSED"
  {
    echo "gate_ok=true"
    echo "gate_reason=all criteria met"
  } >> "$GITHUB_OUTPUT"
  exit 0
}

# --- Criterion 1: author + label --------------------------------------------
AUTHOR=$(gh pr view "$PR_NUM" --json author --jq '.author.login' 2>/dev/null || echo "")
IS_BOT=$(gh pr view "$PR_NUM" --json author --jq '.author.is_bot' 2>/dev/null || echo "false")
HAS_LABEL=$(gh pr view "$PR_NUM" --json labels --jq '[.labels[].name] | index("automated") != null' 2>/dev/null || echo "false")

if [ "$IS_BOT" != "true" ] || [ "$AUTHOR" != "app/github-actions" ]; then
  fail "PR #$PR_NUM not authored by github-actions[bot] (author=$AUTHOR, is_bot=$IS_BOT)"
fi
if [ "$HAS_LABEL" != "true" ]; then
  fail "PR #$PR_NUM missing 'automated' label"
fi

# --- Criterion 2: input scope -----------------------------------------------
CHANGED=$(git diff --name-only "origin/$BASE" HEAD | sort)
EXPECTED=$(printf '%s\n%s\n' "$PATCH" "$PKG" | sort)
if [ "$CHANGED" != "$EXPECTED" ]; then
  fail "diff touches unexpected files: $(echo "$CHANGED" | tr '\n' ' ')"
fi

# Within values.yaml.patch, every changed content line must be a tag: line or
# the fluentd mirror->SUSE repo migration. Hunk headers (@@ / +++ / ---) and
# pure context are ignored.
SCOPE=$(git diff "origin/$BASE" HEAD -- "$PATCH" | python3 -c '
import sys, re
bad = []
for line in sys.stdin:
    if line.startswith(("+++", "---", "@@", "diff ", "index ")):
        continue
    if line[0] not in "+-":
        continue
    body = line[1:].lstrip("+-").strip()   # strip git +/- then patch +/-
    if not body:
        continue
    if re.match(r"tag:\s", body):
        continue
    if "mirrored-kube-logging-fluentd" in body or "ghcr.io/manno/fluentd" in body:
        continue
    bad.append(body)
if bad:
    print("UNEXPECTED: " + " | ".join(bad[:5]))
')
if [ -n "$SCOPE" ]; then
  fail "values.yaml.patch changed non-tag lines: $SCOPE"
fi

# package.yaml: only the version: line may change.
PKG_SCOPE=$(git diff "origin/$BASE" HEAD -- "$PKG" | python3 -c '
import sys
bad = []
for line in sys.stdin:
    if line.startswith(("+++", "---", "@@", "diff ", "index ")):
        continue
    if line[0] not in "+-":
        continue
    body = line[1:].strip()
    if not body or body.startswith("version:"):
        continue
    bad.append(body)
if bad:
    print("UNEXPECTED: " + " | ".join(bad[:5]))
')
if [ -n "$PKG_SCOPE" ]; then
  fail "package.yaml changed non-version lines: $PKG_SCOPE"
fi

# --- Criterion 3: tag validity ----------------------------------------------
if ! echo "$TAG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  fail "tag '$TAG' is malformed"
fi
case "$TAG" in
  latest|*-rc*|*-alpha*|*-beta*|*rc[0-9]*)
    fail "tag '$TAG' looks like a prerelease/floating tag" ;;
esac

# Best-effort manifest check. Only blocks on a definitive "not found"; auth
# failures on private forks are treated as inconclusive (the verify job's k3d
# smoke test pulls the image for real anyway).
declare -A REPOS=(
  [logging-operator]=ghcr.io/manno/logging-operator
  [config-reloader]=ghcr.io/manno/config-reloader
  [fluent-bit]=ghcr.io/manno/fluent-bit
  [fluentd]=ghcr.io/manno/fluentd
)
REPO="${REPOS[$COMPONENT]:-}"
if [ -n "$REPO" ] && [ -n "${GHCR_PULL_TOKEN:-}" ]; then
  echo "$GHCR_PULL_TOKEN" | docker login ghcr.io -u "${GHCR_PULL_USER:-manno}" --password-stdin >/dev/null 2>&1 || true
  OUT=$(docker manifest inspect "$REPO:$TAG" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    if echo "$OUT" | grep -qiE 'no such manifest|manifest unknown|not found'; then
      fail "tag '$TAG' not found in $REPO"
    else
      echo "WARN: manifest check inconclusive for $REPO:$TAG ($OUT) -- deferring to smoke test"
    fi
  else
    echo "manifest for $REPO:$TAG confirmed"
  fi
else
  echo "WARN: skipping manifest check (no GHCR_PULL_TOKEN) -- deferring to smoke test"
fi

# --- Criterion 4: reproducibility -------------------------------------------
cp "$PATCH" /tmp/head.patch
cp "$PKG" /tmp/head.pkg
git checkout "origin/$BASE" -- "$PATCH" "$PKG"
COMPONENT="$COMPONENT" TAG="$TAG" python3 "$SCRIPTS/update-image-tag.py" >/dev/null
python3 "$SCRIPTS/bump-version.py" >/dev/null
REPRO_OK=true
if ! diff -q "$PATCH" /tmp/head.patch >/dev/null; then REPRO_OK=false; fi
if ! diff -q "$PKG" /tmp/head.pkg >/dev/null; then REPRO_OK=false; fi
# Restore the committed versions so the working tree is untouched.
cp /tmp/head.patch "$PATCH"
cp /tmp/head.pkg "$PKG"
if [ "$REPRO_OK" != "true" ]; then
  fail "committed diff does not match a clean regeneration from origin/$BASE"
fi

pass
