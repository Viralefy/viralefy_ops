#!/usr/bin/env bash
# unit · delega para o test runner nativo de cada serviço.
#
# Go: go test -cover -race ./...
# Node/Nest: npm test (ou vitest run)
# Next.js: vitest run / jest
#
# Roda dentro de /viralefy/<svc>/ se existir. Quando o repo do svc não
# estiver presente no host (dev local sem clone), faz skip silencioso.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "unit · delega para runners nativos"

ROOT="${VIRALEFY_ROOT:-/viralefy}"

run_go() {
  local pkg="$1" dir="$ROOT/$pkg"
  if [[ ! -d "$dir" ]]; then
    test_skip "go test ./$pkg" "$dir ausente"
    return
  fi
  if ! command -v go >/dev/null 2>&1 && [[ ! -x /usr/local/go/bin/go ]]; then
    test_skip "go test ./$pkg" "go binary ausente"
    return
  fi
  local out
  out="$(cd "$dir" && PATH="/usr/local/go/bin:$PATH" go test -cover ./... 2>&1)"
  if [[ $? -eq 0 ]]; then
    test_pass "go test ./$pkg ok"
  else
    test_fail "go test ./$pkg falhou" "$out"
  fi
}

run_node() {
  local pkg="$1" dir="$ROOT/$pkg"
  if [[ ! -d "$dir" ]]; then
    test_skip "npm test ./$pkg" "$dir ausente"
    return
  fi
  if [[ ! -f "$dir/package.json" ]]; then
    test_skip "npm test ./$pkg" "package.json ausente"
    return
  fi
  if ! grep -q '"test"' "$dir/package.json"; then
    test_skip "npm test ./$pkg" "sem script 'test' em package.json"
    return
  fi
  local out
  out="$(cd "$dir" && npm test --silent 2>&1)"
  if [[ $? -eq 0 ]]; then
    test_pass "npm test ./$pkg ok"
  else
    test_fail "npm test ./$pkg falhou" "$out"
  fi
}

# Go services
for pkg in api payments sender core auth; do
  run_go "$pkg"
done

# Node services
for pkg in front backoffice; do
  run_node "$pkg"
done

test_summary "unit/run"
exit $TEST_EXIT_CODE
