#!/bin/bash
# AutoBuilder prepare hook
# - Ensures data/repos exists
# - Validates every deployment folder has a well-formed service.json
#
# The docker-compose.yml is STATIC and defines a single service (`autobuilder`)
# which is the updater. The updater itself creates and maintains one container
# per deployment at runtime via the Docker socket.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEPLOYMENTS_DIR="./deployments"
REPOS_DIR="./data/repos"

mkdir -p "$REPOS_DIR"

type log_info    >/dev/null 2>&1 || log_info()    { echo "[INFO] $*"; }
type log_success >/dev/null 2>&1 || log_success() { echo "[OK]   $*"; }
type log_warning >/dev/null 2>&1 || log_warning() { echo "[WARN] $*"; }
type log_error   >/dev/null 2>&1 || log_error()   { echo "[ERR]  $*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required on the host to validate deployments"
    exit 1
fi

shopt -s nullglob
count=0
for dir in "$DEPLOYMENTS_DIR"/*/; do
    name="$(basename "$dir")"
    [[ "$name" == _* ]] && continue
    [[ "$name" == .* ]] && continue

    spec="$dir/service.json"
    if [ ! -f "$spec" ]; then
        log_warning "Skipping $name: no service.json"
        continue
    fi

    if ! jq -e . "$spec" >/dev/null 2>&1; then
        log_error "Invalid JSON in $spec"
        exit 1
    fi

    mkdir -p "$REPOS_DIR/$name"
    count=$((count + 1))
done
shopt -u nullglob

log_success "AutoBuilder: validated $count deployment(s)"
