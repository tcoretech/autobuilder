#!/bin/bash
# AutoBuilder updater — one process, many deployments.
# Scans /app/deployments/*/ every POLL_INTERVAL seconds. For each deployment:
#   - read service.json (spec) and .env (app env vars)
#   - clone/fetch the repo into /app/repos/<name>
#   - on first run or new commit: rebuild the image and (re)create the container
#
# App containers are created directly via `docker run` on the project's default
# network, so no generated docker-compose.yml is needed.

set -u

DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR:-/app/deployments}"
REPOS_DIR="${REPOS_DIR:-/app/repos}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-localai}"
NETWORK="${COMPOSE_PROJECT_NAME}_default"

log() { echo "[autobuilder] $*"; }

ensure_network() {
    if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
        log "network $NETWORK not found — creating"
        docker network create "$NETWORK" >/dev/null || true
    fi
}

# Reconcile one deployment folder.
# Returns 0 on success (incl. no-op), non-zero on error.
reconcile_one() {
    local dir="$1"
    local name
    name="$(basename "$dir")"

    [[ "$name" == _* ]] && return 0
    [[ "$name" == .* ]] && return 0

    local spec="$dir/service.json"
    local envfile="$dir/.env"
    [ -f "$spec" ] || return 0

    local repo_url branch token port host_port cmd custom_df build_args
    repo_url=$(jq -r '.git.repo // ""'        "$spec")
    branch=$(  jq -r '.git.branch // "main"'  "$spec")
    token=$(   jq -r '.git.token // ""'       "$spec")
    port=$(    jq -r '.container.port // 3000' "$spec")
    host_port=$(jq -r '.container.host_port // empty' "$spec")
    cmd=$(     jq -r '.container.command // empty'    "$spec")
    custom_df=$(jq -r '.build.dockerfile // ""'       "$spec")
    build_args=$(jq -r '.build.args // [] | join(" ")' "$spec")

    if [ -z "$repo_url" ]; then
        log "[$name] skip: git.repo is empty"
        return 0
    fi

    local image="${name}:latest"
    local repo_dir="$REPOS_DIR/$name"
    local auth_url="$repo_url"
    if [ -n "$token" ]; then
        auth_url="${repo_url/https:\/\//https:\/\/git:$token@}"
    fi

    # ── Git: clone or fetch ────────────────────────────────────────────────
    local changed=0
    if [ ! -d "$repo_dir/.git" ]; then
        log "[$name] cloning $repo_url ($branch)"
        rm -rf "$repo_dir"
        mkdir -p "$(dirname "$repo_dir")"
        if ! git clone -b "$branch" "$auth_url" "$repo_dir" >/dev/null 2>&1; then
            log "[$name] clone failed"
            return 1
        fi
        changed=1
    else
        (
            cd "$repo_dir" || exit 1
            git remote set-url origin "$auth_url"
            git fetch origin "$branch" >/dev/null 2>&1
        ) || { log "[$name] fetch failed"; return 1; }

        local local_sha remote_sha
        local_sha=$(  git -C "$repo_dir" rev-parse HEAD              2>/dev/null || echo "")
        remote_sha=$( git -C "$repo_dir" rev-parse "origin/$branch"  2>/dev/null || echo "")
        if [ "$local_sha" != "$remote_sha" ] && [ -n "$remote_sha" ]; then
            log "[$name] update: ${local_sha:0:7} -> ${remote_sha:0:7}"
            git -C "$repo_dir" reset --hard "origin/$branch" >/dev/null 2>&1 || true
            changed=1
        fi
    fi

    # Also rebuild/run if the image is missing or the container isn't running.
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        changed=1
    fi
    local running
    running=$(docker ps --filter "name=^${name}$" --format '{{.Names}}' | head -n1)
    if [ "$running" != "$name" ]; then
        changed=1
    fi

    [ "$changed" -eq 0 ] && return 0

    # ── Dockerfile resolution ──────────────────────────────────────────────
    cd "$repo_dir" || return 1
    if [ -n "$custom_df" ] && [ -f "$dir/$custom_df" ]; then
        log "[$name] using custom Dockerfile from deployment folder: $custom_df"
        cp "$dir/$custom_df" Dockerfile
    elif [ ! -f Dockerfile ]; then
        if [ -f package.json ]; then
            log "[$name] no Dockerfile — using bundled node template"
            cp /app/templates/node.Dockerfile Dockerfile
        else
            log "[$name] ERROR: no Dockerfile and could not auto-detect project type"
            return 1
        fi
    fi

    # ── Build-time args (from .env, filtered by spec build.args globs) ─────
    local -a build_cli=()
    if [ -f "$envfile" ] && [ -n "$build_args" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value#\'}"; value="${value%\'}"
            value="${value#\"}"; value="${value%\"}"
            for pattern in $build_args; do
                if [[ "$key" == $pattern ]]; then
                    if ! grep -q "^ARG $key" Dockerfile 2>/dev/null; then
                        sed -i "0,/^FROM/{s/^FROM.*/&\nARG $key/}" Dockerfile
                    fi
                    build_cli+=("--build-arg" "$key=$value")
                    log "[$name]   build-arg: $key"
                    break
                fi
            done
        done < "$envfile"
    fi

    log "[$name] building $image"
    if ! docker build -t "$image" "${build_cli[@]}" . ; then
        log "[$name] build failed"
        return 1
    fi

    # ── (Re)create container ───────────────────────────────────────────────
    log "[$name] (re)creating container on network $NETWORK"
    docker rm -f "$name" >/dev/null 2>&1 || true

    local -a run_args=(
        -d
        --name "$name"
        --restart always
        --network "$NETWORK"
        -e "PORT=$port"
    )
    [ -f "$envfile" ]      && run_args+=( --env-file "$envfile" )
    [ -n "$host_port" ]    && run_args+=( -p "$host_port:$port" )

    if [ -n "$cmd" ]; then
        if ! docker run "${run_args[@]}" "$image" sh -c "$cmd" >/dev/null; then
            log "[$name] run failed"
            return 1
        fi
    else
        if ! docker run "${run_args[@]}" "$image" >/dev/null; then
            log "[$name] run failed"
            return 1
        fi
    fi

    log "[$name] deployed"
    return 0
}

# ── Main loop ────────────────────────────────────────────────────────────────
log "started — project=$COMPOSE_PROJECT_NAME network=$NETWORK interval=${POLL_INTERVAL}s"
ensure_network

while true; do
    shopt -s nullglob
    for dir in "$DEPLOYMENTS_DIR"/*/; do
        reconcile_one "$dir" || log "reconcile error in $(basename "$dir")"
    done
    shopt -u nullglob
    sleep "$POLL_INTERVAL"
done
