#!/bin/bash
# publish.sh - release the holly app to the fleet via AWS IoT Greengrass.
#
# Replaces push.sh (scp over the tailnet). Every release is a numbered component
# version deployed to the holly-fleet thing group: devices pull it themselves,
# a NUC that was offline updates when it reconnects, and a newly provisioned NUC
# receives the current version automatically when it enrols. Your Mac doesn't
# need to stay on.
#
# The component only delivers files (into C:\code\holly). It never launches the
# app - watchdog.ps1 on each NUC does that, in holly's interactive session.
# A mid-day release lands on disk immediately but is picked up when the app next
# starts: either tomorrow 08:30, or kill the app once and the watchdog relaunches
# it on the new code within seconds.
#
# Usage:
#   ./publish.sh            # auto-bump patch version, publish, deploy to fleet
#   ./publish.sh 1.4.0      # publish an explicit version
#
# Requires: aws CLI configured with your account, zip.
#
# ONE-TIME AWS SETUP (per account, not per PC):
#   1. Create the artifact bucket:
#        aws s3 mb s3://holly-greengrass-artifacts --region eu-west-2
#   2. Let the devices read it (role created by the Greengrass installer):
#        aws iam put-role-policy --role-name GreengrassV2TokenExchangeRole \
#          --policy-name holly-artifacts-read \
#          --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::holly-greengrass-artifacts/*"}]}'
set -euo pipefail

REGION=eu-west-2
BUCKET=holly-greengrass-artifacts
COMPONENT=com.holly.app
GROUP=holly-fleet
SRC=/Users/henryforrest/Documents/code/holly-code/holly   # local checkout of the app

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# ---- work out the version ----------------------------------------------
if [ -n "${1:-}" ]; then
  VERSION="$1"
else
  LATEST=$(aws greengrassv2 list-component-versions \
    --arn "arn:aws:greengrass:$REGION:$ACCOUNT:components:$COMPONENT" \
    --query 'componentVersions[0].componentVersion' --output text --region "$REGION" 2>/dev/null || echo "None")
  if [ "$LATEST" = "None" ] || [ -z "$LATEST" ]; then
    VERSION="1.0.0"
  else
    VERSION=$(echo "$LATEST" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
  fi
fi
echo "==> publishing $COMPONENT v$VERSION to $GROUP"

# ---- zip the app source + upload ----------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$SRC" && zip -rq "$TMP/holly.zip" . -x '.venv/*' -x '.git/*' -x '*/__pycache__/*')
# The watchdog rides along in every release (lands at C:\code\holly\watchdog.ps1),
# so watchdog fixes roll out fleet-wide like app code - no per-PC SSH.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
zip -jq "$TMP/holly.zip" "$SCRIPT_DIR/watchdog.ps1"
aws s3 cp "$TMP/holly.zip" "s3://$BUCKET/$COMPONENT/$VERSION/holly.zip" --region "$REGION"

# ---- component recipe ----------------------------------------------------
# Install only: Greengrass runs this as ggc_user in session 0, so it must never
# try to launch the GUI. robocopy mirrors the new code into C:\code\holly but
# leaves .venv alone (locked while the app runs; uv run re-syncs deps anyway).
# robocopy exit codes 0-7 all mean success, hence the exit-code translation.
cat > "$TMP/recipe.json" <<EOF
{
  "RecipeFormatVersion": "2020-01-25",
  "ComponentName": "$COMPONENT",
  "ComponentVersion": "$VERSION",
  "ComponentDescription": "Holly receptionist app source. Delivers files only - watchdog.ps1 launches the app.",
  "ComponentPublisher": "Vena",
  "Manifests": [
    {
      "Platform": { "os": "windows" },
      "Lifecycle": {
        "install": {
          "Script": "powershell -NoProfile -Command \"robocopy '{artifacts:decompressedPath}/holly' 'C:/code/holly' /MIR /XD .venv; if (\$LASTEXITCODE -le 7) { exit 0 } else { exit \$LASTEXITCODE }\"",
          "Timeout": 300
        }
      },
      "Artifacts": [
        {
          "URI": "s3://$BUCKET/$COMPONENT/$VERSION/holly.zip",
          "Unarchive": "ZIP"
        }
      ]
    }
  ]
}
EOF

aws greengrassv2 create-component-version \
  --inline-recipe "fileb://$TMP/recipe.json" --region "$REGION" > /dev/null

# wait for the new version to become deployable
ARN="arn:aws:greengrass:$REGION:$ACCOUNT:components:$COMPONENT:versions:$VERSION"
for i in $(seq 1 12); do
  STATE=$(aws greengrassv2 describe-component --arn "$ARN" \
    --query 'status.componentState' --output text --region "$REGION" 2>/dev/null || echo "PENDING")
  [ "$STATE" = "DEPLOYABLE" ] && break
  [ "$STATE" = "FAILED" ] && { echo "error: component build failed"; exit 1; }
  sleep 5
done
[ "$STATE" = "DEPLOYABLE" ] || { echo "error: component still $STATE after 60s"; exit 1; }

# ---- deploy to the fleet ---------------------------------------------------
# All devices update as soon as they see the deployment. A device that fails
# the deployment ROLLS BACK to its previous working version.
aws greengrassv2 create-deployment \
  --target-arn "arn:aws:iot:$REGION:$ACCOUNT:thinggroup/$GROUP" \
  --deployment-name "holly-app" \
  --components "{\"$COMPONENT\":{\"componentVersion\":\"$VERSION\"}}" \
  --deployment-policies '{"failureHandlingPolicy":"ROLLBACK"}' \
  --region "$REGION" --output text --query deploymentId

echo "done. v$VERSION deploying to $GROUP - watch per-device status with:"
echo "  aws greengrassv2 list-core-devices --region $REGION"
echo "or in the console: AWS IoT -> Greengrass -> Deployments"
