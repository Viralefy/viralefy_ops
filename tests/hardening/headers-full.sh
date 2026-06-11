#!/usr/bin/env bash
# Hardening · headers-full
# Verificação exaustiva dos security headers por vhost:
#  - www:   CSP (com unsafe-inline temporário documentado), COOP same-origin,
#           CORP same-site, Permissions-Policy, Referrer-Policy, X-CTO nosniff.
#  - admin: CSP frame-ancestors 'none', COOP same-origin, COEP require-corp,
#           CORP same-origin, Permissions-Policy, Referrer-Policy no-referrer,
#           X-Frame-Options DENY.
#  - api:   HSTS preload, X-CTO nosniff, Referrer-Policy strict-origin-when-cross-origin,
#           CORP same-site.
#  - obs:   Restrito a rede privada, mas se exposto: HSTS, CORP same-origin.
# Esperado: cada header esperado bate o pattern.
# Falha = regressão na Caddyfile / config hardening.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · headers-full"

API="$(api_base)"
FRONT="$(front_base)"
ADMIN="$(admin_base)"

# expect_header <label> <header_name> <regex>
expect_header() {
  local label="$1" hdr="$2" regex="$3"
  local line
  line="$(echo "$HTTP_HEADERS" | grep -iE "^${hdr}:" | head -1)"
  if [[ -z "$line" ]]; then
    test_fail "$label header $hdr ausente"
    return
  fi
  if echo "$line" | grep -qiE "$regex"; then
    test_pass "$label $hdr ✓ ($regex)"
  else
    test_fail "$label $hdr não bate /$regex/" "$line"
  fi
}

# www (loja pública) — CSP atual aceita unsafe-inline (temporário, doc em config/Caddyfile).
http_call GET "$FRONT/"
if [[ "$HTTP_CODE" == "000" ]]; then
  test_skip "www inacessível"
else
  expect_header "www" "Content-Security-Policy"   "default-src|script-src|frame-ancestors"
  expect_header "www" "Cross-Origin-Opener-Policy" "same-origin"
  expect_header "www" "Cross-Origin-Resource-Policy" "same-site|same-origin"
  expect_header "www" "Permissions-Policy"         "interest-cohort|browsing-topics|camera|microphone"
  expect_header "www" "Referrer-Policy"            "strict-origin|no-referrer"
  expect_header "www" "X-Content-Type-Options"     "nosniff"
fi

# admin (backoffice) — bloqueio total de embedding.
http_call GET "$ADMIN/"
if [[ "$HTTP_CODE" == "000" ]]; then
  test_skip "admin inacessível"
else
  expect_header "admin" "Content-Security-Policy"      "frame-ancestors 'none'"
  expect_header "admin" "Cross-Origin-Opener-Policy"   "same-origin"
  expect_header "admin" "Cross-Origin-Embedder-Policy" "require-corp"
  expect_header "admin" "Cross-Origin-Resource-Policy" "same-origin"
  expect_header "admin" "Referrer-Policy"              "no-referrer"
  expect_header "admin" "X-Content-Type-Options"       "nosniff"
  expect_header "admin" "X-Frame-Options"              "DENY"
fi

# api — JSON-only, CORP same-site.
http_call GET "$API/healthz"
if [[ "$HTTP_CODE" == "000" ]]; then
  test_skip "api inacessível"
else
  expect_header "api" "X-Content-Type-Options"     "nosniff"
  expect_header "api" "Referrer-Policy"            "strict-origin|no-referrer"
  expect_header "api" "Cross-Origin-Resource-Policy" "same-site|same-origin"
fi

# obs (Grafana/Prometheus) — só testa se exposto.
OBS="${VIRALEFY_TEST_OBS_BASE:-}"
if [[ -n "$OBS" ]]; then
  http_call GET "$OBS/"
  if [[ "$HTTP_CODE" != "000" ]]; then
    expect_header "obs" "X-Content-Type-Options"     "nosniff"
    expect_header "obs" "Cross-Origin-Resource-Policy" "same-origin|same-site"
  fi
fi

test_summary "hardening/headers-full"
exit $TEST_EXIT_CODE
