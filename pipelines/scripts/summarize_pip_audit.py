#!/usr/bin/env python3
"""Imprime en una tabla legible los hallazgos de un reporte JSON de pip-audit.
Ver el comentario de cabecera en summarize_trivy.py — mismo motivo.

Uso: python3 summarize_pip_audit.py <ruta-al-reporte.json>
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("Uso: summarize_pip_audit.py <ruta-al-reporte.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as f:
        report = json.load(f)

    # pip-audit >= 2.6 anida los hallazgos bajo "dependencies"; versiones
    # previas devuelven una lista plana en la raíz — se contemplan ambas.
    deps = report.get("dependencies") if isinstance(report, dict) else report
    rows = []
    for dep in deps or []:
        for vuln in dep.get("vulns") or []:
            rows.append((dep.get("name", "?"), dep.get("version", "?"), vuln))

    if not rows:
        print("(ninguna vulnerabilidad conocida en las dependencias)")
        return 0

    for name, version, vuln in rows:
        fixed = ", ".join(vuln.get("fix_versions") or []) or "?"
        print(
            f"{vuln.get('id', '?'):20s} "
            f"{name:25s} instalado={version:15s} parche={fixed}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
