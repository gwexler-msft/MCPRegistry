#!/usr/bin/env bash
# Idempotently enable ACR artifact streaming (overlaybd) on the api and ui
# repos. New repos default to convertPushedImages=false, so without this hook
# the first images pushed to a fresh env never get the streaming format.

set -euo pipefail

ENV_JSON="$(azd env get-values --output json)"
REGISTRY_NAME="$(echo "$ENV_JSON" | jq -r '.AZURE_CONTAINER_REGISTRY_NAME')"
ENV_NAME="$(echo "$ENV_JSON" | jq -r '.AZURE_ENV_NAME')"

if [[ -z "$REGISTRY_NAME" || -z "$ENV_NAME" ]]; then
    echo "ERROR: Missing AZURE_CONTAINER_REGISTRY_NAME or AZURE_ENV_NAME from azd env." >&2
    exit 1
fi

for repo in "mcpregistry/api-${ENV_NAME}" "mcpregistry/ui-${ENV_NAME}"; do
    echo "Checking streaming on ${REGISTRY_NAME}/${repo}..."
    if ! az acr repository show --name "$REGISTRY_NAME" --repository "$repo" >/dev/null 2>&1; then
        echo "  Repo not yet pushed - skipping."
        continue
    fi
    current="$(az acr artifact-streaming show --name "$REGISTRY_NAME" --repository "$repo" --only-show-errors 2>/dev/null | jq -r '.convertPushedImages')"
    if [[ "$current" == "true" ]]; then
        echo "  Already enabled."
        continue
    fi
    echo "  Enabling auto-conversion..."
    az acr artifact-streaming update --name "$REGISTRY_NAME" --repository "$repo" --enable-streaming true --only-show-errors -o none
    echo "  Done."
done
