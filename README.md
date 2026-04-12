# AutoBuilder

GitOps auto-deployment service for AI LaunchKit. Point it at any git repository and it will clone, build, and redeploy your application on every new commit.

## How it works

AutoBuilder runs two containers:

- **autobuilder** — the running application (built from your repo)
- **autobuilder-updater** — a sidecar that watches the git repo, rebuilds the Docker image on new commits, and recreates the app container

## Setup

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Configure your repository:
   ```bash
   # Required
   SERVICE_GIT_REPO='https://github.com/yourorg/your-app.git'

   # For private repos
   SERVICE_GIT_TOKEN='ghp_yourtoken'
   ```

3. Start:
   ```bash
   corekit up autobuilder
   ```

## Environment Variable Injection

AutoBuilder gives you fine-grained control over which variables from `.env` reach your app:

| Variable | Controls | Default |
|---|---|---|
| `RUNTIME_ENV_PASSTHROUGH` | Which vars are passed to the running container | `*` (all) |
| `BUILD_ARGS` | Which vars are passed as `--build-arg` during `docker build` | `VITE_* NEXT_* PUBLIC_* REACT_* NUKS_*` |

**Example:**
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
# Application logs
corekit logs autobuilder

# Updater / deployment logs
corekit logs autobuilder-updater
```
