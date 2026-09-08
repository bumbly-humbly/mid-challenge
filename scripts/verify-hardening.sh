#!/usr/bin/env bash
# Assert the Bonus I hardening from outside the cluster, and fail the deploy
# if any control is missing.
#
# Undocumented hardening is a claim; hardening nobody checks is a claim with
# a date on it. This is the difference between "we configured it" and "it is
# configured right now, on the thing serving traffic".
#
# Runs from the GitHub runner -- the public internet -- deliberately. Running
# it on a node would send the request to the Elastic IP, out through the
# internet gateway and back, which is the hairpin failure documented in
# terraform/user-data/server.sh.tftpl. It would also test a path no user takes.
#
# Usage: verify-hardening.sh <ingress-host>     (or set INGRESS_HOST)
set -euo pipefail

HOST="${1:-${INGRESS_HOST:-}}"
if [ -z "$HOST" ]; then
  echo "usage: $0 <ingress-host>   (e.g. 1.2.3.4.nip.io)" >&2
  exit 2
fi

# -k throughout: the certificate is self-signed by design, which the brief
# permits. This checks the TLS *configuration*, not the chain of trust.
CURL=(curl -sk --max-time 10)

FAILURES=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Wait for the site -----------------------------------------------------
# A changed HelmChartConfig makes helm-controller redeploy Traefik, which is
# asynchronous and outlives the rollout of the app itself. Without this the
# first run after a hardening change fails on timing rather than on substance.
echo "Waiting for https://$HOST ..."
for _ in $(seq 1 30); do
  CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://$HOST/" || echo 000)
  if [ "$CODE" = "200" ]; then
    break
  fi
  sleep 3
done
if [ "${CODE:-000}" != "200" ]; then
  echo "  FAIL  site never returned 200 (last: ${CODE:-none})" >&2
  exit 1
fi
echo

# --- Plaintext is redirected, not served -----------------------------------
echo "HTTP -> HTTPS redirect"
"${CURL[@]}" -I "http://$HOST/" >"$WORK/http.txt" || true
if head -n1 "$WORK/http.txt" | grep -q '30[18]'; then
  ok "plaintext answered with a permanent redirect"
else
  bad "expected 301 on http://, got: $(head -n1 "$WORK/http.txt")"
fi
if grep -qi '^location: https://' "$WORK/http.txt"; then
  ok "redirect target is https"
else
  bad "redirect does not point at https"
fi
echo

# --- OWASP Secure Headers --------------------------------------------------
echo "Security response headers (OWASP Secure Headers Project)"
"${CURL[@]}" -I "https://$HOST/" >"$WORK/https.txt" || true
for HEADER in \
  'strict-transport-security' \
  'content-security-policy' \
  'x-frame-options' \
  'x-content-type-options' \
  'referrer-policy' \
  'permissions-policy'; do
  if grep -qi "^$HEADER:" "$WORK/https.txt"; then
    ok "$HEADER"
  else
    bad "$HEADER missing"
  fi
done

# Absence matters too: the backend's version banner should not reach a client.
if grep -qi '^server:' "$WORK/https.txt"; then
  bad "Server banner leaked: $(grep -i '^server:' "$WORK/https.txt" | tr -d '\r')"
else
  ok "no Server version banner"
fi
echo

# --- TLS profile (Mozilla Intermediate) ------------------------------------
# nmap rather than `openssl s_client -tls1_1` or `curl --tls-max 1.1`: OpenSSL
# 3 on the runner refuses to *speak* TLS 1.1 at all, so a connection failure
# would prove nothing about the server and would pass this check for the
# wrong reason.
echo "TLS profile"
if ! command -v nmap >/dev/null 2>&1; then
  echo "  FAIL  nmap not installed -- cannot verify the TLS profile" >&2
  exit 1
fi
nmap --script ssl-enum-ciphers -p 443 "$HOST" >"$WORK/tls.txt" || true

# Prove the scan worked before trusting anything it did not find. Otherwise a
# blocked or failed scan reads as a clean result.
if grep -qE 'TLSv1\.[23]:' "$WORK/tls.txt"; then
  ok "scan reached the listener"
else
  echo "  FAIL  ssl-enum-ciphers returned no TLS 1.2/1.3 data -- scan failed, not a pass" >&2
  cat "$WORK/tls.txt" >&2
  exit 1
fi

for PROTO in TLSv1.0 TLSv1.1; do
  if grep -qF "$PROTO:" "$WORK/tls.txt"; then
    bad "$PROTO is offered"
  else
    ok "$PROTO refused"
  fi
done

# Match only the cipher lines. Searching the whole report reports a false
# positive on "compressors: NULL", which is the desired answer -- TLS-level
# compression is what CRIME attacks, so NULL there means compression is off.
grep -E '^\|.*[[:space:]]TLS_' "$WORK/tls.txt" > "$WORK/ciphers.txt" || true

if [ ! -s "$WORK/ciphers.txt" ]; then
  echo "  FAIL  no cipher lines parsed from the scan output" >&2
  cat "$WORK/tls.txt" >&2
  exit 1
fi

for WEAK in CBC 3DES RC4 NULL; do
  if grep -q "$WEAK" "$WORK/ciphers.txt"; then
    bad "weak cipher family offered: $WEAK"
  else
    ok "no $WEAK ciphers"
  fi
done
echo

# --- Result ----------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  echo "Hardening check FAILED: $FAILURES control(s) missing on https://$HOST" >&2
  exit 1
fi
echo "Hardening verified on https://$HOST"
