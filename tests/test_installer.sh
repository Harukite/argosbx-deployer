#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_dir/argosbx-deploy.sh"
fixture="$repo_dir/tests/fixtures/sbox-base.json"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

bash -n "$installer"

default_plan=$(bash "$installer" --dry-run)
printf '%s\n' "$default_plan" | grep -Fq 'VMess origin    : 127.0.0.1:44020'
printf '%s\n' "$default_plan" | grep -Fq 'Argo mode       : quick'
printf '%s\n' "$default_plan" | grep -Fq 'Sing-box configs: 1.11, 1.12-1.13, 1.14+'

named_plan=$(bash "$installer" --dry-run \
  --node-name test-vps \
  --argo-domain tunnel.example.com \
  --argo-token 'token.ABC/xyz=' \
  --subscription-token 0123456789abcdef)
printf '%s\n' "$named_plan" | grep -Fq 'Argo mode       : named'
printf '%s\n' "$named_plan" | grep -Fq 'subscription    : provided'
! printf '%s\n' "$named_plan" | grep -Fq 'token.ABC'

if bash "$installer" --dry-run --origin-port 443 >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid origin port to fail' >&2
  exit 1
fi

if bash "$installer" --dry-run --argo-domain tunnel.example.com >/dev/null 2>&1; then
  printf '%s\n' 'expected incomplete named tunnel to fail' >&2
  exit 1
fi

# Sourcing the installer exposes pure helpers without starting a deployment.
source "$installer"
generate_sing_box_variants \
  "$fixture" \
  "$test_dir/sbox-1.14.json" \
  "$test_dir/sbox-legacy.json"
python3 -m json.tool "$test_dir/sbox-1.14.json" >/dev/null
python3 -m json.tool "$test_dir/sbox-legacy.json" >/dev/null
python3 - "$fixture" "$test_dir/sbox-1.14.json" "$test_dir/sbox-legacy.json" <<'PY'
import json
import sys
from pathlib import Path

base = json.loads(Path(sys.argv[1]).read_text())
modern = json.loads(Path(sys.argv[2]).read_text())
legacy = json.loads(Path(sys.argv[3]).read_text())

assert "http_clients" not in base
assert "default_http_client" not in base["route"]
assert modern["http_clients"] == [{"tag": "http-client-direct"}]
assert modern["route"]["default_http_client"] == "http-client-direct"
assert modern["dns"] == base["dns"]
assert legacy["dns"]["servers"][0]["address"] == "https://dns.alidns.com/dns-query"
assert legacy["dns"]["servers"][3] == {"tag": "fakeip", "address": "fakeip"}
assert legacy["dns"]["fakeip"]["enabled"] is True
assert "default_domain_resolver" not in legacy["route"]
assert legacy["inbounds"] == base["inbounds"]
PY

printf '%s\n' 'INF Registered tunnel connection url=https://fixture-name.trycloudflare.com' > "$test_dir/argo.log"
[[ "$(wait_for_quick_tunnel_domain "$test_dir/argo.log" 1)" == fixture-name.trycloudflare.com ]]
if wait_for_quick_tunnel_domain "$test_dir/missing.log" 1 >/dev/null; then
  printf '%s\n' 'expected missing Quick Tunnel domain to fail' >&2
  exit 1
fi

move_function=$(declare -f move_existing_targets)
run_function=$(declare -f run_upstream)
printf '%s\n' "$move_function" | grep -Fq 'return 0'
printf '%s\n' "$run_function" | grep -Fq 'bash "$runner"'
printf '%s\n' "$run_function" | grep -Fq 'download_upstream'

if grep -En 'Zoro@VTGGvsvcwy5478|38\.244\.43\.249' "$installer" "$repo_dir/README.md"; then
  printf '%s\n' 'found forbidden deployment secret or address' >&2
  exit 1
fi
printf '%s\n' 'installer tests passed'
