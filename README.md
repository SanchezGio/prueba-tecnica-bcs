# Modernización de la Plataforma de CI/CD — Agentes Efímeros Seguros

Entregable para la prueba técnica de **Líder de Ciberseguridad**.
Propuesta y construcción de una plataforma de CI/CD sobre **Azure DevOps** con agentes self-hosted
**efímeros**, en reemplazo del modelo actual de VMs dedicadas de larga vida + Azure Bastion
continuo.

📄 **El documento de arquitectura y decisiones completo (con diagrama) está en
[docs/architecture.md](docs/architecture.md).**

## Resumen de la propuesta

El mecanismo de agente efímero es un **Elastic Pool de Azure DevOps sobre un VM Scale Set (VMSS)**:
la VM arranca desde la imagen estándar de **Ubuntu Server 22.04 LTS de Azure Marketplace** (sin
modificar), sin IP pública, instala al inicio de cada job exactamente las herramientas que ese job
necesita, ejecuta un único job, y **se destruye por completo** al terminar (opción "Recreate agent
after each use" del Elastic Pool) — cero estado residual entre ejecuciones. Ver el diagrama completo
y la justificación de esta elección en
[docs/architecture.md §1–3](docs/architecture.md#1-resumen-ejecutivo).

Como capacidad adicional, el repositorio incluye un pipeline independiente
(`pipelines/agent-image-pipeline.yml`) que construye, endurece (CIS básico) y escanea con Trivy una
**imagen dorada** de agente vía Packer, publicándola versionada en un Azure Compute Gallery — un
camino natural de evolución si el volumen de builds justificara el costo de mantener una imagen
propia (ver [docs/architecture.md §3.3](docs/architecture.md#33-imagen-base-del-agente-y-capacidad-de-imagen-dorada)).

## Modo de entrega de este ejercicio

Este repositorio contiene **todo el código y la documentación** pedidos en el entregable (IaC,
imagen del agente, pipelines, componente de prueba, documento de arquitectura), **desplegado y
verificado en vivo** contra una suscripción Azure real y una organización de Azure DevOps real.

## 1. Mapa del repositorio

```
devops-tests/
├── docs/
│   ├── architecture.md         # Documento de arquitectura, decisiones y diagrama (entregable 4.1)
│   
├── infra/                       # IaC (Terraform: azurerm + azapi)
│   ├── providers.tf             # Providers + backend remoto de estado
│   ├── variables.tf
│   ├── main.tf
│   ├── network.tf               # VNet, subredes, NSGs, NAT Gateway, Private DNS
│   ├── agent-vmss.tf             # VM Scale Set del Elastic Pool (agentes efímeros)
│   ├── identity.tf               # Managed Identities + asignaciones RBAC
│   ├── acr.tf                    # Azure Container Registry (Premium, privado)
│   ├── keyvault.tf               # Key Vault (RBAC, privado)
│   ├── storage.tf                # Storage para reportes de escaneo
│   ├── monitoring.tf             # Log Analytics + Defender for Cloud
│   ├── gallery.tf                # Azure Compute Gallery (imagen dorada, demo)
│   ├── container-apps.tf         # Container Apps Environment + app (interno)
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── agent-image/                  # Definición de la imagen dorada del agente (demo, vía Packer)
│   ├── packer/agent.pkr.hcl
│   └── scripts/
│       ├── provision-agent.sh
│       └── cis-hardening.sh
├── pipelines/                    # Pipelines de Azure DevOps (YAML)
│   ├── agent-image-pipeline.yml  # Build/hardening/scan/publish de la imagen dorada (Microsoft-hosted)
│   ├── app-cicd-pipeline.yml     # CI/CD del componente de prueba (sobre el Elastic Pool efímero)
│   └── scripts/                  # Resumidores de reportes JSON (Trivy/Bandit/pip-audit) para el log
└── app/                          # Componente de prueba funcional (FastAPI)
    ├── app/main.py
    ├── tests/test_main.py
    ├── requirements.txt / requirements-dev.txt
    ├── Dockerfile
    └── pyproject.toml
```

## 2. Prerrequisitos para reproducir

- Suscripción Azure con permisos de `Owner`/`Contributor` + `User Access Administrator` en el scope
  del resource group (necesarios para las asignaciones RBAC de `infra/identity.tf`).
- Organización de Azure DevOps con permisos para crear *Service Connections* y *Agent Pools*.
- Un navegador (todo se ejecuta desde **Azure Cloud Shell** + Azure DevOps + Azure Portal — no hace
  falta instalar `terraform`, `az cli`, `packer` ni `docker` en la máquina local).

## 3. Orden de ejecución para desplegar


1. Crear proyecto/repo en Azure DevOps y subir este código (`git push`).
2. Crear el backend remoto de estado de Terraform (Storage Account dedicado) y `terraform apply`
   desde Azure Cloud Shell — crea red, ACR, Key Vault, identidades, Container Apps, Log Analytics,
   Defender for Cloud, el Compute Gallery, y el VM Scale Set de los agentes.
3. Crear la Service Connection OIDC (`svc-conn-azure-rm-oidc`) en Azure DevOps.
4. Enlazar el VM Scale Set ya creado con un **Elastic Pool** (`vmss-cicd-agents`) desde
   *Organization Settings → Agent pools* — único paso manual de UI, ver la guía para el detalle
   exacto de cada campo.
5. (Opcional, demo) Ejecutar `pipelines/agent-image-pipeline.yml` (Microsoft-hosted) para construir,
   endurecer y publicar la imagen dorada en el Azure Compute Gallery.
6. Ejecutar `pipelines/app-cicd-pipeline.yml` sobre el Elastic Pool: build → test → escaneo de
   seguridad → deploy de `app/` en Azure Container Apps.

## 4. Decisiones de diseño no evidentes

- **Por qué Packer y no un Dockerfile para "la imagen dorada del agente"**: el equivalente de un
  Dockerfile para una imagen de VM (no de contenedor) es una plantilla de imagen — `agent-image/packer/agent.pkr.hcl`
  cumple ese rol; `app/Dockerfile` es el Dockerfile "clásico" del componente de prueba.
- **La imagen del agente en vivo es la de Marketplace, sin modificar** (`infra/agent-vmss.tf`): se
  prioriza cero incertidumbre de integración VM-guest con el *fabric* de Azure sobre el ahorro de
  tiempo de build de tener herramientas precargadas. El costo explícito de esta decisión es que cada
  job del pipeline instala sus propias herramientas al inicio (ver
  [docs/architecture.md §3.4](docs/architecture.md#34-herramientas-y-pasos-del-pipeline-de-la-aplicación))
  — documentado también como limitación abajo.
- **`standbyAgentCount = 0`, `maxAgents = 1`**: se prioriza el ahorro de costo (cero VMs en reposo)
  sobre la latencia de arranque en frío (~1-2 min); `maxAgents` está acotado por la cuota real de
  vCPUs de la suscripción usada para esta prueba, no por diseño.
- **Sin Bastion en ninguna parte del diseño**: se reemplaza por (a) el hecho de que los agentes ya
  no requieren mantenimiento interactivo rutinario, y (b) Azure Run Command/Serial Console sobre el
  plano de control de ARM para el caso excepcional de depuración. Ver docs/architecture.md §4.
- **Terraform gestiona plano de control, no plano de datos, detrás de un Private Endpoint**: crear
  una *Storage Account* es una operación ARM (plano de control, siempre alcanzable); crear un
  *contenedor dentro de ella* es una llamada a la Blob REST API (plano de datos), que con
  `public_network_access_enabled = false` solo es alcanzable desde dentro de la VNet — y quien corre
  `terraform apply` (Azure Cloud Shell) no está dentro de ella. La solución es que el propio pipeline
  (que sí corre dentro de la VNet, en el agente efímero) cree esos recursos de datos la primera vez
  que los necesita, con su identidad administrada.
- **El microservicio de prueba es completamente interno** (`external_enabled = false`, sin IP
  pública en el Container Apps Environment). El *gate* de despliegue es el propio `az containerapp
  update`, que falla si la revisión nueva no llega a estado sano — cumpliendo el requisito de
  "pipeline completo build→test→deploy" **sin** violar la restricción no negociable de "no endpoints
  públicos en componentes críticos". Un *smoke test* HTTP adicional contra el FQDN interno (`curl` a
  `/healthz` desde el propio agente, misma VNet) se probó en vivo pero se retiró: expuso una
  limitación real de Azure Container Apps con VNet propia (la Private DNS Zone del dominio interno no
  se crea sola — ver [docs/architecture.md §4](docs/architecture.md#4-modelo-de-red-y-aislamiento-sin-bastion-dedicado))
  cuyo fix de infraestructura queda documentado y listo para aplicar, pero fuera del alcance de esta
  entrega por tiempo.
- **ACR Premium** (no Basic/Standard) es una decisión deliberada de costo-por-seguridad: es el único
  tier que soporta Private Endpoint. Se documenta explícitamente como el componente fijo más caro de
  la propuesta (docs/architecture.md §7.3) para que sea una decisión informada, no un descuido.
- **El NSG de los agentes permite salida HTTP/80 además de HTTPS/443**: el mirror regional de `apt`
  usado por la imagen de Ubuntu (`azure.archive.ubuntu.com`) no ofrece *listener* HTTPS — la
  integridad de los paquetes la garantizan las firmas GPG de `apt`, no el transporte. Ver
  docs/architecture.md §4 para el detalle completo del modelo de egress.

## 5. Limitaciones conocidas y mejoras futuras

- **El Elastic Pool se enlaza manualmente al VMSS** desde *Organization Settings* de Azure DevOps —
  no es 100% IaC de punta a punta, porque ese enlace es administración de la organización de Azure
  DevOps, no un recurso de Azure. Automatizable a futuro vía la API REST de Azure DevOps.
- **Cada job del pipeline instala sus propias herramientas al inicio** (git, Docker, Trivy, Azure
  CLI, gitleaks según el job) en vez de partir de una imagen precargada — *trade-off* deliberado de
  velocidad de arranque de build vs. confiabilidad/simplicidad de la imagen base (ver
  docs/architecture.md §3.3). La imagen dorada del §3.3 demuestra que la capacidad de precargar
  herramientas existe, para cuando el volumen de builds justifique ese costo de mantenimiento.
- **Egress a Internet desde `snet-agents` está limitado a HTTPS/443 y HTTP/80** (NSG, ver
  `infra/network.tf`) — suficiente para las herramientas y registries que usa este pipeline
  (PyPI, Docker Hub, GitHub Releases, el mirror de apt), pero sigue siendo "todo HTTP(S)" en vez de
  una lista explícita de destinos. En un despliegue de mayor madurez se resolvería con un feed
  privado de Azure Artifacts (con *upstream*) o un Azure Firewall con filtrado por FQDN.
- **El escaneo de Trivy sobre la imagen del microservicio quedó informativo, no bloqueante** — se
  investigó exhaustivamente una discrepancia reproducible entre el contenido real de la imagen
  (verificado directamente, sin Trivy) y lo reportado por la herramienta; el detalle completo de la
  investigación y la decisión está en
  [docs/architecture.md §6.1](docs/architecture.md#61-limitación-conocida-trivy-vs-contenido-real-de-la-imagen).
  El resto de los *gates* de seguridad (Bandit, pip-audit, gitleaks) siguen siendo activos y
  bloqueantes.
- **Sin Azure Firewall**: el filtrado de egress actual es por puerto/*service tags* de NSG, más
  simple pero menos granular que un firewall con reglas FQDN. Sería la siguiente mejora natural si
  el volumen de pipelines crece.
- **Sin política de Azure (Azure Policy)** aplicada a este resource group (p. ej. "denegar recursos
  con IP pública") — reforzaría de forma preventiva, no solo por diseño, la restricción de "sin
  endpoints públicos". Recomendado como siguiente paso.
- **Cobertura de tests del componente de prueba es mínima** (4 casos) — suficiente para demostrar el
  pipeline, no representativo de una suite de calidad real.
- **Hardening de la imagen dorada es un subconjunto pragmático de CIS**, no una certificación
  completa.
- **No se automatizó la rotación/expiración de las versiones antiguas de la imagen dorada** en el
  Compute Gallery (debería purgarse automáticamente tras N versiones o M días).

## 6. Reflexión: equilibrio seguridad / costo / operabilidad

El modelo anterior optimizaba operabilidad percibida (una VM "siempre lista", acceso administrativo
siempre disponible vía Bastion) a costa de costo fijo alto y una superficie de vulnerabilidad que
solo crecía con el tiempo. La propuesta invierte esa relación: **se acepta una pequeña penalización
de latencia** (cold start de ~1-2 min con `standbyAgentCount=0`, y unos segundos adicionales por job
para instalar herramientas sobre una imagen sin modificar) **a cambio de**:

- Una reducción de costo estimada del 70-80% (docs/architecture.md §7), que además pasa de ser
  *fijo* a *variable con el uso real*.
- Una superficie de vulnerabilidad que nunca acumula más de un job de vida — el peor caso posible ya
  no es "una VM contaminada que afecta meses de builds", sino "una instancia comprometida acotada a
  los minutos que vive un agente, sin estado que sobreviva para el siguiente job".
- Una carga operativa que se traslada de "mantener VMs" a "mantener un pipeline y, opcionalmente,
  una plantilla de imagen" — trabajo que se hace una vez y se audita, no trabajo recurrente de
  parcheo manual.

El costo de esa ganancia es la disciplina de mantener acotado el egress de red en vez de abrirlo por
comodidad, y aceptar que instalar herramientas en cada job añade unos segundos por ejecución. Es el
trade-off correcto para el problema descrito: la organización pidió explícitamente eliminar costo
ocioso, reducir vulnerabilidades acumuladas y liberar carga operativa — no pidió el mínimo esfuerzo
de migración posible.
