#!/usr/bin/env bash
# Hardening · subdomain-takeover
# Para cada subdomínio conhecido, verifica se aponta pra recurso "dangling"
# (CNAME para S3 bucket inexistente, Heroku app não claimed, GitHub Pages
# unclaimed, etc.) — classic subdomain takeover via Detectify/EdOverflow's
# can-i-take-over-xyz signatures.
# Esperado: nenhum CNAME órfão.
# Falha = atacante pode hospedar conteúdo no subdomínio nosso → CSRF/cookie
# theft em escopo cross-subdomain.
# Skip se dig ausente.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · subdomain-takeover"

if ! command -v dig >/dev/null 2>&1; then
  test_skip "dig ausente"
  test_summary "hardening/subdomain-takeover"
  exit $TEST_EXIT_CODE
fi

ZONE="${VIRALEFY_TEST_ZONE:-viralefy.com}"

# Lista canônica + alguns staging/legacy que costumam ficar pendurados.
SUBS=(
  "www"
  "api"
  "admin"
  "cdn"
  "obs"
  "grafana"
  "staging"
  "dev"
  "test"
  "preview"
  "beta"
  "old"
)

# Provedores famosos com signature de takeover (substring de CNAME).
# Não detecta 100% — só sinaliza padrões.
SIGNATURES=(
  ".s3.amazonaws.com"
  ".herokuapp.com"
  ".github.io"
  ".netlify.app"
  ".vercel.app"
  ".cloudfront.net"
  ".azurewebsites.net"
  ".appspot.com"
  ".readthedocs.io"
  ".fastly.net"
  ".pantheonsite.io"
  ".s3-website"
  ".bitbucket.io"
)

for sub in "${SUBS[@]}"; do
  fqdn="${sub}.${ZONE}"
  cname="$(dig +short "$fqdn" CNAME 2>/dev/null | head -1)"
  if [[ -z "$cname" ]]; then
    # Sem CNAME = não é candidate a takeover (apontaria via A direto).
    continue
  fi
  printf '  %s%s → CNAME %s%s\n' "${C_DIM:-}" "$fqdn" "$cname" "${C_RST:-}"

  matched=""
  for sig in "${SIGNATURES[@]}"; do
    if [[ "$cname" == *"$sig"* ]]; then
      matched="$sig"
      break
    fi
  done

  if [[ -z "$matched" ]]; then
    test_pass "$fqdn: CNAME interno / sem signature pública de takeover"
    continue
  fi

  # Resolve A do alvo. Se NXDOMAIN ou sem A, é candidate a takeover.
  a_records="$(dig +short "$cname" A 2>/dev/null)"
  if [[ -z "$a_records" ]]; then
    test_fail "$fqdn: CNAME → $cname ($matched) sem resolução A — takeover candidate" \
              "verifique se o recurso ainda existe na conta correta"
  else
    test_pass "$fqdn: CNAME → $cname resolve ($matched, ok)"
  fi
done

test_summary "hardening/subdomain-takeover"
exit $TEST_EXIT_CODE
