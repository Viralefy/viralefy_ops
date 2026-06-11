#!/usr/bin/env bash
# Security · dependency-licenses
# Inspeciona licenças das dependências Node e enxerga se há alguma "copyleft
# forte" (GPL/AGPL/SSPL) — §13 das diretrizes proíbe distribuir software com
# essas licenças linkado estaticamente no nosso closed-source.
# Esperado: 0 GPL/AGPL/SSPL em dependências runtime.
# Falha = obrigação legal de release de código-fonte ou trocar dep.
#
# Skip se npm ausente ou nenhum package-lock.json. Ignora devDependencies.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · dependency-licenses"

if ! command -v npm >/dev/null 2>&1; then
  test_skip "npm ausente"
  test_summary "security/dependency-licenses"
  exit $TEST_EXIT_CODE
fi

ROOTS=(
  "${VIRALEFY_FRONT_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_front}"
  "${VIRALEFY_BACKOFFICE_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_backoffice}"
)

# Pacotes onde licença SSPL é aceita como dual-licensed com outra (ex.: alguns
# clientes mongo). Adicione no allowlist se ficar verde após review.
ALLOWLIST=""

audited=0
for root in "${ROOTS[@]}"; do
  if [[ ! -f "$root/package-lock.json" ]]; then
    test_skip "$root sem package-lock.json"
    continue
  fi
  audited=$((audited + 1))

  # `npm ls --all --json --omit=dev` dá árvore só de runtime.
  tree="$(cd "$root" && npm ls --all --json --omit=dev 2>/dev/null || true)"
  if [[ -z "$tree" ]]; then
    test_fail "$root: npm ls sem output"
    continue
  fi

  # Walk recursivo do tree pra extrair {name, version, license}.
  # `npm ls` nem sempre injeta license; complementamos lendo do package-lock.
  lock="$(cat "$root/package-lock.json")"

  bad="$(echo "$lock" | jq -r --arg allow "$ALLOWLIST" '
    .packages // {}
    | to_entries[]
    | select(.key != "")  # raiz
    | select(.value.dev != true)
    | {
        path: .key,
        name: (.value.name // (.key | sub("^node_modules/"; ""))),
        license: (
          if (.value.license | type) == "string" then .value.license
          elif (.value.license | type) == "object" then .value.license.type
          else "UNKNOWN" end
        )
      }
    | select(.license != null)
    | select(.license | test("(GPL|AGPL|SSPL)"; "i"))
    | select(.license | test("LGPL"; "i") | not)  # LGPL é OK pra link dinâmico
    | "\(.name)@\(.path): \(.license)"
  ' 2>/dev/null | sort -u)"

  if [[ -z "$bad" ]]; then
    test_pass "$root: 0 GPL/AGPL/SSPL em runtime deps"
  else
    count="$(echo "$bad" | wc -l | tr -d ' ')"
    sample="$(echo "$bad" | head -5 | tr '\n' ';')"
    test_fail "$root: $count dep(s) com licença forbidden" "$sample"
  fi
done

if (( audited == 0 )); then
  test_skip "nenhum package-lock.json encontrado"
fi

test_summary "security/dependency-licenses"
exit $TEST_EXIT_CODE
