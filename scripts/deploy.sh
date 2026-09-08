#!/usr/bin/env bash
# Apply the Kubernetes manifests to the cluster.
#
# The path in is AWS Systems Manager, not kubectl-over-the-internet:
#   - the API server has no inbound rule for GitHub
#   - no kubeconfig is stored as a GitHub secret
#   - every deploy is a CloudTrail event with an identity attached
#
# Requires SERVER_INSTANCE_ID and AWS credentials (the workflow supplies both
# via OIDC). Run it locally with an admin profile and it behaves identically.
set -euo pipefail

: "${SERVER_INSTANCE_ID:?set SERVER_INSTANCE_ID (terraform output server_instance_id)}"

cd "$(dirname "$0")/.."

# The manifests travel inside the command rather than via S3 or a git clone on
# the node: no extra bucket, no repo credentials on the instance. ~9 KB against
# an SSM limit of 100 KB.
PAYLOAD=$(tar czf - -C k8s . | base64 -w0)

REMOTE=$(cat <<'SCRIPT'
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# INGRESS_HOST and NODE_CIDR were written by Terraform at boot.
. /etc/k3s-demo/env

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "__PAYLOAD__" | base64 -d | tar xzf - -C "$WORK"
sed -i "s|__INGRESS_HOST__|$INGRESS_HOST|g; s|__NODE_CIDR__|$NODE_CIDR|g" "$WORK"/*.yaml

kubectl apply -f "$WORK"

# The gate. A pipeline that goes green without rolling anything out is worse
# than one that goes red.
kubectl rollout status deployment/hello --timeout=180s

echo
kubectl get pods -o wide -l app=hello
echo
echo "Serving on https://$INGRESS_HOST"
SCRIPT
)
REMOTE=${REMOTE/__PAYLOAD__/$PAYLOAD}

# The whole remote script is base64-encoded before it goes into the SSM
# parameter JSON. Base64 contains no quotes, backslashes or newlines, so there
# is nothing to escape and no dependency on jq -- which matters because this
# script is also run by hand from a Windows workstation.
ENCODED=$(printf '%s' "$REMOTE" | base64 -w0)

# Written next to the repo rather than in /tmp: on Windows the AWS CLI is a
# native binary and cannot resolve Git Bash virtual paths like /tmp/xxx.
PARAMS=$(mktemp ./.ssm-params.XXXXXX)
trap 'rm -f "$PARAMS"' EXIT
printf '{"commands":["echo %s | base64 -d | bash"]}\n' "$ENCODED" > "$PARAMS"

CMD_ID=$(aws ssm send-command \
  --instance-ids "$SERVER_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "deploy ${GITHUB_SHA:-manual}" \
  --parameters "file://$PARAMS" \
  --query Command.CommandId --output text)

echo "SSM command: $CMD_ID"

# Brief pause: the invocation is not immediately queryable after send-command.
sleep 5
aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$SERVER_INSTANCE_ID" || true

invocation() {
  aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$SERVER_INSTANCE_ID" \
    --query "$1" --output text
}

STATUS=$(invocation Status)

echo "--- stdout ---"
invocation StandardOutputContent

ERR=$(invocation StandardErrorContent)
if [ -n "$ERR" ]; then
  echo "--- stderr ---"
  echo "$ERR"
fi

if [ "$STATUS" != "Success" ]; then
  echo "Deploy failed: $STATUS" >&2
  exit 1
fi

# Hand the host to the next workflow step, which asserts the hardening against
# it from the public internet. Only the server knows this value -- Terraform
# wrote it to /etc/k3s-demo/env at boot -- so it is parsed back out of the
# remote output rather than duplicated as a GitHub variable that could drift.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  HOST=$(invocation StandardOutputContent | sed -n 's#^Serving on https://##p' | tail -1)
  if [ -z "$HOST" ]; then
    echo "Could not determine ingress host from the deploy output" >&2
    exit 1
  fi
  echo "ingress_host=$HOST" >> "$GITHUB_OUTPUT"
  echo "ingress_host=$HOST"
fi

echo "Deploy succeeded."
