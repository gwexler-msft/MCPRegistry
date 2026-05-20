#!/usr/bin/env bash
# Patches the UI AAD app registration's web redirect URI to the actual UI
# container app FQDN. See set-aad-redirect.ps1 for full explanation.

set -euo pipefail

echo "Patching UI app registration redirect URI..."

uiAppId=$(azd env get-value AZURE_UI_APP_CLIENT_ID 2>/dev/null || true)
uiUrl=$(azd env get-value UI_URL 2>/dev/null || true)

if [ -z "$uiAppId" ]; then
    echo "ERROR: AZURE_UI_APP_CLIENT_ID not set in azd env. Did the preprovision hook run?" >&2
    exit 1
fi
if [ -z "$uiUrl" ]; then
    echo "ERROR: UI_URL not set in azd env. Did 'azd provision' succeed?" >&2
    exit 1
fi

callbackUrl="$uiUrl/signin-oidc"
signoutCallbackUrl="$uiUrl/signout-callback-oidc"
logoutUrl="$uiUrl/MicrosoftIdentity/Account/SignedOut"
echo "  UI app:                $uiAppId"
echo "  Sign-in callback:      $callbackUrl"
echo "  Sign-out callback:     $signoutCallbackUrl"

uiApp=$(az ad app show --id "$uiAppId" -o json)
uiObjectId=$(echo "$uiApp" | jq -r '.id')
hasSignin=$(echo "$uiApp" | jq --arg url "$callbackUrl" '.web.redirectUris | index($url)')
hasSignout=$(echo "$uiApp" | jq --arg url "$signoutCallbackUrl" '.web.redirectUris | index($url)')

if [ "$hasSignin" != "null" ] && [ "$hasSignout" != "null" ]; then
    echo "  Redirect URIs already present. Nothing to patch."
    exit 0
fi

patch=$(echo "$uiApp" | jq --arg signin "$callbackUrl" --arg signout "$signoutCallbackUrl" --arg logout "$logoutUrl" \
    '{
        web: {
            redirectUris: ((.web.redirectUris // []) + [$signin, $signout] | unique),
            logoutUrl: $logout,
            implicitGrantSettings: {
                enableIdTokenIssuance: true,
                enableAccessTokenIssuance: false
            }
        }
    }')

az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$uiObjectId" \
    --headers "Content-Type=application/json" \
    --body "$patch" >/dev/null

echo "  Redirect URIs added."
