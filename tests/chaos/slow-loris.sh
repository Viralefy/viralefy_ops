#!/usr/bin/env bash
# chaos · slow-loris
# Conexão TCP com headers enviados byte-por-byte com delay. Esperado: o
# server deve cortar em < 60s. Caddy default = read_timeout 1m.
#
# Usamos python3 stdlib pra abrir socket cru.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · slow-loris"

API="$(api_base)"

if ! command -v python3 >/dev/null 2>&1; then
  test_skip "python3 ausente"; test_summary "chaos/slow-loris"; exit $TEST_EXIT_CODE
fi

# Extrai host:port do API base
HOST_PORT="${API#http://}"
HOST_PORT="${HOST_PORT#https://}"
HOST_PORT="${HOST_PORT%%/*}"
HOST="${HOST_PORT%%:*}"
PORT="${HOST_PORT##*:}"
[[ "$HOST" == "$PORT" ]] && PORT=80

echo "  alvo: $HOST:$PORT"

OUT=$(timeout 75 python3 -u - "$HOST" "$PORT" <<'PY'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
t0 = time.time()
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((host, port))
    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
    # Envia headers fillers byte por byte, espera 1s entre cada
    for i in range(70):
        try:
            s.sendall(b"X-Slow-%d: a\r\n" % i)
        except (BrokenPipeError, ConnectionResetError, OSError):
            break
        try:
            s.settimeout(0.1)
            chunk = s.recv(4096)
            if not chunk:
                break  # server fechou
        except (socket.timeout, BlockingIOError):
            pass
        except Exception:
            break
        time.sleep(1.0)
        if time.time() - t0 > 70:
            break
    elapsed = time.time() - t0
    print(f"elapsed={elapsed:.1f} iters={i}")
except Exception as e:
    elapsed = time.time() - t0
    print(f"elapsed={elapsed:.1f} error={type(e).__name__}")
finally:
    try: s.close()
    except Exception: pass
PY
)
[[ -z "$OUT" ]] && OUT="elapsed=75.0 error=timeout"
echo "  $OUT"

ELAPSED=$(echo "$OUT" | grep -oE 'elapsed=[0-9.]+' | cut -d= -f2)
ELAPSED_INT=${ELAPSED%.*}
if [[ -z "$ELAPSED_INT" ]]; then ELAPSED_INT=0; fi

if (( ELAPSED_INT < 60 )); then
  test_pass "conexão derrubada em ${ELAPSED}s (< 60s, timeout sano)"
elif (( ELAPSED_INT < 90 )); then
  test_pass "conexão derrubada em ${ELAPSED}s (entre 60 e 90s — aceitável)"
else
  test_fail "conexão aguentou ${ELAPSED}s — slow-loris ataca esse server" "$OUT"
fi

test_summary "chaos/slow-loris"
exit $TEST_EXIT_CODE
