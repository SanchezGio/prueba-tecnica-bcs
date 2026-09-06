#!/usr/bin/env python3
"""Imprime en una tabla legible los hallazgos de un reporte JSON de Bandit.
Ver el comentario de cabecera en summarize_trivy.py — mismo motivo.

Uso: python3 summarize_bandit.py <ruta-al-reporte.json>
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("Uso: summarize_bandit.py <ruta-al-reporte.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as f:
        report = json.load(f)

    results = report.get("results") or []
    if not results:
        print("(ningún hallazgo)")
        return 0

    for r in results:
        print(
            f"{r.get('issue_severity', '?'):8s} "
            f"{r.get('test_id', '?'):8s} "
            f"{r.get('filename', '?')}:{r.get('line_number', '?')} "
            f"{r.get('issue_text', '?')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
