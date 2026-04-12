#!/bin/bash
source "$PROJECT_ROOT/lib/utils/healthcheck.sh"
source .env

SERVICE_NAME=$(grep '"name":' service.json | cut -d '"' -f 4)
INTERNAL_PORT="${SERVICE_PORT:-3000}"

check_internal_service_http "$SERVICE_NAME" "$INTERNAL_PORT" "${SERVICE_NAME}-updater"
