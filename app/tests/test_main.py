from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_healthz_returns_ok():
    response = client.get("/healthz")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["uptime_seconds"] >= 0


def test_greet_valid_name():
    response = client.post("/greet", json={"name": "Giovanny"})
    assert response.status_code == 200
    assert response.json() == {"message": "Hola, Giovanny!"}


def test_greet_rejects_invalid_characters():
    # Nombres con caracteres fuera del patrón permitido deben ser rechazados
    # por la validación de Pydantic (422), no procesados silenciosamente.
    response = client.post("/greet", json={"name": "<script>alert(1)</script>"})
    assert response.status_code == 422


def test_greet_rejects_empty_name():
    response = client.post("/greet", json={"name": ""})
    assert response.status_code == 422
