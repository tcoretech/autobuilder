#!/bin/bash
# AutoBuilder management CLI
# Invoked via: corekit run autobuilder <command> [args]
#
# One autobuilder container manages many deployments. Each deployment lives in
# deployments/<name>/ as a service.json spec + a plain .env file. The
# autobuilder polls this folder and reconciles app containers via the Docker
# socket.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEPLOYMENTS_DIR="./deployments"
AUTOBUILDER_CONTAINER="autobuilder"

if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    export PROJECT_ROOT
fi

if [ -f "$PROJECT_ROOT/lib/utils/logging.sh" ]; then
    source "$PROJECT_ROOT/lib/utils/logging.sh"
else
    log_info()    { echo "[INFO] $*"; }
    log_success() { echo "[OK]   $*"; }
    log_warning() { echo "[WARN] $*"; }
    log_error()   { echo "[ERR]  $*" >&2; }
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

list_deployments() {
    shopt -s nullglob
    for dir in "$DEPLOYMENTS_DIR"/*/; do
        local n
        n="$(basename "$dir")"
        [[ "$n" == _* ]] && continue
        [[ "$n" == .* ]] && continue
        [ -f "$dir/service.json" ] || continue
        echo "$n"
    done
    shopt -u nullglob
}

deployment_exists() { [ -f "$DEPLOYMENTS_DIR/$1/service.json" ]; }

container_status() {
    docker ps -a --filter "name=^$1$" --format '{{.Status}}' | head -1
}

require_name() {
    if [ -z "$1" ]; then
        log_error "Deployment name required"
        exit 1
    fi
    if [[ "$1" == _* ]]; then
        log_error "Names starting with _ are reserved for templates"
        exit 1
    fi
}

autobuilder_running() {
    docker ps --filter "name=^${AUTOBUILDER_CONTAINER}$" --format '{{.Names}}' | grep -q "^${AUTOBUILDER_CONTAINER}$"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_list() {
    local ab_status
    ab_status=$(container_status "$AUTOBUILDER_CONTAINER")
    [ -z "$ab_status" ] && ab_status="not running"
    echo "autobuilder: $ab_status"
    echo ""
    printf '%-24s %-6s %-18s %s\n' "NAME" "PORT" "BRANCH" "CONTAINER"
    echo "------------------------------------------------------------------------"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local spec="$DEPLOYMENTS_DIR/$name/service.json"
        local port branch cstat
        port=$(jq -r '.container.port // "-"' "$spec")
        branch=$(jq -r '.git.branch // "main"' "$spec")
        cstat=$(container_status "$name")
        [ -z "$cstat" ] && cstat="—"
        printf '%-24s %-6s %-18s %s\n' "$name" "$port" "$branch" "$cstat"
    done < <(list_deployments)
}

cmd_status() {
    if [ -n "$1" ]; then
        local name="$1"
        require_name "$name"
        deployment_exists "$name" || { log_error "Deployment '$name' not found"; exit 1; }
        echo "Deployment: $name"
        echo "  spec:      $(jq -c '{git: .git.repo, branch: .git.branch, port: .container.port}' "$DEPLOYMENTS_DIR/$name/service.json")"
        echo "  container: $(container_status "$name" || echo 'not found')"
    else
        cmd_list
    fi
}

cmd_show() {
    local name="$1"
    require_name "$name"
    deployment_exists "$name" || { log_error "Deployment '$name' not found"; exit 1; }
    echo "── service.json ──"
    jq '.git.token = if (.git.token // "") == "" then "" else "***REDACTED***" end' \
        "$DEPLOYMENTS_DIR/$name/service.json"
    if [ -f "$DEPLOYMENTS_DIR/$name/.env" ]; then
        echo ""
        echo "── .env ──"
        cat "$DEPLOYMENTS_DIR/$name/.env"
    fi
}

cmd_add() {
    local name="$1"
    require_name "$name"
    if deployment_exists "$name"; then
        log_error "Deployment '$name' already exists"
        exit 1
    fi
    local dest="$DEPLOYMENTS_DIR/$name"
    mkdir -p "$dest"
    if [ -f "$DEPLOYMENTS_DIR/_example/service.json" ]; then
        jq --arg n "$name" '.name = $n' "$DEPLOYMENTS_DIR/_example/service.json" > "$dest/service.json"
    else
        cat > "$dest/service.json" <<JSON
{
  "name": "$name",
  "git":       { "repo": "", "branch": "main", "token": "" },
  "container": { "port": 3000, "host_port": null, "command": null },
  "build":     { "dockerfile": null, "args": ["VITE_*", "NEXT_PUBLIC_*"] }
}
JSON
    fi
    if [ -f "$DEPLOYMENTS_DIR/_example/.env.example" ]; then
        cp "$DEPLOYMENTS_DIR/_example/.env.example" "$dest/.env"
    else
        : > "$dest/.env"
    fi
    log_success "Created $dest"
    echo ""
    echo "Next:"
    echo "  1. Edit $dest/service.json   (set git.repo, git.token if private, port, build.args)"
    echo "  2. Edit $dest/.env           (app env vars)"
    echo "  3. corekit run autobuilder reload   (if autobuilder is already running)"
    echo "     or  corekit up autobuilder       (first-time start)"
}

cmd_remove() {
    local name="$1"
    require_name "$name"
    deployment_exists "$name" || { log_error "Deployment '$name' not found"; exit 1; }
    log_warning "This will stop the container and delete $DEPLOYMENTS_DIR/$name"
    read -p "Type the deployment name to confirm: " confirm
    if [ "$confirm" != "$name" ]; then
        log_error "Confirmation did not match; aborting"
        exit 1
    fi
    docker rm -f "$name" 2>/dev/null || true
    docker image rm "${name}:latest" 2>/dev/null || true
    rm -rf "$DEPLOYMENTS_DIR/$name"
    rm -rf "./data/repos/$name"
    log_success "Removed $name"
}

cmd_logs() {
    if autobuilder_running; then
        exec docker logs "$AUTOBUILDER_CONTAINER" "$@"
    else
        log_error "autobuilder container is not running"
        exit 1
    fi
}

cmd_app_logs() {
    local name="$1"; shift || true
    require_name "$name"
    deployment_exists "$name" || { log_error "Deployment '$name' not found"; exit 1; }
    exec docker logs "$name" "$@"
}

cmd_rebuild() {
    local name="$1"
    require_name "$name"
    deployment_exists "$name" || { log_error "Deployment '$name' not found"; exit 1; }
    if ! autobuilder_running; then
        log_error "autobuilder is not running. Start it with: corekit up autobuilder"
        exit 1
    fi
    log_info "Forcing rebuild of $name: removing image and container so next poll rebuilds"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker image rm "${name}:latest" >/dev/null 2>&1 || true
    rm -rf "./data/repos/$name"
    log_info "Restarting autobuilder to trigger an immediate reconcile..."
    docker restart "$AUTOBUILDER_CONTAINER" >/dev/null
    log_success "Triggered. Watch: corekit run autobuilder logs -f"
}

cmd_reload() {
    if ! autobuilder_running; then
        log_error "autobuilder is not running"
        exit 1
    fi
    log_info "Restarting autobuilder to trigger immediate reconcile..."
    docker restart "$AUTOBUILDER_CONTAINER" >/dev/null
    log_success "Reloaded. Watch: corekit run autobuilder logs -f"
}

cmd_edit() {
    local name="$1"
    require_name "$name"
    deployment_exists "$name" || { log_error "Deployment '$name' not found"; exit 1; }
    "${EDITOR:-nano}" "$DEPLOYMENTS_DIR/$name/service.json"
}

cmd_help() {
    cat <<'HELP'
AutoBuilder CLI — manage GitOps deployments

Usage: corekit run autobuilder <command> [args]

Commands:
  list                     List all deployments with container status
  status [name]            Short status (all, or for one deployment)
  show <name>              Show service.json (token redacted) and .env
  add <name>               Scaffold a new deployment from the _example template
  remove <name>            Stop container, remove image, delete deployment folder
  logs [args]              Follow the autobuilder's logs (extra args passed to docker logs)
  app-logs <name> [args]   Follow an app container's logs
  rebuild <name>           Force an immediate rebuild of one deployment
  reload                   Restart the autobuilder to reconcile immediately
  edit <name>              Open service.json in $EDITOR
  help                     Show this message

Config lives in: deployments/<name>/{service.json, .env}
HELP
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
    list|ls)      cmd_list ;;
    status)       cmd_status "$@" ;;
    show)         cmd_show "$@" ;;
    add|new)      cmd_add "$@" ;;
    remove|rm)    cmd_remove "$@" ;;
    logs)         cmd_logs "$@" ;;
    app-logs)     cmd_app_logs "$@" ;;
    rebuild)      cmd_rebuild "$@" ;;
    reload|reconcile) cmd_reload ;;
    edit)         cmd_edit "$@" ;;
    help|--help|-h|"") cmd_help ;;
    *)            log_error "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac
