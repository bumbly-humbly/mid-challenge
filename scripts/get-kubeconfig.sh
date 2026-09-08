#!/usr/bin/env bash
# Fetch a kubeconfig for your local machine (task 1: "kubectl get nodes"
# from the challenge-taker's own machine).
#
# The server was started with --tls-san for its public IP, so the API
# certificate is already valid for the address we rewrite in here.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

IP=$(terraform output -raw server_public_ip)
KEY=$(terraform output -raw ssh_private_key_path)
OUT="${1:-$PWD/../kubeconfig}"

ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    "ubuntu@$IP" "cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s#https://127.0.0.1:6443#https://$IP:6443#" > "$OUT"

chmod 600 "$OUT"

echo "Wrote $OUT"
echo
echo "  export KUBECONFIG=$OUT   # bash"
echo "  \$env:KUBECONFIG=\"$OUT\"  # PowerShell"
echo
echo "Then: kubectl get nodes"
