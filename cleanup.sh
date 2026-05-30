#!/bin/bash
# Stop and remove app containers managed by the AutoBuilder service.
# CoreKit runs cleanup.sh after `docker compose down` for this service, which
# makes AutoBuilder deployments follow the parent service lifecycle.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

type log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
type log_success >/dev/null 2>&1 || log_success() { echo "[OK]   $*"; }
type log_warning >/dev/null 2>&1 || log_warning() { echo "[WARN] $*"; }

if ! command -v docker >/dev/null 2>&1; then
    log_warning "AutoBuilder cleanup skipped: docker command not found"
    exit 0
fi

tmp_ids="$(mktemp)"
trap 'rm -f "$tmp_ids"' EXIT

# Newer children are labeled. This also catches stopped containers.
docker ps -aq \
    --filter "label=corekit.child=true" \
    --filter "label=corekit.parent.service=autobuilder" >> "$tmp_ids" || true
docker ps -aq --filter "label=corekit.autobuilder=true" >> "$tmp_ids" || true

# Older children may only be identifiable by the deployment/container name.
shopt -s nullglob
for dir in ./deployments/*/; do
    name="$(basename "$dir")"
    [[ "$name" == _* ]] && continue
    [[ "$name" == .* ]] && continue
    [ -f "$dir/service.json" ] || continue
    docker ps -aq --filter "name=^${name}$" >> "$tmp_ids" || true
done
shopt -u nullglob

mapfile -t container_ids < <(sort -u "$tmp_ids" | sed '/^$/d')
if [ ${#container_ids[@]} -eq 0 ]; then
    log_info "AutoBuilder cleanup: no managed app containers found"
    exit 0
fi

log_info "AutoBuilder cleanup: removing ${#container_ids[@]} managed app container(s)"
docker rm -f "${container_ids[@]}" >/dev/null 2>&1 || true
log_success "AutoBuilder cleanup complete"
