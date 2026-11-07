#!/usr/bin/env bash
# shellcheck disable=SC2016 # the jq filters use $write and $read on purpose
# Checks that the JSON files in evidence/ still say what the README tables say.
# Runs against the committed files, or against fresh output after the scripts run again.
# Usage: bash scripts/check-evidence.sh   (needs jq)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="$ROOT/evidence"
WRITE_TOOLS='["kubectl_apply","kubectl_create","kubectl_patch","kubectl_scale","kubectl_rollout","exec_in_pod","install_helm_chart","upgrade_helm_chart"]'
READ_TOOLS='["explain_resource","kubectl_context","kubectl_describe","kubectl_get","kubectl_logs","kubectl_reconnect","list_api_resources","ping"]'
failed=0

check() {
  local description="$1" file="$2" filter="$3"
  if jq -e --argjson write "$WRITE_TOOLS" --argjson read "$READ_TOOLS" "$filter" "$EVIDENCE/$file" >/dev/null; then
    echo "ok   $description"
  else
    echo "FAIL $description ($file)"
    failed=1
  fi
}

# 1. What each flag exposes, and whether a hidden tool can still be called directly.
check "no flag: 23 tools" flags-none.json \
  '.server.version == "4.1.7" and .toolCount == 23'
check "non-destructive flag: 18 tools, the 8 write tools still listed" flags-non-destructive.json \
  '.toolCount == 18 and (($write - .tools) == [])'
check "non-destructive flag: kubectl_delete refused on tools/call" flags-non-destructive.json \
  '.calls[0].tool == "kubectl_delete" and (.calls[0].response.message | test("is not allowed"))'
check "read-only flag: only the 8 read tools" flags-readonly.json \
  '.toolCount == 8 and (.tools | sort) == ($read | sort)'
check "read-only flag: kubectl_apply refused on tools/call" flags-readonly.json \
  '.calls[0].tool == "kubectl_apply" and (.calls[0].response.message | test("is not allowed"))'

# 2. RBAC: the same six calls, all 23 tools exposed, two identities.
check "view ServiceAccount: all 23 tools exposed" rbac-as-view-serviceaccount.json \
  '.toolCount == 23 and (.calls | length) == 6'
check "view ServiceAccount: kubectl_get allowed" rbac-as-view-serviceaccount.json \
  '.calls[0].tool == "kubectl_get" and (.calls[0].response | has("code") | not)
   and (.calls[0].response | tostring | test("forbidden"; "i") | not)'
check "view ServiceAccount: the 5 writes are Forbidden" rbac-as-view-serviceaccount.json \
  '[.calls[1:][] | .response | tostring | test("forbidden"; "i")] | length == 5 and all'
check "cluster-admin: all 6 calls succeed" rbac-as-cluster-admin.json \
  '[.calls[] | .response | has("code") or (tostring | test("forbidden|success.{0,4}false"; "i"))]
   | length == 6 and (any | not)'

if [ "$failed" -ne 0 ]; then
  echo "evidence/ does not match the README" >&2
  exit 1
fi
echo "evidence/ matches the README"
