#!/bin/bash
# AutoBuilder updater — one process, many deployments.
# Scans /app/deployments/*/ every POLL_INTERVAL seconds. For each deployment:
#   - read service.json (spec) and .env (app env vars)
#   - clone/fetch the repo into /app/repos/<name>
#   - on first run or new commit: rebuild the image and (re)create the container
#
# App containers are created directly via `docker run` on the project's default
# network. CoreKit's generic child-label contract makes them discoverable even
# though they are not Docker Compose services themselves.

set -u

DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR:-/app/deployments}"
REPOS_DIR="${REPOS_DIR:-/app/repos}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-localai}"
NETWORK="${COMPOSE_PROJECT_NAME}_default"

# Host-side absolute path corresponding to DEPLOYMENTS_DIR inside this container.
# Required so `docker run -v` can mount deployment subdirs onto app containers
# (the docker daemon resolves volume paths on the host, not in this container).
DEPLOYMENTS_HOST_PATH="${DEPLOYMENTS_HOST_PATH:-}"

log() { echo "[autobuilder] $*"; }

ensure_network() {
    if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
        log "network $NETWORK not found — creating"
        docker network create "$NETWORK" >/dev/null || true
    fi
}

# Expand ${VAR} and ${VAR:-default} occurrences in $1 against the calling
# environment. Pure-bash, no eval, so safe to run on operator-supplied strings
# from service.json. Unset variables with no default render to an empty string.
expand_env_in() {
    local s="$1"
    local pattern='\$\{([A-Z_][A-Z0-9_]*)(:-([^}]*))?\}'
    while [[ "$s" =~ $pattern ]]; do
        local match="${BASH_REMATCH[0]}"
        local var="${BASH_REMATCH[1]}"
        local default_val="${BASH_REMATCH[3]}"
        local value
        if [ -n "${!var:-}" ]; then
            value="${!var}"
        else
            value="$default_val"
        fi
        local before="${s%%"$match"*}"
        local after="${s#*"$match"}"
        s="${before}${value}${after}"
    done
    printf '%s' "$s"
}

# Translate a deployment-relative host path (./foo or foo) into an absolute
# host path under DEPLOYMENTS_HOST_PATH/<name>. Absolute paths are passed
# through untouched. Environment variable references (${VAR} or
# ${VAR:-default}) are expanded first, so deployments can mount paths that
# live outside the deployment directory — e.g. shared test fixtures pinned
# via PYDJ_FIXTURES_DIR in the deployment's .env.
resolve_host_path() {
    local name="$1" rel="$2"
    rel="$(expand_env_in "$rel")"
    if [[ "$rel" == /* ]]; then
        echo "$rel"
        return
    fi
    rel="${rel#./}"
    if [ -z "$DEPLOYMENTS_HOST_PATH" ]; then
        log "[$name] WARN: DEPLOYMENTS_HOST_PATH unset; volume '$rel' may not resolve correctly"
        echo "$rel"
        return
    fi
    echo "${DEPLOYMENTS_HOST_PATH%/}/${name}/${rel}"
}

hash_file_or_empty() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        sha256sum "$file_path" | awk '{print $1}'
    fi
}

compute_config_hash() {
    local remote_sha="$1" spec="$2" envfile="$3" custom_dockerfile="$4" deploy_dir="$5"
    local custom_dockerfile_hash=""

    if [ -n "$custom_dockerfile" ] && [ -f "$deploy_dir/$custom_dockerfile" ]; then
        custom_dockerfile_hash="$(hash_file_or_empty "$deploy_dir/$custom_dockerfile")"
    fi

    {
        printf 'repo_sha=%s\n' "$remote_sha"
        printf 'service_json_sha=%s\n' "$(hash_file_or_empty "$spec")"
        printf 'env_sha=%s\n' "$(hash_file_or_empty "$envfile")"
        printf 'custom_dockerfile_sha=%s\n' "$custom_dockerfile_hash"
    } | sha256sum | awk '{print $1}'
}

container_label() {
    local container_name="$1" label_name="$2" label_value
    label_value=$(docker container inspect -f "{{ index .Config.Labels \"$label_name\" }}" "$container_name" 2>/dev/null || true)
    [ "$label_value" = "<no value>" ] && label_value=""
    echo "$label_value"
}

container_state() {
    local container_name="$1"
    docker container inspect -f '{{ .State.Status }}' "$container_name" 2>/dev/null || true
}

container_health() {
    local container_name="$1"
    docker container inspect -f '{{ if .State.Health }}{{ .State.Health.Status }}{{ end }}' "$container_name" 2>/dev/null || true
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

    local repo_url branch token port host_port cmd custom_df dockerfile_path target
    repo_url=$(    jq -r '.git.repo // ""'              "$spec")
    branch=$(      jq -r '.git.branch // "main"'        "$spec")
    token=$(       jq -r '.git.token // ""'             "$spec")
    port=$(        jq -r '.container.port // 3000'      "$spec")
    host_port=$(   jq -r '.container.host_port // empty' "$spec")
    cmd=$(         jq -r '.container.command // empty'  "$spec")
    custom_df=$(   jq -r '.build.dockerfile // ""'      "$spec")
    dockerfile_path=$(jq -r '.build.dockerfile_path // ""' "$spec")
    target=$(      jq -r '.build.target // ""'          "$spec")
    local -a build_arg_patterns=()
    mapfile -t build_arg_patterns < <(jq -r '.build.args // [] | .[]' "$spec")
    for pattern in "${build_arg_patterns[@]}"; do
        if [ "$pattern" = "*" ]; then
            log "[$name] WARN: build.args '*' passes every key from this deployment's .env as Docker build args; avoid this for secrets"
            break
        fi
    done

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
    local local_sha="" remote_sha=""
    if [ ! -d "$repo_dir/.git" ]; then
        log "[$name] cloning $repo_url ($branch)"
        rm -rf "$repo_dir"
        mkdir -p "$(dirname "$repo_dir")"
        if ! git clone -b "$branch" "$auth_url" "$repo_dir" >/dev/null 2>&1; then
            log "[$name] clone failed"
            return 1
        fi
        remote_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
        changed=1
    else
        (
            cd "$repo_dir" || exit 1
            git remote set-url origin "$auth_url"
            git fetch origin "$branch" >/dev/null 2>&1
        ) || { log "[$name] fetch failed"; return 1; }

        local_sha=$(  git -C "$repo_dir" rev-parse HEAD              2>/dev/null || echo "")
        remote_sha=$( git -C "$repo_dir" rev-parse "origin/$branch"  2>/dev/null || echo "")
        if [ "$local_sha" != "$remote_sha" ] && [ -n "$remote_sha" ]; then
            log "[$name] update: ${local_sha:0:7} -> ${remote_sha:0:7}"
            git -C "$repo_dir" reset --hard "origin/$branch" >/dev/null 2>&1 || true
            changed=1
        fi
    fi
    [ -n "$remote_sha" ] || remote_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")

    local config_hash
    config_hash="$(compute_config_hash "$remote_sha" "$spec" "$envfile" "$custom_df" "$dir")"

    # Also rebuild/run if the image is missing, container is failed/unhealthy,
    # or the desired deployment config differs from the running container.
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log "[$name] image missing: $image"
        changed=1
    fi

    local state_status health_status current_hash
    state_status="$(container_state "$name")"
    if [ -z "$state_status" ]; then
        log "[$name] container missing"
        changed=1
    elif [ "$state_status" != "running" ]; then
        log "[$name] container state is $state_status"
        changed=1
    else
        health_status="$(container_health "$name")"
        if [ "$health_status" = "unhealthy" ]; then
            log "[$name] container health is unhealthy"
            changed=1
        fi
    fi

    current_hash=""
    [ -n "$state_status" ] && current_hash="$(container_label "$name" "corekit.autobuilder.config-sha")"
    if [ -n "$state_status" ] && [ "$current_hash" != "$config_hash" ]; then
        if [ -n "$current_hash" ]; then
            log "[$name] config changed: ${current_hash:0:12} -> ${config_hash:0:12}"
        else
            log "[$name] config hash missing: ${config_hash:0:12}"
        fi
        changed=1
    fi

    [ "$changed" -eq 0 ] && return 0

    # ── Dockerfile resolution ──────────────────────────────────────────────
    # Precedence:
    #   1. build.dockerfile_path  — path inside the cloned repo; passed via -f,
    #      build context stays at repo root.
    #   2. build.dockerfile       — path inside the deployment folder, copied
    #      into the repo root as `Dockerfile` (legacy behaviour).
    #   3. repo's existing Dockerfile at the root.
    #   4. bundled node template if package.json is present.
    cd "$repo_dir" || return 1
    local build_file=""
    if [ -n "$dockerfile_path" ]; then
        if [ ! -f "$repo_dir/$dockerfile_path" ]; then
            log "[$name] ERROR: build.dockerfile_path '$dockerfile_path' not found in repo"
            return 1
        fi
        build_file="$dockerfile_path"
        log "[$name] using in-repo Dockerfile: $dockerfile_path"
    elif [ -n "$custom_df" ] && [ -f "$dir/$custom_df" ]; then
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

    # ── Build-time args ───────────────────────────────────────────────────
    # Two sources, merged:
    #   a) build.args (glob list) — keys matched against the .env file
    #   b) build.args_map (object) — explicit key:value pairs in service.json
    local -a build_cli=()

    # (a) .env-glob source
    # When the Dockerfile is autobuilder-managed (custom from deployment folder
    # or bundled template), inject `ARG KEY` after FROM so that build-args
    # work even if the source Dockerfile doesn't declare them. For in-repo
    # Dockerfiles (build.dockerfile_path), trust the author and skip injection.
    local inject_args=0
    if [ -z "$dockerfile_path" ]; then
        inject_args=1
    fi
    if [ -f "$envfile" ] && [ ${#build_arg_patterns[@]} -gt 0 ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value#\'}"; value="${value%\'}"
            value="${value#\"}"; value="${value%\"}"
            for pattern in "${build_arg_patterns[@]}"; do
                if [[ "$key" == $pattern ]]; then
                    if [ "$inject_args" -eq 1 ] && ! grep -q "^ARG $key" Dockerfile 2>/dev/null; then
                        sed -i "0,/^FROM/{s/^FROM.*/&\nARG $key/}" Dockerfile
                    fi
                    build_cli+=("--build-arg" "$key=$value")
                    log "[$name]   build-arg (from .env): $key"
                    break
                fi
            done
        done < "$envfile"
    fi

    # (b) explicit map source
    local args_map_keys
    args_map_keys=$(jq -r '.build.args_map // {} | keys[]?' "$spec" 2>/dev/null || true)
    if [ -n "$args_map_keys" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            local v
            v=$(jq -r --arg k "$key" '.build.args_map[$k] // ""' "$spec")
            build_cli+=("--build-arg" "$key=$v")
            log "[$name]   build-arg (from args_map): $key"
        done <<< "$args_map_keys"
    fi

    # ── Build ──────────────────────────────────────────────────────────────
    local -a build_cmd=(
        docker build
        --label "corekit.autobuilder=true"
        --label "corekit.autobuilder.parent=autobuilder"
        --label "corekit.autobuilder.project=$COMPOSE_PROJECT_NAME"
        --label "corekit.autobuilder.deployment=$name"
        --label "corekit.autobuilder.config-sha=$config_hash"
        --label "corekit.autobuilder.repo-sha=$remote_sha"
        --label "corekit.child=true"
        --label "corekit.parent.service=autobuilder"
        --label "corekit.project=$COMPOSE_PROJECT_NAME"
        --label "corekit.service=$name"
        -t "$image"
    )
    [ -n "$target"     ] && build_cmd+=( --target "$target" )
    [ -n "$build_file" ] && build_cmd+=( -f "$build_file" )
    build_cmd+=( "${build_cli[@]}" . )

    log "[$name] building $image${target:+ (target=$target)}${build_file:+ (-f $build_file)}"
    if ! "${build_cmd[@]}"; then
        log "[$name] build failed"
        return 1
    fi

    # ── post_build_run: one-shot container (e.g. migrations) ───────────────
    # Schema: { "dockerfile_path": "...", "target": "...", "command": "...",
    #           "image_tag": "..." (default <name>-post:latest),
    #           "auto":      true|false (default true; false = manual only) }
    local pbr_df pbr_target pbr_cmd pbr_image pbr_auto
    pbr_df=$(    jq -r '.post_build_run.dockerfile_path // ""' "$spec")
    pbr_target=$(jq -r '.post_build_run.target // ""'          "$spec")
    pbr_cmd=$(   jq -r '.post_build_run.command // ""'         "$spec")
    pbr_image=$( jq -r --arg n "$name" '.post_build_run.image_tag // ($n + "-post:latest")' "$spec")
    pbr_auto=$(  jq -r '.post_build_run.auto // true'          "$spec")

    if { [ -n "$pbr_df" ] || [ -n "$pbr_target" ]; } && [ "$pbr_auto" = "true" ]; then
        local -a pbr_build=(docker build -t "$pbr_image")
        [ -n "$pbr_target" ] && pbr_build+=( --target "$pbr_target" )
        [ -n "$pbr_df"     ] && pbr_build+=( -f "$pbr_df" )
        pbr_build+=( "${build_cli[@]}" . )

        log "[$name] post-build: building $pbr_image${pbr_target:+ (target=$pbr_target)}"
        if ! "${pbr_build[@]}"; then
            log "[$name] post-build image build failed"
            return 1
        fi

        local -a pbr_run=(
            docker run
            --rm
            --network "$NETWORK"
            --label "corekit.autobuilder=true"
            --label "corekit.autobuilder.parent=autobuilder"
            --label "corekit.autobuilder.project=$COMPOSE_PROJECT_NAME"
            --label "corekit.autobuilder.deployment=$name"
            --label "corekit.child=true"
            --label "corekit.parent.service=autobuilder"
            --label "corekit.project=$COMPOSE_PROJECT_NAME"
            --label "corekit.service=$name"
        )
        [ -f "$envfile" ] && pbr_run+=( --env-file "$envfile" )
        if [ -n "$pbr_cmd" ]; then
            pbr_run+=( "$pbr_image" sh -c "$pbr_cmd" )
        else
            pbr_run+=( "$pbr_image" )
        fi
        log "[$name] post-build: running $pbr_image"
        if ! "${pbr_run[@]}"; then
            log "[$name] post-build run failed; aborting deployment"
            return 1
        fi
    fi

    # ── (Re)create container ───────────────────────────────────────────────
    log "[$name] (re)creating container on network $NETWORK"
    docker rm -f "$name" >/dev/null 2>&1 || true

    local -a run_args=(
        -d
        --name "$name"
        --restart always
        --network "$NETWORK"
        --label "corekit.autobuilder=true"
        --label "corekit.autobuilder.parent=autobuilder"
        --label "corekit.autobuilder.project=$COMPOSE_PROJECT_NAME"
        --label "corekit.autobuilder.deployment=$name"
        --label "corekit.autobuilder.config-sha=$config_hash"
        --label "corekit.autobuilder.repo-sha=$remote_sha"
        --label "corekit.child=true"
        --label "corekit.parent.service=autobuilder"
        --label "corekit.project=$COMPOSE_PROJECT_NAME"
        --label "corekit.service=$name"
        -e "PORT=$port"
    )
    [ -f "$envfile" ]   && run_args+=( --env-file "$envfile" )
    [ -n "$host_port" ] && run_args+=( -p "$host_port:$port" )

    # Volumes: array of strings "<src>:<dst>[:flags]". <src> can be:
    #   - absolute host path (passed through),
    #   - relative path (resolved against DEPLOYMENTS_HOST_PATH/<name>/),
    #   - or either of the above with ${VAR} / ${VAR:-default} env references
    #     resolved against the deployment's .env (sourced in a subshell so
    #     vars don't leak between deployments).
    local vol_count
    vol_count=$(jq -r '.volumes // [] | length' "$spec")
    if [ "$vol_count" -gt 0 ]; then
        local i=0
        while [ "$i" -lt "$vol_count" ]; do
            local entry src rest
            entry=$(jq -r --argjson i "$i" '.volumes[$i]' "$spec")
            src="${entry%%:*}"
            rest="${entry#*:}"
            local abs
            abs="$(
                if [ -f "$envfile" ]; then
                    set -a
                    # shellcheck disable=SC1090
                    source "$envfile" 2>/dev/null || true
                    set +a
                fi
                resolve_host_path "$name" "$src"
            )"
            run_args+=( -v "${abs}:${rest}" )
            log "[$name]   volume: ${abs}:${rest}"
            i=$((i + 1))
        done
    fi

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

# ── Manual one-shot post_build_run (e.g. CLI-driven migrations) ──────────────
# Builds and runs the post_build_run target for a single deployment, regardless
# of git/image state. Invoked via `start.sh run-post <name>`.
run_post_only() {
    local name="$1"
    local dir="$DEPLOYMENTS_DIR/$name"
    local spec="$dir/service.json"
    local envfile="$dir/.env"
    [ -f "$spec" ] || { log "[$name] no service.json"; return 1; }

    local repo_url branch token
    repo_url=$(  jq -r '.git.repo // ""'    "$spec")
    branch=$(    jq -r '.git.branch // "main"' "$spec")
    token=$(     jq -r '.git.token // ""'   "$spec")
    local -a build_arg_patterns=()
    mapfile -t build_arg_patterns < <(jq -r '.build.args // [] | .[]' "$spec")
    for pattern in "${build_arg_patterns[@]}"; do
        if [ "$pattern" = "*" ]; then
            log "[$name] WARN: build.args '*' passes every key from this deployment's .env as Docker build args; avoid this for secrets"
            break
        fi
    done

    local pbr_df pbr_target pbr_cmd pbr_image
    pbr_df=$(    jq -r '.post_build_run.dockerfile_path // ""' "$spec")
    pbr_target=$(jq -r '.post_build_run.target // ""'          "$spec")
    pbr_cmd=$(   jq -r '.post_build_run.command // ""'         "$spec")
    pbr_image=$( jq -r --arg n "$name" '.post_build_run.image_tag // ($n + "-post:latest")' "$spec")

    if [ -z "$pbr_df" ] && [ -z "$pbr_target" ]; then
        log "[$name] no post_build_run configured"
        return 1
    fi

    local repo_dir="$REPOS_DIR/$name"
    if [ ! -d "$repo_dir/.git" ]; then
        log "[$name] cloning $repo_url ($branch) for post-build run"
        local auth_url="$repo_url"
        [ -n "$token" ] && auth_url="${repo_url/https:\/\//https:\/\/git:$token@}"
        rm -rf "$repo_dir"
        mkdir -p "$(dirname "$repo_dir")"
        git clone -b "$branch" "$auth_url" "$repo_dir" >/dev/null 2>&1 || { log "[$name] clone failed"; return 1; }
    fi

    cd "$repo_dir" || return 1

    local -a build_cli=()
    if [ -f "$envfile" ] && [ ${#build_arg_patterns[@]} -gt 0 ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value#\'}"; value="${value%\'}"
            value="${value#\"}"; value="${value%\"}"
            for pattern in "${build_arg_patterns[@]}"; do
                if [[ "$key" == $pattern ]]; then
                    build_cli+=("--build-arg" "$key=$value")
                    break
                fi
            done
        done < "$envfile"
    fi
    local args_map_keys
    args_map_keys=$(jq -r '.build.args_map // {} | keys[]?' "$spec" 2>/dev/null || true)
    if [ -n "$args_map_keys" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            local v
            v=$(jq -r --arg k "$key" '.build.args_map[$k] // ""' "$spec")
            build_cli+=("--build-arg" "$key=$v")
        done <<< "$args_map_keys"
    fi

    local -a pbr_build=(docker build -t "$pbr_image")
    [ -n "$pbr_target" ] && pbr_build+=( --target "$pbr_target" )
    [ -n "$pbr_df"     ] && pbr_build+=( -f "$pbr_df" )
    pbr_build+=( "${build_cli[@]}" . )

    log "[$name] post-build (manual): building $pbr_image"
    "${pbr_build[@]}" || { log "[$name] build failed"; return 1; }

    local -a pbr_run=(
        docker run
        --rm
        --network "$NETWORK"
        --label "corekit.autobuilder=true"
        --label "corekit.autobuilder.parent=autobuilder"
        --label "corekit.autobuilder.project=$COMPOSE_PROJECT_NAME"
        --label "corekit.autobuilder.deployment=$name"
        --label "corekit.child=true"
        --label "corekit.parent.service=autobuilder"
        --label "corekit.project=$COMPOSE_PROJECT_NAME"
        --label "corekit.service=$name"
    )
    [ -f "$envfile" ] && pbr_run+=( --env-file "$envfile" )
    if [ -n "$pbr_cmd" ]; then
        pbr_run+=( "$pbr_image" sh -c "$pbr_cmd" )
    else
        pbr_run+=( "$pbr_image" )
    fi
    log "[$name] post-build (manual): running $pbr_image"
    "${pbr_run[@]}"
}

prune_removed_deployments() {
    docker ps -a --filter "label=corekit.autobuilder=true" \
        --format "{{.Names}}\t{{.Label \"corekit.autobuilder.deployment\"}}\t{{.Label \"corekit.autobuilder.project\"}}" |
    while IFS=$'\t' read -r container_name deployment project_name; do
        [ -n "$container_name" ] || continue

        [ "$deployment" = "<no value>" ] && deployment=""
        [ "$project_name" = "<no value>" ] && project_name=""

        # Older AutoBuilder containers did not carry a project label. Treat
        # them as belonging to this updater so one upgrade can clean them up.
        if [ -n "$project_name" ] && [ "$project_name" != "$COMPOSE_PROJECT_NAME" ]; then
            continue
        fi

        [ -n "$deployment" ] || deployment="$container_name"
        if [ ! -f "$DEPLOYMENTS_DIR/$deployment/service.json" ]; then
            log "[$deployment] removing orphaned container $container_name: deployment folder is gone"
            docker rm -f "$container_name" >/dev/null 2>&1 || true
        fi
    done
}

# ── Entrypoint ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "run-post" ]; then
    run_post_only "$2"
    exit $?
fi

# ── Main loop ────────────────────────────────────────────────────────────────
log "started — project=$COMPOSE_PROJECT_NAME network=$NETWORK interval=${POLL_INTERVAL}s"
[ -n "$DEPLOYMENTS_HOST_PATH" ] && log "deployments host path: $DEPLOYMENTS_HOST_PATH"
ensure_network

while true; do
    shopt -s nullglob
    for dir in "$DEPLOYMENTS_DIR"/*/; do
        reconcile_one "$dir" || log "reconcile error in $(basename "$dir")"
    done
    shopt -u nullglob
    prune_removed_deployments
    sleep "$POLL_INTERVAL"
done
