#!/usr/bin/env python3
"""
Simulated test engine — cruza rotas × personas × injections exaustivamente.

Implementa §22.3 do plano (categoria 'simulated'). Stdlib-only (Python 3.11+).

Inputs (no diretório do script):
  routes-inventory.json
  personas.json
  injections.json

Variáveis de ambiente:
  VIRALEFY_TEST_API_BASE      base do dispatcher       (default http://127.0.0.1:8090)
  VIRALEFY_TEST_LOG_DIR       diretório-pai dos logs   (default /var/log/viralefy ou /tmp)
  VIRALEFY_SIM_MAX_ROUTES     trunca o inventário      (default 200)
  VIRALEFY_SIM_SKIP_MUTATIONS '1' pula POST/PUT/PATCH/DELETE
  VIRALEFY_SIM_TIMEOUT        timeout HTTP seg         (default 10)
  VIRALEFY_SIM_TOKEN_USER     bearer token p/ persona normal_user
  VIRALEFY_SIM_TOKEN_ADMIN    bearer token p/ persona normal_admin
  VIRALEFY_SIM_TOKEN_SUPERADMIN bearer token p/ persona superadmin
  VIRALEFY_SIM_API_KEY        valor de X-API-Key p/ persona b2b_key

Outputs (em <log_dir>/sim-<timestamp>/):
  raw.jsonl       — uma linha por request
  report.md       — sumário human-readable (seções AUTO / REVIEW)
  summary.json    — totais agregados

Classificação (status field):
  auto    — comportamento ESPERADO (status HTTP no expected_status e acesso
            bate com persona.expected_access[route.category]; ou injection
            não-control retornou 4xx/429).
  review  — algo merece olho humano (status fora do esperado, persona com
            'deny' bateu 2xx, injection com payload malicioso passou).

Exit code: 1 se houver qualquer 'review', 0 caso contrário.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent


# ─── IO ────────────────────────────────────────────────────────────────────

def load_json(filename: str) -> dict[str, Any]:
    path = SCRIPT_DIR / filename
    if not path.exists():
        die(f"input file missing: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        die(f"invalid JSON in {path}: {e}")
        return {}  # unreachable


def die(msg: str) -> None:
    sys.stderr.write(f"simulated/run.py: error: {msg}\n")
    sys.exit(2)


# ─── Resolução de injection → payload ──────────────────────────────────────

def materialize_value(inj: dict[str, Any]) -> Any:
    """Resolve o `value` de uma injection, expandindo value_repeat se houver."""
    if "value_repeat" in inj:
        spec = inj["value_repeat"]
        return spec["char"] * int(spec["count"])
    return inj.get("value")


# ─── Construção da request ─────────────────────────────────────────────────

def build_request(
    api_base: str,
    route: dict[str, Any],
    persona: dict[str, Any],
    injection: dict[str, Any],
) -> tuple[str, dict[str, str], bytes | None]:
    """Devolve (url, headers, body)."""
    path = route["path"]
    method = route["method"].upper()
    inj_type = injection.get("type", "control")
    inj_value = materialize_value(injection)

    # ─ Path: substitui qualquer UUID-placeholder por injection.value quando
    # o injection é path-traversal. Outros tipos ficam só no query/body.
    if inj_type == "path" and inj_value is not None:
        path = path.replace(
            "00000000-0000-0000-0000-000000000000",
            urllib.parse.quote(str(inj_value), safe=""),
        )

    # ─ Query string para tipos textuais
    query = ""
    if inj_type in ("sqli", "xss", "encoding", "size") and inj_value is not None:
        # Limita size do query (browser/servidor capa a URL em ~8KB);
        # injections maiores vão pelo body em métodos com body.
        q_value = str(inj_value)
        if len(q_value) > 4096 and method == "GET":
            q_value = q_value[:4096]
        query = "?q=" + urllib.parse.quote(q_value, safe="")

    url = api_base.rstrip("/") + path + query

    # ─ Headers
    headers: dict[str, str] = {
        "User-Agent": "viralefy-simulated-engine/1.0",
        "Accept": "application/json",
    }

    auth = persona.get("auth", {}) or {"kind": "none"}
    kind = auth.get("kind", "none")
    if kind in ("jwt-user", "jwt-admin"):
        token = (
            auth.get("token_literal")
            or os.getenv(auth.get("token_env", ""), "")
        )
        if token:
            headers["Authorization"] = f"Bearer {token}"
        # se vazio, persona vira efetivamente anon — vamos rastrear no result.
    elif kind == "api-key":
        token = os.getenv(auth.get("token_env", ""), "")
        if token:
            headers[auth.get("header", "X-API-Key")] = token
    elif kind == "internal-token":
        token = os.getenv(auth.get("token_env", ""), "")
        if token:
            headers["X-Internal-Token"] = token

    # Header smuggle injection adiciona um header extra.
    if inj_type == "header_smuggle":
        headers[injection["header_name"]] = injection["header_value"]

    # ─ Body para métodos com body
    body: bytes | None = None
    if method in ("POST", "PUT", "PATCH"):
        body_dict: dict[str, Any] = {
            "email": "sim@viralefy.test",
            "name": "sim",
            "q": str(inj_value) if inj_value is not None else "sim",
        }
        if inj_type == "mass_assign":
            body_dict.update(injection.get("extra_fields", {}))
        # Para webhooks, deixa body mínimo + signature dummy — esperado é
        # 400/401, e isso já confirma que o validador de assinatura está
        # ligado.
        body = json.dumps(body_dict).encode("utf-8")
        headers["Content-Type"] = "application/json"
        # Idempotency-Key para evitar 409 acidental em POSTs idempotentes.
        headers["Idempotency-Key"] = f"sim-{persona['name']}-{injection['name']}-{int(time.time()*1000)}"

    return url, headers, body


# ─── Execução de uma request ───────────────────────────────────────────────

def run_one(
    api_base: str,
    route: dict[str, Any],
    persona: dict[str, Any],
    injection: dict[str, Any],
    timeout: float,
) -> dict[str, Any]:
    url, headers, body = build_request(api_base, route, persona, injection)
    method = route["method"].upper()

    start = time.time()
    http_code = 0
    err = ""
    resp_body = ""
    resp_headers: dict[str, str] = {}

    try:
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            http_code = resp.status
            raw = resp.read(4096)
            resp_body = raw.decode("utf-8", errors="replace")
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as e:
        http_code = e.code
        try:
            raw = e.read(4096) if e.fp is not None else b""
            resp_body = raw.decode("utf-8", errors="replace")
        except Exception:
            resp_body = ""
        try:
            resp_headers = {k.lower(): v for k, v in e.headers.items()} if e.headers else {}
        except Exception:
            resp_headers = {}
    except urllib.error.URLError as e:
        http_code = 0
        err = f"URLError: {e.reason}"
    except TimeoutError:
        http_code = 0
        err = "timeout"
    except Exception as e:  # noqa: BLE001
        http_code = 0
        err = f"{type(e).__name__}: {e}"

    latency_ms = (time.time() - start) * 1000.0

    classification, reasons = classify(route, persona, injection, http_code, resp_body, err)

    return {
        "route": route["path"],
        "method": method,
        "category": route["category"],
        "persona": persona["name"],
        "injection": injection["name"],
        "injection_type": injection.get("type", "control"),
        "url": url,
        "http_code": http_code,
        "latency_ms": round(latency_ms, 1),
        "status": classification,
        "reasons": reasons,
        "err": err,
        "body_truncated": resp_body[:500],
        "resp_content_type": resp_headers.get("content-type", ""),
    }


# ─── Classificação auto/review ─────────────────────────────────────────────

OK_DENY_CODES = {401, 403}
ALWAYS_OK_CODES = {404, 405, 415, 422, 429}


def classify(
    route: dict[str, Any],
    persona: dict[str, Any],
    injection: dict[str, Any],
    http_code: int,
    body: str,
    err: str,
) -> tuple[str, list[str]]:
    reasons: list[str] = []
    expected_codes = set(route.get("expected_status") or [])
    category = route.get("category", "public")
    access = persona.get("expected_access", {}).get(category, "deny")
    inj_type = injection.get("type", "control")
    is_control = inj_type == "control"

    # Falha de transporte completa — REVIEW (serviço pode estar fora).
    if http_code == 0:
        reasons.append(f"transport error: {err or 'unknown'}")
        return "review", reasons

    # Server errors são sempre REVIEW.
    if http_code >= 500:
        reasons.append(f"server error {http_code}")
        return "review", reasons

    # ── Baseline (control) ────────────────────────────────────────────
    if is_control:
        if access == "allow":
            # Esperado 2xx OU 4xx documentado (ex.: 404 com placeholder UUID).
            if http_code in expected_codes or 200 <= http_code < 300 or http_code in ALWAYS_OK_CODES:
                return "auto", reasons
            reasons.append(f"allow but http={http_code} not in expected={sorted(expected_codes)}")
            return "review", reasons
        if access == "deny":
            if http_code in OK_DENY_CODES:
                return "auto", reasons
            # alguns endpoints aceitam anonymous opcional (ex.: /v1/checkout
            # com optionalUserAuth). Aceita 2xx/4xx documentados também,
            # mas registra com nota.
            if http_code in expected_codes or http_code in ALWAYS_OK_CODES:
                reasons.append(f"deny-persona got {http_code} (expected_status permits)")
                return "auto", reasons
            reasons.append(f"deny-persona got {http_code} (no 401/403)")
            return "review", reasons
        if access == "partial":
            # persona admin sem todas as permissões — qualquer 2xx/403 é OK.
            if http_code in OK_DENY_CODES or (200 <= http_code < 300) or http_code in ALWAYS_OK_CODES:
                return "auto", reasons
            reasons.append(f"partial-access got {http_code}")
            return "review", reasons
        reasons.append(f"unknown access policy '{access}'")
        return "review", reasons

    # ── Injection não-control ────────────────────────────────────────
    # Qualquer 4xx/429 é prova de defesa funcionando.
    if 400 <= http_code < 500:
        return "auto", reasons

    # 2xx + persona deny = escalação clara.
    if 200 <= http_code < 300:
        if access == "deny":
            reasons.append(f"deny-persona+injection got {http_code} — possible bypass")
            return "review", reasons
        # Persona com acesso legítimo: baseline pode passar mas injection
        # não-control passando precisa de revisão (a app aceitou payload
        # malicioso e respondeu OK — checar se foi sanitizado).
        if inj_type in ("sqli", "xss", "path", "encoding", "mass_assign"):
            # Heurística: se body contém literal do payload, é REVIEW.
            inj_value = injection.get("value")
            if isinstance(inj_value, str) and inj_value and inj_value in body:
                reasons.append(f"payload echoed back in 2xx response (type={inj_type})")
                return "review", reasons
            # size: 2xx é OK desde que não tenha timeout/500.
            reasons.append(f"2xx with injection {inj_type} — no echo, treating as sanitized")
            return "auto", reasons
        return "auto", reasons

    # 3xx — redirect inesperado.
    reasons.append(f"redirect {http_code}")
    return "review", reasons


# ─── Report / summary ──────────────────────────────────────────────────────

def generate_report(results: list[dict[str, Any]], meta: dict[str, Any]) -> str:
    auto = [r for r in results if r["status"] == "auto"]
    review = [r for r in results if r["status"] == "review"]

    lines: list[str] = []
    lines.append("# Simulated Test Report\n\n")
    lines.append(f"- Generated: `{meta['generated_at']}`\n")
    lines.append(f"- API base: `{meta['api_base']}`\n")
    lines.append(f"- Routes: {meta['n_routes']} · Personas: {meta['n_personas']} · Injections: {meta['n_injections']}\n")
    lines.append(f"- **Total requests: {len(results)}**\n")
    lines.append(f"- AUTO: {len(auto)} · REVIEW: {len(review)}\n\n")

    # Tabela por category × persona com count de REVIEW.
    by_cat: dict[str, dict[str, int]] = {}
    for r in review:
        by_cat.setdefault(r["category"], {}).setdefault(r["persona"], 0)
        by_cat[r["category"]][r["persona"]] += 1
    if by_cat:
        lines.append("## REVIEW heat-map (category × persona)\n\n")
        personas = sorted({p for cat in by_cat.values() for p in cat})
        lines.append("| category | " + " | ".join(personas) + " |\n")
        lines.append("|" + "---|" * (len(personas) + 1) + "\n")
        for cat in sorted(by_cat):
            row = [cat] + [str(by_cat[cat].get(p, 0)) for p in personas]
            lines.append("| " + " | ".join(row) + " |\n")
        lines.append("\n")

    # Detalhes REVIEW (top 100).
    lines.append("## REVIEW — needs human eyes\n\n")
    if not review:
        lines.append("_(none)_\n\n")
    else:
        for r in review[:100]:
            reason = "; ".join(r.get("reasons") or []) or "(no reason)"
            lines.append(
                f"- `{r['method']} {r['route']}` "
                f"persona=`{r['persona']}` injection=`{r['injection']}` "
                f"→ HTTP **{r['http_code']}** ({r['latency_ms']:.0f}ms) — {reason}\n"
            )
        if len(review) > 100:
            lines.append(f"\n_…{len(review) - 100} mais — ver raw.jsonl._\n")

    # AUTO bucket counts.
    lines.append("\n## AUTO — passed by injection type\n\n")
    auto_by_type: dict[str, int] = {}
    for r in auto:
        auto_by_type[r["injection_type"]] = auto_by_type.get(r["injection_type"], 0) + 1
    for t in sorted(auto_by_type):
        lines.append(f"- `{t}`: {auto_by_type[t]}\n")

    return "".join(lines)


def generate_summary(results: list[dict[str, Any]], meta: dict[str, Any]) -> dict[str, Any]:
    auto = [r for r in results if r["status"] == "auto"]
    review = [r for r in results if r["status"] == "review"]

    def bucket(field: str) -> dict[str, int]:
        out: dict[str, int] = {}
        for r in results:
            out[r[field]] = out.get(r[field], 0) + 1
        return out

    def review_bucket(field: str) -> dict[str, int]:
        out: dict[str, int] = {}
        for r in review:
            out[r[field]] = out.get(r[field], 0) + 1
        return out

    latencies = [r["latency_ms"] for r in results if r["latency_ms"] > 0]
    latencies.sort()

    def pct(p: float) -> float:
        if not latencies:
            return 0.0
        idx = min(len(latencies) - 1, int(len(latencies) * p))
        return latencies[idx]

    return {
        "generated_at": meta["generated_at"],
        "api_base": meta["api_base"],
        "totals": {
            "requests": len(results),
            "auto": len(auto),
            "review": len(review),
            "routes": meta["n_routes"],
            "personas": meta["n_personas"],
            "injections": meta["n_injections"],
        },
        "by_injection_type": bucket("injection_type"),
        "by_persona": bucket("persona"),
        "by_category": bucket("category"),
        "review_by_injection_type": review_bucket("injection_type"),
        "review_by_persona": review_bucket("persona"),
        "review_by_category": review_bucket("category"),
        "latency_ms": {
            "p50": pct(0.50),
            "p95": pct(0.95),
            "p99": pct(0.99),
            "max": latencies[-1] if latencies else 0.0,
        },
    }


# ─── Main ──────────────────────────────────────────────────────────────────

def default_log_root() -> str:
    var_log = Path("/var/log/viralefy")
    if var_log.is_dir() and os.access(var_log, os.W_OK):
        return str(var_log)
    return "/tmp"


def main() -> int:
    parser = argparse.ArgumentParser(description="Viralefy simulated test engine")
    parser.add_argument(
        "--api-base",
        default=os.getenv("VIRALEFY_TEST_API_BASE", "http://127.0.0.1:8090"),
        help="Base URL do dispatcher",
    )
    parser.add_argument(
        "--log-dir",
        default=os.getenv("VIRALEFY_TEST_LOG_DIR", default_log_root()),
        help="Diretório-pai dos logs",
    )
    parser.add_argument(
        "--max-routes",
        type=int,
        default=int(os.getenv("VIRALEFY_SIM_MAX_ROUTES", "200")),
        help="Limita número de rotas testadas (debug)",
    )
    parser.add_argument(
        "--skip-mutations",
        action="store_true",
        default=os.getenv("VIRALEFY_SIM_SKIP_MUTATIONS") == "1",
        help="Pula rotas com mutates=true (POST/PUT/PATCH/DELETE marcados)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.getenv("VIRALEFY_SIM_TIMEOUT", "10")),
        help="Timeout HTTP por request (segundos)",
    )
    parser.add_argument(
        "--persona",
        action="append",
        default=None,
        help="Filtra por persona name (pode repetir)",
    )
    parser.add_argument(
        "--injection-type",
        action="append",
        default=None,
        help="Filtra por injection type (pode repetir)",
    )
    parser.add_argument("--quiet", action="store_true", help="Suprime progresso stdout")
    args = parser.parse_args()

    routes_doc = load_json("routes-inventory.json")
    personas_doc = load_json("personas.json")
    injections_doc = load_json("injections.json")

    routes = routes_doc.get("routes", [])[: args.max_routes]
    personas = personas_doc.get("personas", [])
    injections = injections_doc.get("injections", [])

    if args.persona:
        personas = [p for p in personas if p["name"] in args.persona]
    if args.injection_type:
        injections = [
            i for i in injections if i.get("type") in args.injection_type
        ]

    if args.skip_mutations:
        routes = [r for r in routes if not r.get("mutates", False)]

    if not routes or not personas or not injections:
        die(
            f"empty matrix: routes={len(routes)} personas={len(personas)} "
            f"injections={len(injections)}"
        )

    ts = datetime.now(timezone.utc)
    run_dir = Path(args.log_dir) / f"sim-{ts.strftime('%Y%m%d-%H%M%S')}"
    run_dir.mkdir(parents=True, exist_ok=True)
    raw_path = run_dir / "raw.jsonl"

    total = len(routes) * len(personas) * len(injections)
    if not args.quiet:
        print(
            f"[sim] api_base={args.api_base} routes={len(routes)} "
            f"personas={len(personas)} injections={len(injections)} "
            f"total={total} log_dir={run_dir}",
            file=sys.stderr,
        )

    results: list[dict[str, Any]] = []
    n = 0
    with raw_path.open("w", encoding="utf-8") as raw_f:
        for route in routes:
            for persona in personas:
                for injection in injections:
                    n += 1
                    try:
                        r = run_one(
                            args.api_base,
                            route,
                            persona,
                            injection,
                            args.timeout,
                        )
                    except Exception as e:  # noqa: BLE001 — fail-soft
                        r = {
                            "route": route["path"],
                            "method": route["method"],
                            "category": route.get("category", "?"),
                            "persona": persona["name"],
                            "injection": injection["name"],
                            "injection_type": injection.get("type", "control"),
                            "http_code": 0,
                            "latency_ms": 0,
                            "status": "review",
                            "reasons": [f"engine exception: {type(e).__name__}: {e}"],
                            "err": str(e),
                            "body_truncated": "",
                            "resp_content_type": "",
                            "url": "",
                        }
                    results.append(r)
                    raw_f.write(json.dumps(r, ensure_ascii=False) + "\n")
                    if not args.quiet and n % 50 == 0:
                        print(
                            f"[sim] {n}/{total} … last={r['method']} {r['route']} "
                            f"persona={r['persona']} status={r['status']}",
                            file=sys.stderr,
                        )

    meta = {
        "generated_at": ts.isoformat(),
        "api_base": args.api_base,
        "n_routes": len(routes),
        "n_personas": len(personas),
        "n_injections": len(injections),
    }

    report = generate_report(results, meta)
    (run_dir / "report.md").write_text(report, encoding="utf-8")

    summary = generate_summary(results, meta)
    (run_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    # ─ stdout summary p/ humano + para o wrapper bash ler.
    auto_n = summary["totals"]["auto"]
    review_n = summary["totals"]["review"]
    print(
        f"simulated: total={summary['totals']['requests']} "
        f"auto={auto_n} review={review_n} "
        f"log_dir={run_dir}"
    )

    return 1 if review_n > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
