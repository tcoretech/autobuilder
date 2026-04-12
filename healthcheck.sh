#!/bin/bash
# Verify the single autobuilder updater container is running.
if docker ps --format '{{.Names}}' | grep -q '^autobuilder$'; then
    echo "[OK] autobuilder is running"
    exit 0
else
    echo "[FAIL] autobuilder is not running"
    exit 1
fi
