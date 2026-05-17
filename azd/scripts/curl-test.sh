#!/usr/bin/env bash
# Deploy a one-shot curl container into snet-aci to validate that the
# Container Apps environment L7 routes correctly to the UI and API apps.
# Returns non-zero exit code if either endpoint returns the env's
# "Container App is stopped or does not exist" 404 page.

set -euo pipefail

TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-240}"

echo "=== Container Apps L7 routing test ==="

ENV_JSON="$(azd env get-values --output json)"
RG="$(echo "$ENV_JSON" | jq -r '.AZURE_RESOURCE_GROUP')"
ACI_SUBNET_ID="$(echo "$ENV_JSON" | jq -r '.AZURE_ACI_SUBNET_ID')"
ENV_DOMAIN="$(echo "$ENV_JSON" | jq -r '.AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN')"
API_NAME="$(echo "$ENV_JSON" | jq -r '.SERVICE_WEB_NAME')"
UI_NAME="$(echo "$ENV_JSON" | jq -r '.SERVICE_UI_NAME')"
LOC="$(echo "$ENV_JSON" | jq -r '.AZURE_LOCATION')"

if [[ -z "$RG" || -z "$ACI_SUBNET_ID" || -z "$ENV_DOMAIN" || -z "$API_NAME" || -z "$UI_NAME" ]]; then
    echo "ERROR: Missing required azd env values." >&2
    exit 1
fi

API_FQDN="${API_NAME}.internal.${ENV_DOMAIN}"
UI_FQDN="${UI_NAME}.internal.${ENV_DOMAIN}"
TS="$(date +%H%M%S)"
ACI_NAME="curl-test-${TS}"
YAML_PATH="$(mktemp -t curl-test-XXXXXX.yaml)"

echo "Resource group:  $RG"
echo "Subnet:          $ACI_SUBNET_ID"
echo "API endpoint:    https://${API_FQDN}"
echo "UI endpoint:     https://${UI_FQDN}"
echo

cat > "$YAML_PATH" <<EOF
apiVersion: '2023-05-01'
location: ${LOC}
name: ${ACI_NAME}
properties:
  osType: Linux
  restartPolicy: Never
  subnetIds:
    - id: ${ACI_SUBNET_ID}
  containers:
    - name: curl
      properties:
        image: curlimages/curl:latest
        resources:
          requests:
            cpu: 0.5
            memoryInGB: 0.5
        command:
          - sh
          - -c
          - |
            set +e
            echo '=== UI HEAD https://${UI_FQDN}/ ==='
            curl -k -sS -I --max-time 30 https://${UI_FQDN}/
            echo ''
            echo '=== UI BODY https://${UI_FQDN}/ (first 400 bytes) ==='
            curl -k -sS --max-time 30 https://${UI_FQDN}/ | head -c 400
            echo ''
            echo '=== API HEAD https://${API_FQDN}/v0/servers ==='
            curl -k -sS -I --max-time 30 https://${API_FQDN}/v0/servers
            echo ''
            echo '=== API BODY https://${API_FQDN}/v0/servers (first 400 bytes) ==='
            curl -k -sS --max-time 30 https://${API_FQDN}/v0/servers | head -c 400
            echo ''
            echo '=== DONE ==='
type: Microsoft.ContainerInstance/containerGroups
EOF

cleanup() {
    echo
    echo "Cleaning up curl-test container instance..."
    az container delete --resource-group "$RG" --name "$ACI_NAME" --yes --output none 2>/dev/null || true
    rm -f "$YAML_PATH"
}
trap cleanup EXIT

echo "Creating curl-test container instance (${ACI_NAME})..."
az container create --resource-group "$RG" --file "$YAML_PATH" --output none

DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
STATE=""
while true; do
    sleep 5
    STATE="$(az container show --resource-group "$RG" --name "$ACI_NAME" --query 'instanceView.state' -o tsv 2>/dev/null || echo '')"
    echo "  state: $STATE"
    if [[ "$STATE" == "Succeeded" || "$STATE" == "Failed" ]]; then break; fi
    if [[ $(date +%s) -ge $DEADLINE ]]; then
        echo "WARNING: Container did not finish within ${TIMEOUT_SECONDS}s; continuing to fetch logs."
        break
    fi
done

echo
echo "=== curl-test logs ==="
LOGS="$(az container logs --resource-group "$RG" --name "$ACI_NAME" 2>/dev/null || echo '')"
echo "$LOGS"
echo "=== end logs ==="

if echo "$LOGS" | grep -qF 'Container App is stopped or does not exist'; then
    echo "ERROR: L7 routing FAILED: env returned the 'Container App is stopped or does not exist' 404 page for at least one endpoint." >&2
    exit 1
fi

echo
echo "L7 routing test PASSED. Both endpoints responded from the app (not the env router)."
exit 0
