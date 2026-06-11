#!/usr/bin/env bash
# Hardening · tls-config
# Verifica configuração TLS dos hostnames públicos:
#  - TLS 1.0 e SSLv3 rejeitados (connection / protocol error).
#  - TLS 1.2 e 1.3 aceitos.
#  - Cert válido (não expirado, hostname bate).
#  - HSTS preload no response header (idem security-headers, mas via openssl).
# Esperado: depreciados rejeitados; modernos aceitos; cert válido.
# Falha = downgrade attack viável ou cert expirado.
#
# Skip se openssl ausente, ou se host é http://127.0.0.1 (sem TLS local).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · tls-config"

if ! command -v openssl >/dev/null 2>&1; then
  test_skip "openssl ausente"
  test_summary "hardening/tls-config"
  exit $TEST_EXIT_CODE
fi

# Lista de hostnames pra testar. Em prod, vem do DOMAIN_* do env.template.
HOSTS=(
  "${VIRALEFY_TEST_TLS_API:-api.viralefy.com}"
  "${VIRALEFY_TEST_TLS_WWW:-www.viralefy.com}"
  "${VIRALEFY_TEST_TLS_ADMIN:-admin.viralefy.com}"
)

# Test um protocolo: deve ficar igual a "ok" (esperado-aceitar) ou "reject"
# (esperado-rejeitar).
probe_proto() {
  local host="$1" flag="$2"
  # `s_client` com -servername (SNI) + -connect host:443. Stdin vazio + timeout.
  if echo "" | timeout 8 openssl s_client -connect "$host:443" \
       -servername "$host" "$flag" </dev/null \
       >/dev/null 2>&1; then
    echo "ok"
  else
    echo "reject"
  fi
}

for host in "${HOSTS[@]}"; do
  # Sanity de DNS.
  if ! getent hosts "$host" >/dev/null 2>&1; then
    test_skip "$host: DNS sem resolução" "rodando offline?"
    continue
  fi

  # TCP 443 alcançável?
  if ! timeout 3 bash -c "exec 3<>/dev/tcp/$host/443" 2>/dev/null; then
    test_skip "$host: TCP 443 inalcançável"
    continue
  fi

  # Protocolos depreciados — devem ser REJECT.
  for flag in -tls1 -ssl3; do
    case "$(probe_proto "$host" "$flag")" in
      reject) test_pass "$host: $flag rejeitado" ;;
      ok)     test_fail "$host: $flag ACEITO (downgrade viável)" ;;
    esac
  done

  # Protocolos modernos — devem ser OK.
  for flag in -tls1_2 -tls1_3; do
    case "$(probe_proto "$host" "$flag")" in
      ok)     test_pass "$host: $flag aceito" ;;
      reject) test_fail "$host: $flag rejeitado (modernos devem funcionar)" ;;
    esac
  done

  # Cert válido (chain + hostname). `-verify_return_error` retorna != 0
  # se hostname não bate ou cert expirado.
  if echo "" | timeout 8 openssl s_client -connect "$host:443" \
       -servername "$host" -verify_return_error \
       </dev/null >/dev/null 2>&1; then
    test_pass "$host: cert chain válido + hostname bate"
  else
    test_fail "$host: cert inválido / hostname não bate"
  fi

  # Dias até expirar (informativo + alerta).
  end_date="$(echo "" | timeout 5 openssl s_client -connect "$host:443" \
              -servername "$host" </dev/null 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null \
              | sed 's/^notAfter=//')"
  if [[ -n "$end_date" ]]; then
    end_epoch="$(date -d "$end_date" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    days_left=$(( (end_epoch - now_epoch) / 86400 ))
    if (( days_left < 7 )); then
      test_fail "$host: cert expira em $days_left dia(s)"
    elif (( days_left < 30 )); then
      test_skip "$host: cert expira em $days_left dia(s) (renovação Caddy automática)"
    else
      test_pass "$host: cert expira em $days_left dia(s)"
    fi
  fi

  # HSTS preload via curl HEAD HTTPS (independente do security-headers script).
  hsts="$(curl -sI --max-time 5 "https://$host/" 2>/dev/null | grep -i '^Strict-Transport-Security:')"
  if echo "$hsts" | grep -qi 'preload'; then
    test_pass "$host: HSTS preload no header"
  else
    test_fail "$host: HSTS preload ausente" "$hsts"
  fi
done

test_summary "hardening/tls-config"
exit $TEST_EXIT_CODE
