"""Microservicio de prueba funcional.

Componente mínimo usado para demostrar el pipeline completo
build -> test -> scan -> deploy sobre los agentes efímeros (ver
docs/architecture.md, restricción no negociable "al menos un componente de
prueba funcional").

Prácticas de seguridad aplicadas en el código (capa "desarrollo"):
- Sin secretos ni credenciales embebidas.
- Entradas validadas por Pydantic (rechaza payloads malformados por defecto).
- Sin `eval`/`exec`/deserialización insegura.
- Endpoint de salud sin información sensible (no expone versión de dependencias
  ni detalles de infraestructura).
"""
from __future__ import annotations

import time

from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(
    title="demo-ephemeral-agents",
    description="Componente de prueba funcional para la plataforma de CI/CD con agentes efímeros.",
    version="1.0.0",
)

_START_TIME = time.time()


class HealthResponse(BaseModel):
    status: str
    uptime_seconds: float


class GreetRequest(BaseModel):
    name: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9 _-]+$")


class GreetResponse(BaseModel):
    message: str


@app.get("/healthz", response_model=HealthResponse)
def healthz() -> HealthResponse:
    """Usado por el liveness/readiness probe de Azure Container Apps
    (infra/container-apps.tf) y por el smoke test del pipeline de despliegue."""
    return HealthResponse(status="ok", uptime_seconds=round(time.time() - _START_TIME, 2))


@app.post("/greet", response_model=GreetResponse)
def greet(payload: GreetRequest) -> GreetResponse:
    """Endpoint de ejemplo — el patrón de validación (Pydantic con `pattern`
    acotado) es intencional: evita que el componente de prueba se use como
    excusa para introducir inyección o payloads arbitrarios sin validar."""
    return GreetResponse(message=f"Hola, {payload.name}!")
