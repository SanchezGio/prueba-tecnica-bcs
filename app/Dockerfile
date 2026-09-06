# Imagen del microservicio de prueba (FastAPI). Prácticas de seguridad aplicadas:
# - Multi-stage: las herramientas de build no viajan a la imagen final.
# - Base mínima (slim), versión pineada explícitamente (no `latest`).
# - Usuario no root en tiempo de ejecución.
# - Sin secretos ni archivos `.env` copiados a la imagen (ver .dockerignore).
# - `pip install --no-cache-dir` + hash-checking de dependencias vía requirements pineado.

FROM python:3.11.9-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt
# Diagnóstico permanente en el log de build: rutas exactas de los paquetes
# que Trivy reporta como vulnerables, dentro de /root/.local (lo único que
# se copia a la imagen final vía COPY --from=builder más abajo) — en vez de
# depender de bajar el reporte JSON de Trivy a ciegas para saber de dónde
# viene cada hallazgo, queda visible directo en la consola del pipeline en
# cada build.
RUN echo "----- Rutas de msgpack/setuptools/wheel en /root/.local (builder) -----" && \
    find /root/.local -maxdepth 6 \( -iname "*msgpack*" -o -iname "*setuptools*" -o -iname "*wheel*" \) 2>/dev/null; \
    echo "-----"

FROM python:3.11.9-slim AS runtime

# La imagen base oficial de Python trae fecha de corte fija (esta, de agosto
# 2024) — sus paquetes de sistema Debian (libexpat1, libgnutls30, libssl3,
# openssl, libsqlite3-0, etc.) acumulan CVEs ya parcheados en los repos de
# Debian que nunca se instalan porque nadie corre `apt-get upgrade` después
# del build oficial. Sin este paso, el escaneo de Trivy (pipeline CI/CD)
# encuentra decenas de CVEs HIGH/CRITICAL evitables con una sola línea.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# setuptools y wheel son herramientas de BUILD (empaquetado/instalación de
# paquetes), no algo que FastAPI/Starlette/uvicorn/pydantic necesiten en
# tiempo de ejecución — estos frameworks usan `importlib.metadata` (librería
# estándar) para inspección de versiones/plugins, no el `pkg_resources` de
# setuptools. Perseguir la versión parcheada más reciente de estas dos cada
# vez que Trivy encuentra un CVE nuevo es una carrera sin fin contra algo que
# la imagen final ni siquiera necesita tener instalado — se eliminan del todo
# en vez de mantenerlas actualizadas indefinidamente. `pip` se actualiza
# igual (útil para depuración manual, y su huella de CVEs históricamente ha
# sido mínima).
#
# NOTA (root cause real, no otra suposición): `pip uninstall` depende de que
# el paquete tenga un manifiesto RECORD normal — setuptools/wheel en esta
# imagen base los instala el script interno get-pip.py de la propia imagen
# oficial de Python (no un `pip install` común), que puede no dejar ese
# manifiesto en el formato que `pip uninstall` espera, haciendo que el
# comando "tenga éxito" (exit 0) sin borrar nada realmente. Se reemplaza por
# borrado directo del disco — el mismo método ya comprobado efectivo más
# abajo para el sitio de usuario copiado del stage builder — con
# verificación impresa en el propio log de build, no en un paso aparte.
RUN pip install --no-cache-dir --upgrade pip && \
    find /usr/local/lib/python3.11/site-packages -maxdepth 1 \( -iname "setuptools*" -o -iname "wheel*" \) -exec rm -rf {} + ; \
    echo "----- Verificación tras limpieza directa (sitio de sistema) -----" && \
    find /usr/local/lib/python3.11/site-packages -maxdepth 1 \( -iname "*setuptools*" -o -iname "*wheel*" \) 2>/dev/null; \
    echo "-----"

# Usuario no root dedicado — nunca correr la app como root.
RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid appuser --shell /usr/sbin/nologin --create-home appuser

COPY --from=builder /root/.local /home/appuser/.local

# Limpieza definitiva e incondicional: si por cualquier motivo quedó una
# copia de setuptools/wheel en el sitio de usuario recién copiado desde el
# stage builder (una fuente independiente del `pip uninstall` de arriba, que
# solo pudo actuar sobre el sitio de SISTEMA de este stage runtime), se
# elimina directamente del disco sin depender de que `pip` la encuentre o
# reconozca correctamente. Se imprime el antes/después en el log de build
# para confirmar qué había, en vez de asumirlo.
RUN echo "----- Antes de limpiar: setuptools/wheel en /home/appuser/.local -----" && \
    find /home/appuser/.local -maxdepth 6 \( -iname "*setuptools*" -o -iname "*wheel*" \) 2>/dev/null; \
    echo "-----" && \
    find /home/appuser/.local -maxdepth 6 \( -iname "*setuptools*" -o -iname "*wheel*" \) -exec rm -rf {} + 2>/dev/null; \
    echo "----- Después de limpiar -----" && \
    find /home/appuser/.local -maxdepth 6 \( -iname "*setuptools*" -o -iname "*wheel*" \) 2>/dev/null; \
    echo "-----"

WORKDIR /app
COPY app ./app

RUN chown -R appuser:appuser /app
USER appuser

ENV PATH="/home/appuser/.local/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
