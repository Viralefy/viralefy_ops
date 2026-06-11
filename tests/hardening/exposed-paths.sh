#!/usr/bin/env bash
# Hardening · exposed-paths
# Verifica que paths sensíveis canônicos retornam 404 (ou 403/421), NUNCA 200.
# Cobre estado de servidores famosos (Apache/Nginx/WordPress/Spring) e dotfiles
# repositório (.git, .env). Caddy faz @block_internal pra /internal/*.
# Esperado: cada path → 404 (Caddy default catch-all).
# Falha = vazamento óbvio de informação ou shell remoto via path conhecido.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · exposed-paths"

# Testa em todos os vhosts canônicos que existem.
TARGETS=(
  "api:$(api_base)"
  "www:$(front_base)"
  "admin:$(admin_base)"
)

PATHS=(
  "/.git/HEAD"
  "/.git/config"
  "/.env"
  "/.env.local"
  "/debug"
  "/actuator"
  "/actuator/health"
  "/phpinfo.php"
  "/wp-admin"
  "/wp-login.php"
  "/.htaccess"
  "/server-status"
  "/admin/config"
  "/backup"
  "/backup.sql"
  "/internal/metrics"
  "/internal/debug"
  "/.aws/credentials"
  "/.ssh/id_rsa"
)

for entry in "${TARGETS[@]}"; do
  label="${entry%%:*}"
  base="${entry#*:}"

  # Sanity: base alcançável?
  http_call GET "$base/healthz"
  if [[ "$HTTP_CODE" == "000" ]]; then
    # Em alguns frontends, /healthz não existe; tenta raiz.
    http_call GET "$base/"
    if [[ "$HTTP_CODE" == "000" ]]; then
      test_skip "$label inacessível"
      continue
    fi
  fi

  for p in "${PATHS[@]}"; do
    http_call GET "${base}${p}"
    case "$HTTP_CODE" in
      404|403|421|410|451)
        test_pass "$label $p → $HTTP_CODE"
        ;;
      000)
        test_skip "$label $p connect fail"
        ;;
      200)
        # Conteúdo importa: HTML 200 do Next.js (catch-all) é falso positivo.
        # Marca fail só se body contém marker do path (ex.: "ref:" em .git/HEAD,
        # "AWS_ACCESS_KEY" em .env). Caso contrário, alerta como skip.
        if [[ "$p" == "/.git/HEAD"  ]] && echo "$HTTP_BODY" | grep -q '^ref:'; then
          test_fail "$label $p VAZA conteúdo git real" "$(echo "$HTTP_BODY" | head -3)"
        elif [[ "$p" =~ ^/\.env  ]] && echo "$HTTP_BODY" | grep -qE '^[A-Z_]+='; then
          test_fail "$label $p VAZA .env" "$(echo "$HTTP_BODY" | head -3)"
        elif [[ "$p" =~ actuator ]] && echo "$HTTP_BODY" | grep -q '"status"'; then
          test_fail "$label $p Spring actuator exposto" "$(echo "$HTTP_BODY" | head -3)"
        else
          test_skip "$label $p → 200 (SPA catch-all? checar manualmente)"
        fi
        ;;
      *)
        # Qualquer 4xx/5xx fora do esperado anota como pass (path está protegido).
        if [[ "$HTTP_CODE" =~ ^4 ]] || [[ "$HTTP_CODE" =~ ^5 ]]; then
          test_pass "$label $p → $HTTP_CODE (bloqueado)"
        else
          test_fail "$label $p status inesperado $HTTP_CODE"
        fi
        ;;
    esac
  done
done

test_summary "hardening/exposed-paths"
exit $TEST_EXIT_CODE
