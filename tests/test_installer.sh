#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_dir/argosbx-deploy.sh"

bash -n "$installer"

default_plan=$(bash "$installer" --dry-run)
printf '%s\n' "$default_plan" | grep -Fq 'VMess origin    : 127.0.0.1:44020'
printf '%s\n' "$default_plan" | grep -Fq 'Argo mode       : quick'

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

! rg -n 'Zoro@VTGGvsvcwy5478|38\.244\.43\.249' "$repo_dir/argosbx-deploy.sh" "$repo_dir/README.md"
printf '%s\n' 'installer tests passed'
