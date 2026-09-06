#!/usr/bin/env python3
"""Imprime en una tabla legible las vulnerabilidades de un reporte JSON de
Trivy. El pipeline solo escribe JSON (auditable, publicado como artefacto),
pero JSON no es legible directamente en la consola de Azure Pipelines —
depender de bajar el artefacto a ciegas cada vez que el gate falla es
exactamente el tipo de vuelta que este script evita de ahora en adelante.

Uso: python3 summarize_trivy.py <ruta-al-reporte.json>
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("Uso: summarize_trivy.py <ruta-al-reporte.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as f:
        report = json.load(f)

    rows = []
    for result in report.get("Results") or []:
        for vuln in result.get("Vulnerabilities") or []:
            rows.append(vuln)

    if not rows:
        print("(ninguna vulnerabilidad HIGH/CRITICAL con parche disponible)")
        return 0

    for v in rows:
        print(
            f"{v.get('Severity', '?'):8s} "
            f"{v.get('PkgName', '?'):25s} "
            f"{v.get('VulnerabilityID', '?'):18s} "
            f"instalado={v.get('InstalledVersion', '?')} "
            f"parche={v.get('FixedVersion', '?')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
