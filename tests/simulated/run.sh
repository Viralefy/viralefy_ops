#!/usr/bin/env bash
# tests/simulated/run.sh
# Wrapper bash p/ o runner viralefy-test. Carrega lib.sh, prepara seeds e
# tokens via setup.sh, e invoca run.py com os args do caller.
#
# Exit code:
#   0 — todas as combinações classificadas como AUTO
#   1 — alguma combinação caiu em REVIEW (report.md aponta)
#   2 — engine quebrou (input inválido, setup falhou, etc.)

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "simulated · cross-matrix (routes × personas × injections)"

# Prepara seeds + tokens (não-fatal: setup.sh já avisa quando falta secret).
# shellcheck source=./setup.sh
source "$_DIR/simulated/setup.sh"

python3 "$_DIR/simulated/run.py" "$@"
engine_exit=$?

case "$engine_exit" in
  0)
    test_pass "matrix sweep limpa (sem REVIEW)"
    ;;
  1)
    test_fail "matrix tem items REVIEW — checar report.md no log_dir impresso acima"
    ;;
  *)
    test_fail "engine quebrou (exit=$engine_exit)" "ver stderr acima"
    ;;
esac

test_summary "simulated/cross-matrix"
exit $engine_exit
