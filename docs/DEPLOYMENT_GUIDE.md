# Guía de Despliegue Paso a Paso

Guía operativa para llevar este repositorio a una Azure DevOps org + suscripción Azure reales,
sin instalar nada en la máquina local (usa Azure Cloud Shell para todo lo que requiere `az`/`terraform`,
y Azure DevOps/Azure Portal para el resto). Complementa [architecture.md](architecture.md) (el porqué)
con el cómo, en orden de ejecución.

> Convención en esta guía: 🧑 = lo haces tú (clic en un portal/UI); 💻 = comando para pegar en
> **Azure Cloud Shell**; 🤝 = paso que se resuelve junto con el asistente de IA que te acompaña
> (p. ej. `git push` desde tu máquina local, que ya tiene `git` instalado).

> El **VM Scale Set** de los agentes se crea con Terraform en la misma pasada que el resto de la
> infraestructura (Fase 2). El **Elastic Pool** de Azure DevOps que lo enlaza con la organización se
> crea aparte, a mano, desde *Organization Settings* (Fase 6) — es administración de la
> organización de Azure DevOps, no un recurso de Azure, así que no es Terraform. Orden de fases:
> 2 (infra + VMSS) → 4-5 (service connection + opcional imagen dorada) → 6 (enlazar el Elastic Pool)
> → 7 (pipeline principal).

---

## Fase 1 — Crear el proyecto y el repo en Azure DevOps

🧑 1.1. Ve a `https://dev.azure.com/` → **New project**.
   - Nombre sugerido: `cicd-ephemeral-agents`.
   - Visibility: **Private**.
   - Version control: **Git**.
   - Work item process: da igual (Basic).
   - **Create**.

🧑 1.2. El proyecto crea automáticamente un repo Git vacío con el mismo nombre. Ve a **Repos** →
   botón **Clone** → copia la URL HTTPS (formato
   `https://dev.azure.com/TU-ORG/TU-PROYECTO/_git/TU-PROYECTO`).

🤝 1.3. Comparte esa URL (y el nombre de tu organización + proyecto) para configurar el remoto y
   hacer `git push` de este repo local hacia Azure Repos. Al hacer el push, Git puede abrir una
   ventana de tu navegador o del sistema para que inicies sesión con tu cuenta Microsoft/Azure AD
   (Git Credential Manager) — la completas tú; nadie más ve tu contraseña.

---

## Fase 2 — Desplegar la infraestructura base con Terraform (Azure Cloud Shell)

Este `apply` crea toda la infraestructura, incluido el VM Scale Set de los agentes — el enlace de
ese VMSS con un Elastic Pool de la organización de Azure DevOps se hace aparte, en la Fase 6.

> ⚠️ **Lección aprendida durante este despliegue**: Azure Cloud Shell no garantiza que tu sesión
> (y con ella, `terraform.tfstate` local) sobreviva entre reconexiones — una sesión inactiva puede
> reciclarse y perder todo el disco no persistido. Perder el state significa que Terraform "olvida"
> qué ya existe en Azure, aunque los recursos sigan ahí facturando. Por eso el paso 2.1 configura un
> **backend remoto obligatorio** antes de crear nada — el estado vive en Azure Storage, no en el
> disco de la sesión.

🧑 2.1. Entra a `https://portal.azure.com` → icono de terminal **Cloud Shell** (`>_`) en la barra
   superior → elige **Bash**.

💻 2.1.1. Crea el storage account para el estado remoto de Terraform (una sola vez; si ya lo
   creaste, sáltate este paso):
   ```bash
   az group create --name rg-tfstate --location eastus
   STORAGE_NAME="sttfstate$RANDOM$RANDOM"
   echo "Nombre generado: $STORAGE_NAME"   # anótalo
   az storage account create --name $STORAGE_NAME --resource-group rg-tfstate \
     --location eastus --sku Standard_LRS --encryption-services blob
   az storage container create --name tfstate --account-name $STORAGE_NAME
   ```
   Con ese nombre, `infra/providers.tf` ya trae configurado el bloque `backend "azurerm"` apuntando
   a `resource_group_name = "rg-tfstate"` / `container_name = "tfstate"` — si repites este proceso
   con un storage account distinto, actualiza `storage_account_name` en ese archivo antes de
   `terraform init`.

💻 2.2. Confirma la suscripción activa (importante desde que el proveedor `azurerm` >= 4.0 la
   requiere explícita):
   ```bash
   az account show --query "{subscriptionId:id, name:name}" -o table
   # Si tienes más de una suscripción y no es la correcta:
   az account set --subscription "ID-O-NOMBRE-DE-TU-SUSCRIPCION"
   ```

💻 2.3. Clona el repo (te pedirá autenticarte — usa un **Personal Access Token**: icono de usuario
   arriba a la derecha en Azure DevOps → *Personal access tokens* → *New Token* → scope
   **Code: Read** → *Create* → copia el token, se usa como contraseña):
   ```bash
   git clone https://TU-ORG@dev.azure.com/TU-ORG/TU-PROYECTO/_git/TU-PROYECTO repo
   cd repo/infra
   git checkout feature/ephemeral-agents-platform   # o main, si ya se fusionó
   ```

💻 2.4. Completa las variables:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   code terraform.tfvars   # abre el editor integrado de Cloud Shell
   ```
   Edita como mínimo `azure_devops_organization_url` y `azure_devops_project_name` con tus valores
   reales de la Fase 1. Guarda (Ctrl+S) y cierra el editor (Ctrl+Q o el botón "..." → Close Editor).

💻 2.5. Despliega:
   ```bash
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   ```
   `terraform plan` te muestra exactamente qué se va a crear antes de aplicar — revísalo. El
   `apply` tarda entre 5 y 15 minutos (Key Vault, ACR Premium y Private Endpoints son los que más
   tardan).

💻 2.6. Guarda los outputs, los necesitarás en las fases siguientes:
   ```bash
   terraform output
   ```

---

## Fase 3 — Verificar en Azure Portal

🧑 3.1. Busca el resource group `rg-cicd-dev` (o el nombre que hayas puesto en `environment`) y
   confirma que existen: VNet con 4 subredes, NSGs, NAT Gateway, ACR, Key Vault, Storage Account,
   Log Analytics, Compute Gallery, Container Apps Environment + la app, el VM Scale Set de los
   agentes, y las dos identidades administradas. (El **Elastic Pool** de Azure DevOps todavía no
   existe — eso es correcto, se enlaza en la Fase 6).

🧑 3.2. En **Container Registry → Networking**, confirma "Public network access: Disabled" y que
   existe una conexión de Private Endpoint. Repite la verificación en **Key Vault → Networking**.

---

## Fase 4 — Crear la Service Connection OIDC en Azure DevOps

Esta conexión la usan los dos pipelines (`agent-image-pipeline.yml` y `app-cicd-pipeline.yml`) para
autenticarse contra Azure **sin ningún secreto estático**.

🧑 4.1. En el proyecto de Azure DevOps → **Project settings** (ícono de engranaje, abajo a la
   izquierda) → **Service connections** (bajo "Pipelines") → **New service connection**.

🧑 4.2. Elige **Azure Resource Manager** → *Next* → **Workload identity federation (automatic)** →
   *Next*.

🧑 4.3. Scope level: **Subscription**. Selecciona tu suscripción y, como *Resource Group*, el
   `rg-cicd-dev` creado en la Fase 2 (limita el alcance de la conexión a este resource group, en
   vez de a toda la suscripción).

🧑 4.4. Service connection name: exactamente `svc-conn-azure-rm-oidc` (los pipelines YAML de este
   repo referencian este nombre literal). Marca **Grant access permission to all pipelines**.
   **Save**.

   Azure DevOps crea automáticamente el *app registration* y la *federated credential* en Entra ID
   — no se genera ni se copia ningún secreto en ningún momento.

🧑 4.5. **Otorgar permisos a esa identidad** sobre los recursos que va a tocar el pipeline: ve al
   resource group `rg-cicd-dev` en Azure Portal → **Access control (IAM)** → **Add role
   assignment** → rol **Contributor** → asigna al *service principal* que Azure DevOps acaba de
   crear (aparece con un nombre parecido a `cicd-ephemeral-agents-<fecha>`, búscalo por ese patrón
   en el selector de miembros). Esto es necesario porque la Service Connection es una identidad
   nueva, distinta de tu propia cuenta que usaste en Cloud Shell para el `terraform apply`.

---

## Fase 5 — Publicar la primera versión de la imagen del agente

Corre en un agente **Microsoft-hosted** (todavía no existe el pool propio — se crea en la Fase 6
usando la imagen que este paso publica).

🧑 5.1. En Azure DevOps → **Pipelines** → **Library** → **+ Variable group** → nombre
   `cicd-ephemeral-agents-image`. Agrega estas variables (no son secretas, no marques el candado),
   tomando los valores de `terraform output` (Fase 2.6):

   | Variable | Valor (de `terraform output`) |
   |---|---|
   | `AZURE_SUBSCRIPTION_ID` | `azure_subscription_id` |
   | `RESOURCE_GROUP_NAME` | `resource_group_name` |
   | `GALLERY_NAME` | `compute_gallery_name` |
   | `BUILD_SUBNET_ID` | `image_build_subnet_id` |

   **Save**.

🧑 5.2. **Pipelines** → **New pipeline** → **Azure Repos Git** → selecciona el repo →
   **Existing Azure Pipelines YAML file** → rama `main` (o tu rama de trabajo), path
   `/pipelines/agent-image-pipeline.yml` → **Continue** → **Save** (flecha junto a *Run* → *Save*,
   no lo ejecutes todavía desde aquí). Ponle un nombre reconocible, p. ej. `agent-image-build`.

🧑 5.3. Ejecuta el pipeline manualmente una vez: ábrelo → **Run pipeline** → **Run**. Tarda
   ~10-20 minutos (instala Packer, construye la VM temporal en `snet-image-build`, aplica
   hardening, escanea con Trivy, publica la versión en el Compute Gallery, destruye la VM
   temporal). Revisa el artefacto `trivy-agent-image-report` publicado al final del run.

🧑 5.4. Verifica en Azure Portal → tu Compute Gallery → `img-agent-ubuntu2204` → que aparece al
   menos una versión (formato `AAAA.MM.DD`).

---

## Fase 6 — Crear el Elastic Pool (VM Scale Set)

💻 6.1. El VM Scale Set (`vmss-cicd-agents-dev`, 0 instancias — Azure DevOps las escala
   dinámicamente, arrancando desde la imagen estándar de Ubuntu Server 22.04 LTS de Azure
   Marketplace) ya se creó en la Fase 2, como parte del mismo `terraform apply`. No hace falta
   ningún paso adicional de Terraform aquí.

🧑 6.2. En Azure DevOps → **Organization settings** → **Agent pools** → **Add pool**:
   - Pool type: **Azure virtual machine scale set**.
   - Azure subscription: selecciona la Service Connection `svc-conn-azure-rm-oidc` (Fase 4).
   - Scale set: `vmss-cicd-agents-dev` (resource group `rg-cicd-dev`).
   - **Recreate agent after each use**: actívalo — es la garantía de "efímero" (cero estado
     residual entre ejecuciones), ver docs/architecture.md §3.2.
   - Agent interactive UI: **No**.
   - Desired idle: `0` (escala a cero, costo mínimo — ver docs/architecture.md §7.3).
   - Max saved agents / Max number of agents: `1` (acorde al tope de cuota de esta suscripción, ver
     `infra/variables.tf:agent_vm_sku`).
   - Pool name: `vmss-cicd-agents` (debe coincidir exactamente con el `pool:` de
     `pipelines/app-cicd-pipeline.yml`).
   - **Create**.

🧑 6.3. Verifica en **Agent pools** que el pool nuevo aparece. La primera vez que un pipeline lo use,
   Azure DevOps aprovisiona una instancia desde el VMSS — tarda unos minutos más que en ejecuciones
   posteriores (cold start).

---

## Fase 7 — Pipeline principal: build → test → scan → deploy

🧑 7.1. **Library** → **+ Variable group** → nombre `cicd-ephemeral-agents-app`. Variables:

   | Variable | Valor |
   |---|---|
   | `ACR_LOGIN_SERVER` | `terraform output container_registry_login_server` |
   | `CONTAINER_APP_NAME` | `aca-fastapi-demo` |
   | `RESOURCE_GROUP_NAME` | `terraform output resource_group_name` |
   | `CONTAINER_APP_INTERNAL_FQDN` | `terraform output container_app_fqdn_internal` |

🧑 7.2. **Pipelines** → **New pipeline** → Azure Repos Git → tu repo → **Existing YAML** → path
   `/pipelines/app-cicd-pipeline.yml` → **Save**, nómbralo `app-cicd`.

🧑 7.3. Antes de correrlo: en el proyecto → **Project settings** → **Agent pools**, confirma que el
   pool `vmss-cicd-agents` esté disponible para este proyecto/pipeline.

🧑 7.4. **Run pipeline**. Primer arranque: como el pool escala desde 0 instancias, espera unos
   minutos de "cold start" mientras Azure aprovisiona la primera VM efímera desde la imagen
   publicada en la Fase 5.

🧑 7.5. Sigue el run: `BuildAndTest` (pytest) → `SecurityScan` (bandit, pip-audit, gitleaks, build
   de imagen + Trivy) → `Deploy` (solo en `main`: `az containerapp update`, que falla si la revisión
   nueva no llega a estado sano). Si algún gate de seguridad falla, el pipeline se detiene ahí — es
   el comportamiento esperado ("mecanismos activos", no solo declarativos).

---

## Fase 8 — Validar el resultado

🧑 8.1. Azure Portal → tu Container App `aca-fastapi-demo` → **Log stream** o **Revisions** →
   confirma que la revisión más reciente corresponde al build recién desplegado.

🧑 8.2. El endpoint es **interno** (no hay URL pública) — no hace falta ni se recomienda exponerlo
   públicamente para probarlo. Si querés confirmarlo manualmente, hacelo desde un recurso dentro de
   la misma VNet (por ejemplo, `az containerapp show` para obtener el FQDN, y un `curl` desde una VM
   en `snet-agents` o `snet-pe`).

---

## Fase 9 — Costos y cómo desmantelar

- Revisa el gasto real en **Cost Management + Billing** → filtra por el resource group
  `rg-cicd-dev` y compáralo contra la estimación de `docs/architecture.md §7`.
- Para desmantelar todo cuando termines la demo/sustentación (evita seguir pagando ACR Premium +
  NAT Gateway):
  ```bash
  # en Azure Cloud Shell, dentro de repo/infra
  terraform destroy
  ```
  Esto elimina también el VM Scale Set (lo gestiona Terraform). El Elastic Pool en Azure DevOps
  (Fase 6.2) y la Service Connection (Fase 4) no los gestiona Terraform — elimínalos manualmente en
  Azure DevOps si ya no los necesitas.

---

## Resumen de lo manual vs. lo automatizado

| Paso | Automatizable | Por qué |
|---|---|---|
| Red, ACR, Key Vault, identidades, Container Apps, Compute Gallery, **VM Scale Set** | ✅ Terraform | Recursos ARM estándar y maduros |
| Enlace del Elastic Pool con la organización de Azure DevOps | ❌ Manual (ADO UI) | El mecanismo "Azure virtual machine scale set" agent pool no tiene equivalente Terraform — es un objeto del lado de Azure DevOps, no de Azure |
| Service Connection OIDC | ❌ Manual (ADO UI) | Requiere permisos de administración de la organización de Azure DevOps, fuera del alcance de un proveedor de Terraform de Azure |
| Pipelines YAML | ✅ Ya están en el repo | Solo falta "importarlos" una vez desde la UI de Azure DevOps |
| Imagen dorada del agente (demo) | ✅ Pipeline (Packer) | Automatizado end-to-end una vez importado el pipeline |
