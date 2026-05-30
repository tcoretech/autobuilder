# AutoBuilder

GitOps deployment engine for AI CoreKit. **One** autobuilder container manages **many** auto-built repositories, each described by a folder under `deployments/`.

The autobuilder polls the deployments folder and reconciles app containers directly via the Docker socket. Every `POLL_INTERVAL` seconds (default 60s) it fetches each deployment's branch, rebuilds the image when the deployment hash changes, and (re)creates the app container on the project's default network.

The deployment hash covers the fetched repo commit, `service.json`, `.env`, and any deployment-folder Dockerfile override. AutoBuilder stores that hash as Docker labels on the image and app container, so changes to runtime env, build args, ports, commands, volumes, or deployment Dockerfile content are reconciled even when the git commit is unchanged.

## Deployment anatomy

Each deployment is a folder containing a spec file, an env file, and optionally a Dockerfile override:

```
deployments/main-site/
├── service.json   # git repo, branch, token, port, build args, command (structured)
├── .env           # app environment variables (passed via --env-file)
└── Dockerfile     # (optional) custom Dockerfile if the repo doesn't have one
```

All `deployments/*/` folders are gitignored — tokens and app secrets stay off disk history. The `_example/` template is tracked as a starting point.

## service.json schema

```jsonc
{
  "name": "main-site",                       // must match folder name; becomes container name and image tag
  "git": {
    "repo":   "https://github.com/org/repo",
    "branch": "main",
    "token":  "ghp_…"                        // optional; only needed for private repos
  },
  "container": {
    "port":      3000,                       // port the app listens on inside the container
    "host_port": 3000,                       // optional; publish on host. Omit or null to keep internal
    "command":   "npm run preview -- --host" // optional; overrides Dockerfile CMD
  },
  "build": {
    "dockerfile":      null,                 // path inside the deployment folder; copied into the repo as `Dockerfile`
    "dockerfile_path": null,                 // path inside the cloned repo; passed via -f (context stays at repo root)
    "target":          null,                 // multi-stage build target (e.g. "runtime")
    "args":            ["VITE_*", "NEXT_PUBLIC_*"],  // glob patterns — matched against .env for --build-arg injection
    "args_map":        {}                    // explicit { KEY: "value" } build args, merged with the glob list
  },
  "volumes": [                               // optional bind mounts. Relative <src> paths resolve under
    "./data:/data",                          // <deployments-host-path>/<name>/<src>; absolute paths pass through.
    "./config/settings.env:/config/settings.env:ro"
  ],
  "post_build_run": {                        // optional one-shot run after each rebuild (e.g. db migrations)
    "dockerfile_path": "deploy/Dockerfile",  //   built with the same build_args as the main image
    "target":          "migrator",
    "command":         null                  //   optional override of the image's CMD
  }
}
```

`dockerfile_path` takes precedence over `dockerfile`. Specify at most one.

## .env (app env vars)

Pure, unprefixed environment variables for the running app container. They're passed via `--env-file` — no stripping, no filtering.

```bash
# deployments/main-site/.env
GEMINI_API_KEY=sk_live_...
SERVICE_ALLOWED_HOSTS=tcoretech.com,localhost,main-site
VITE_ALLOWED_HOSTS=tcoretech.com,localhost,main-site
```

## Build-time vs runtime env

| When | What gets through | Controlled by |
|---|---|---|
| `docker build` | Vars from `.env` whose keys match `build.args` globs — passed as `--build-arg` | `service.json` → `build.args` |
| Container runtime | Every var in `.env` — passed via `--env-file` | `.env` alone |

Frontend frameworks that inline env vars at compile time (Vite, Next.js, Create React App) need **build-time** args. Everything else lives happily in the runtime env.

## Managing deployments

AutoBuilder exposes a CLI via corekit's standard `run` command:

```bash
corekit run autobuilder help                  # show all commands
corekit run autobuilder list                  # list deployments + container status
corekit run autobuilder add my-app            # scaffold deployments/my-app/ from the template
corekit run autobuilder edit my-app           # edit service.json in $EDITOR
corekit run autobuilder show my-app           # print spec (token redacted) + .env
corekit run autobuilder rebuild my-app        # force an immediate rebuild
corekit run autobuilder migrate my-app        # run the deployment's post_build_run target on demand
corekit run autobuilder logs -f               # tail autobuilder logs
corekit run autobuilder app-logs my-app -f    # tail the app container's logs
corekit run autobuilder reload                # restart autobuilder to reconcile immediately
corekit run autobuilder remove my-app         # stop, delete image, delete folder
```

## Typical workflow

```bash
# 1. Scaffold a new deployment
corekit run autobuilder add landing-page

# 2. Configure it
$EDITOR services/custom-services/autobuilder/deployments/landing-page/service.json
$EDITOR services/custom-services/autobuilder/deployments/landing-page/.env

# 3. Start autobuilder (first time) or reload (already running)
corekit up autobuilder
# or: corekit run autobuilder reload

# 4. Watch the first build
corekit run autobuilder logs -f
```

## Dockerfile resolution

For each deployment, autobuilder uses the first of these it finds:

1. **In-repo Dockerfile by path** — set `build.dockerfile_path` in `service.json` to a path inside the cloned repo (e.g. `"deploy/docker/Dockerfile.web"`). Passed via `-f`; the build context stays at the repo root. Combines naturally with `build.target` for multi-stage Dockerfiles.
2. **Custom Dockerfile from the deployment folder** — set `build.dockerfile` to a path inside the deployment folder. Copied into the repo at build time.
3. **The repo's own `Dockerfile`** — used as-is.
4. **Auto-detected template** — if the repo has `package.json`, a bundled Node.js Dockerfile template is used.

## How it hangs together

```
corekit up autobuilder
  ├─ secrets.sh     (no-op)
  ├─ prepare.sh     → validates deployments/*/service.json, ensures data/repos/<name>/ dirs
  ├─ build.sh       → docker build ./updater -t autobuilder:latest
  ├─ docker compose up -d           (static compose: one service, `autobuilder`)
  └─ healthcheck.sh → confirms the autobuilder container is running

Inside the autobuilder container, every POLL_INTERVAL seconds:
  for each deployments/<name>/:
    ├─ read service.json (spec) and .env
    ├─ clone or fetch into /app/repos/<name>
    ├─ compute desired deployment hash from commit + spec + env + Dockerfile override
    ├─ if hash changed / missing image / missing, failed, or unhealthy container:
    │    ├─ build <name>:latest with the spec's build.args as --build-arg
    │    ├─ run automatic post_build_run, if configured
    │    └─ docker run -d --name <name> --network <project>_default --env-file .env <name>:latest
    └─ continue
```

All app containers live on the `<project>_default` network (e.g. `localai_default`), so Caddy and any other core-stack service can reach them by container name.

## Volume mounts

Add bind mounts in `service.json` under `volumes`. Each entry is a string of the form `<src>:<dst>[:flags]`:

- Relative `<src>` (e.g. `./data/api`) resolves to `<deployments-host-path>/<deployment-name>/<src>` on the host. The autobuilder learns its host path from the `DEPLOYMENTS_HOST_PATH` env var (set by `prepare.sh`).
- Absolute `<src>` passes through unchanged.

```jsonc
"volumes": [
  "./data/api:/data",
  "./data/music:/fixtures/music:ro",
  "./config/settings.env:/config/settings.env:ro"
]
```

## Post-build run (one-shot containers)

Some deployments need a side-effect container after each rebuild — database migrations being the classic case. Configure `post_build_run` in `service.json`:

```jsonc
"post_build_run": {
  "dockerfile_path": "deploy/docker/Dockerfile.web",
  "target":          "migrator",
  "command":         null,
  "auto":            true   // default true — fire every rebuild. Set false for manual-only.
}
```

When `auto` is true, the autobuilder builds the named target into `<name>-post:latest` after each successful main-image build, runs it once with `--rm --env-file .env --network <project>_default`, then proceeds to (re)create the long-running app container. If the automatic post-build run fails, deployment stops and the existing app container is left in place.

When `auto` is false, the spec stays dormant and you trigger it manually:

```bash
corekit run autobuilder migrate <name>
```

The CLI invokes `docker exec autobuilder /app/start.sh run-post <name>`, which performs the same build + run flow on demand regardless of the `auto` flag.

## Standalone usage (without corekit)

```bash
cd services/custom-services/autobuilder

# 1. Create a deployment folder
mkdir -p deployments/my-app
cp deployments/_example/service.json deployments/my-app/service.json
cp deployments/_example/.env.example  deployments/my-app/.env
$EDITOR deployments/my-app/service.json
$EDITOR deployments/my-app/.env

# 2. Build the updater image and start
bash prepare.sh
bash build.sh
docker compose -p localai up -d
```

## Migrating from a standalone service (e.g. main-site)

If you have an old service directory that was cloned from autobuilder:

```bash
corekit run autobuilder add main-site
# Copy values from services/custom-services/main-site/.env into:
#   deployments/main-site/service.json   (git, container, build.args)
#   deployments/main-site/.env           (app env vars only — GEMINI_API_KEY, VITE_*, etc.)

corekit disable main-site                     # drop the old service from profiles
corekit down main-site                        # stop the old container
corekit up autobuilder                        # autobuilder brings up main-site; name unchanged
```

The new container's name is the same (`main-site`), so any Caddy routes or cross-service references keep working.
