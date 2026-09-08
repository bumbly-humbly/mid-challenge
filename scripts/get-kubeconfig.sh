#!/usr/bin/env bash
# Fetch a kubeconfig for your local machine (task 1: "kubectl get nodes" from
# the challenge-taker's own machine) and merge it into ~/.kube/config as a
# context named "cgi-k3s".
#
# Merging rather than just writing a file is deliberate: needing to export
# KUBECONFIG in every shell is a bad thing to be fumbling with in front of an
# audience. After this, plain `kubectl get nodes` works anywhere.
#
# Safe to re-run. After a cluster rebuild the CA and client certificate change,
# and re-running replaces the stale context with the new credentials.
set -euo pipefail

CONTEXT=cgi-k3s

cd "$(dirname "$0")/../terraform"

IP=$(terraform output -raw server_public_ip)
KEY=$(terraform output -raw ssh_private_key_path)
STANDALONE="$PWD/../kubeconfig"

# The server was started with --tls-san for its public IP, so the API
# certificate is already valid for the address substituted in here.
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ubuntu@$IP" "cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s#https://127.0.0.1:6443#https://$IP:6443#" > "$STANDALONE"
chmod 600 "$STANDALONE"

# k3s names the cluster, user and context all "default". Rename so this cluster
# is identifiable alongside any others already in the config.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
sed -e "s/^  name: default\$/  name: $CONTEXT/" \
    -e "s/^- name: default\$/- name: $CONTEXT/" \
    -e "s/^    cluster: default\$/    cluster: $CONTEXT/" \
    -e "s/^    user: default\$/    user: $CONTEXT/" \
    -e "s/^current-context: default\$/current-context: $CONTEXT/" \
    "$STANDALONE" > "$TMP"

mkdir -p "$HOME/.kube"
touch "$HOME/.kube/config"
cp "$HOME/.kube/config" "$HOME/.kube/config.bak.$(date +%s)"

# The new file comes first, so on a rebuild its credentials win over the stale
# context of the same name rather than being discarded as a duplicate.
MERGED=$(mktemp)
KUBECONFIG="$TMP:$HOME/.kube/config" kubectl config view --flatten > "$MERGED"
mv "$MERGED" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

kubectl config use-context "$CONTEXT" >/dev/null

echo "Merged context '$CONTEXT' into ~/.kube/config (previous config backed up)."
echo "A standalone copy is also at $STANDALONE"
echo
kubectl get nodes
