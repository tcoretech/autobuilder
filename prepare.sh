#!/bin/bash
mkdir -p ./data/repo
mkdir -p ./config/local

chmod 755 ./data

# Bootstrap: create a placeholder image so docker compose doesn't fail before
# the updater has had a chance to build the real image from the git repo.
source .env
IMG=${SERVICE_IMAGE_NAME:-autobuilder:latest}
if ! docker image inspect "$IMG" > /dev/null 2>&1; then
    echo "[Bootstrap] Image $IMG not found. Creating placeholder..."
    docker pull alpine:latest
    docker tag alpine:latest "$IMG"
    echo "[Bootstrap] Placeholder image created."
fi
