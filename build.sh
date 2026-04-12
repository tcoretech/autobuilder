#!/bin/bash
# Build the autobuilder updater image.
# docker-compose.yml references `autobuilder:latest` with pull_policy: never.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build --pull -t autobuilder:latest "$SCRIPT_DIR/updater"
