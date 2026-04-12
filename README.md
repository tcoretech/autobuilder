# AutoBuilder

GitOps auto-deployment service for AI CoreKit. Point it at any git repository and it will clone, build, and redeploy your application on every new commit.

## How it works

AutoBuilder runs two containers:

- **autobuilder** — the running application (built from your repo)
- **autobuilder-updater** — a sidecar that watches the git repo, rebuilds the Docker image on new commits, and recreates the app container

## Usage

### Standalone (docker compose)

```bash
cp .env.example .env
# edit .env — set SERVICE_GIT_REPO at minimum
docker compose up -d
```

### Via AI CoreKit

```bash
corekit up autobuilder
```

## Configuration

Copy `.env.example` to `.env` and set:

```bash
# Required — repo to build and deploy
SERVICE_GIT_REPO='https://github.com/yourorg/your-app.git'

# Optional — for private repos
SERVICE_GIT_TOKEN='ghp_yourtoken'

# Optional — branch to track (default: main)
SERVICE_GIT_BRANCH='main'
```

## Environment Variable Injection

AutoBuilder gives you fine-grained control over which variables from `.env` reach your app:

| Variable | Controls | Default |
|---|---|---|
| `RUNTIME_ENV_PASSTHROUGH` | Which vars are passed to the running container | `*` (all) |
| `BUILD_ARGS` | Which vars are passed as `--build-arg` during `docker build` | `VITE_* NEXT_* PUBLIC_* REACT_* NUKS_*` |

**Example — restrict what reaches the container:**
```bash
RUNTIME_ENV_PASSTHROUGH='MYAPP_* DATABASE_*'
BUILD_ARGS='VITE_*'
```

## Auto-Detection

If your repo has no `Dockerfile`, AutoBuilder detects the project type and applies a default template:

| Detected | Template used |
|---|---|
| `package.json` | Node.js / npm |

## Logs

```bash
# Standalone
docker compose logs -f autobuilder
docker compose logs -f autobuilder-updater

# Via CoreKit
corekit logs autobuilder
corekit logs autobuilder-updater
```
