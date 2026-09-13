# Azure Monitor Lab

A self-contained demo centered on Azure Monitor, AI, and Azure SRE Agent, with optional Microsoft Sentinel scenarios. Everything runs from a single config file that stays out of git, so you can stand the whole thing up in your own subscription and tear it back down when you're finished.

- One resource group: the whole lab lands in `rg-azure-monitor-lab`.
- Two ways to deploy it: Bicep or Terraform.
- Three ways to run it: a single-click [Deploy to Azure](#option-1-deploy-to-azure-portal-no-local-setup) button for the Azure portal, a scripted one-shot deployment using PowerShell, or a 5-stage workshop you can walk through piece by piece.
- 58 demo scenarios that cover Azure Monitor, Sentinel, and Azure SRE Agent from end to end.

It's built for demos, microhacks, and hackathons. Deploy it, poke around, break it, restore it, and tear it down.

## Use The Lab

| Experience | Start here |
|---|---|
| **Guided Scenarios** | Follow the existing [scenario walkthroughs](docs/DEMO-SCENARIOS.md) for the story, Azure portal steps, queries, and expected results. |
| **Lab Control Center** | Check infrastructure health, generate traffic, try Foundry agents, and perform approved SRE MCP operations. Open the [Control Center guide](docs/LAB-CONTROL-CENTER.md) for screenshots, access requirements, and linked scenarios. |

These are complementary entry points into the same lab. The Control Center links to the guided scenarios; it does not replace their setup or walkthroughs.

## Architecture

Everything lands in a single resource group (`rg-azure-monitor-lab`), with telemetry flowing from left to right:

1. Workloads emit signals.
2. Agents and policies collect them.
3. The telemetry backplane stores them.
4. The consumption layer turns them into dashboards, alerts, and responses.

The GenAI workload and Azure SRE Agent can also be deployed on the same telemetry backbone.

The App Service Control Center starts approved lab operations in an independent **Azure Container Apps Job**, using a digest-pinned runner image from **Azure Container Registry (ACR)**. Blue dashed arrows show approved operations; grey arrows show telemetry and image supply.

> 📦 For a full, resource-by-resource list of what gets created, see [REFERENCE.md → What gets deployed](docs/REFERENCE.md#what-gets-deployed).

[![Azure Monitor Lab architecture including Container Apps Jobs and Azure Container Registry](docs/architecture-overview-sre.svg)](docs/architecture.drawio)

## Prerequisites

- Azure CLI (`az`) 2.60 or later, logged in with `az login`
- `kubectl` (any recent version)
- Bicep CLI (bundled with `az` 2.20+), or Terraform 1.6+ if you take the Terraform path
- PowerShell 7+
- .NET 8 SDK for publishing the Control Center
- Deployment rights for the console registry, Consumption job environment, custom roles, and role assignments; tenant permission to manage its single-tenant sign-in registration and validate operator users. See [console deployment prerequisites](workloads/webapp/LAB-OPERATIONS.md#prerequisites). ACR Tasks must be available in the subscription; no local Docker or GitHub runner credentials are needed.
- A subscription with quota for ~5 small VMs/nodes (`Standard_B2s`), 1 App Service B1, Managed Grafana, Storage, Event Hub, and Key Vault
- For the optional AI stage only: Python 3.10+. `scripts/setup-ai.ps1` provisions the demo agents and traffic simulator from [`workloads/ai/`](workloads/ai/), and the models it deploys are billable.
- For deployments with an SRE Agent: npm and tar on the deployment machine to package the pinned native MCP runtime. The deployed .NET app does not need Node.js.

> Two IaC paths, one config. Bicep is the primary one (`infra/`); Terraform (`terraform/`) is a parallel implementation driven from the same `lab.config.json`. Pick one and don't mix them.

## Deploy

> Recommended region: `northeurope` (the default), which has the widest feature availability. A few things pin themselves to a fixed region no matter what you pick: the Health Model preview and the optional GenAI / AI stage (Microsoft Foundry and its models) go to `swedencentral` (they aren't available in `northeurope`), and the App Service goes to `westeurope` (the sponsored lab subscriptions have no Basic App Service quota in `northeurope`). Everything else follows the region you choose.

### Option 1: Deploy to Azure (portal, no local setup)

<div align="center">

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Fazure-monitor-lab%2Fmaster%2Finfra%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Fazure-monitor-lab%2Fmaster%2Finfra%2FcreateUiDefinition.json)

</div>

Opens a guided Custom deployment wizard in the Azure Portal, where you enter every value in the UI and don't need any local files. Sensible defaults are pre-filled throughout; the only things you have to supply are an alert email and a VM admin password.

| Tab | You provide |
|---|---|
| **Basics** | Resource group (recommended `rg-azure-monitor-lab`), Region (recommended `northeurope`), name prefix, alert email, VM admin username + password |
| **Workloads** | Deploy Linux/Windows VMs, VM size, AKS node size + count |
| **Monitoring & cost** | Daily ingestion cap, Sentinel, platform-logs/metrics-export DCRs, LAW replication |
| **Advanced** | Owner tag, optional Grafana administrator object ID, App Service sample repo, optional SIEM/Teams webhook, optional AI and SRE Agent stages |

After the portal deployment succeeds, open **Cloud Shell** in the Azure portal, select **PowerShell**, and run the commands below. The Cloud Shell wrapper discovers the deployed resources, publishes the App Service sample, installs the AKS and Health Model demo components, and verifies the identity, RBAC, and Managed Prometheus prerequisites for the SLI demo without requiring optional Azure CLI extensions:

```powershell
git clone --branch master https://github.com/claestom/azure-monitor-lab.git
cd azure-monitor-lab
$subscriptionId = Read-Host 'Subscription ID'
$resourceGroup = Read-Host 'Resource group name'
az account set --subscription $subscriptionId
./scripts/post-cloud-shell-deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
```

If the repository is already present in Cloud Shell, update it before rerunning the wrapper:

```powershell
cd ~/azure-monitor-lab
git switch master
git pull --ff-only origin master
$subscriptionId = Read-Host 'Subscription ID'
$resourceGroup = Read-Host 'Resource group name'
./scripts/post-cloud-shell-deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
```

> **Next:** Follow the [post-deployment guide for the portal option](docs/POST-DEPLOYMENT.md#portal-deployment) to finish the scenarios and optional stages you enabled.

> Use Option 2 for a scripted one-shot deployment, or Option 3 for the staged workshop and progressive deployment.

### Option 2: Scripted one-shot (Bicep / Terraform, full control)

This repo ships no secrets. You fill in one central config file, and `sync-config.ps1` generates every derived input from it.

```powershell
# 1. Clone the repo and enter it
git clone --branch master https://github.com/claestom/azure-monitor-lab.git
cd azure-monitor-lab

# 2. Copy the template and fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, ...
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json
#    → edit the values, then save the file (Ctrl+S) and close Notepad before continuing
#    → stageToggles.enableStageA-E are only used by the staged/Terraform paths; the
#      one-shot deploy always deploys everything and can leave them untouched.
#      enableStageAI deploys the optional Foundry resources, while
#      enableStageSreAgent deploys Azure SRE Agent and validates its connectors.

# 3. Deploy (deploy.ps1 calls sync-config.ps1 for you)
./scripts/deploy.ps1

# Or target a custom resource group / region (created if it doesn't exist yet):
./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
```

Defaults: resource group `rg-azure-monitor-lab`, region `northeurope`. Override them with `-ResourceGroup` / `-Location` (explicit args win over `lab.config.json`, then defaults). The group is created or reused. Infrastructure provisioning, native packaging, and the cloud runner build can take tens of minutes. A successful run includes console sign-in, health, the six-operation Azure runner, and access to selected optional agents. See [deployment reference](docs/REFERENCE.md#deploy) for config and guardrails.

<details>
<summary><b>Pre-flight check</b> (region SKU / quota validation before deploy)</summary>

Before creating anything, `deploy.ps1` runs [`scripts/preflight-check.ps1`](scripts/preflight-check.ps1), which checks in about 15 seconds that every VM SKU, vCPU quota, and PaaS resource type the lab needs is actually available in the region you picked for your subscription. It fails fast with a PASS/WARN/FAIL table instead of blowing up 20 minutes into the deployment. You can run it on its own to vet a region before committing (`./scripts/preflight-check.ps1 -Location westeurope`), or skip it with `./scripts/deploy.ps1 -SkipPreflight`.

The pre-flight checks *availability and quota*, not *live service capacity*. Transient, region-wide shortages like AKS `AksCapacityHeavyUsage` have no pre-check API and only surface at deploy time. If one hits, `deploy.ps1` catches it and points you to the fix: deploy to another region (`-Location northeurope`) or retry (`-MaxDeployRetries 3`), since capacity frees up as other clusters are deleted.

</details>

> **Next:** Follow the [post-deployment guide for the scripted one-shot option](docs/POST-DEPLOYMENT.md#scripted-one-shot) to see what `deploy.ps1` already completed and which scenario-specific steps remain.

### Option 3: Staged workshop (progressive deployment)

Use the staged approach when you want to pause between capabilities, walk through the lab with an audience, or deploy only the stages needed for a particular demo. Stages A to E can be toggled in `lab.config.json`. The optional AI and SRE Agent stages can be enabled separately after Stage A. Bicep deploys SRE Agent with `infra/stages/60-sre-agent.bicep`; Terraform deploys the compiled stage when `enable_stage_sre_agent = true`.

Step-by-step guides:

- [Bicep staged deployment](docs/DEPLOY-BICEP-STEP-BY-STEP.md)
- [Terraform staged deployment](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md)

> **Next:** Follow the [post-deployment guide for the staged option](docs/POST-DEPLOYMENT.md#staged-deployment) after completing the stages you selected.

### Grafana Access

Lab deployment assigns **Grafana Admin** to the deploying identity at the Grafana instance scope. This permits dashboard and alert setup, not subscription-wide administration. It is separate from the **Monitoring Reader** assignment that lets Grafana's own managed identity query telemetry. The assignment is included in one-shot, portal, Stage B, and Terraform deployments.

For a pipeline deployment or a different operator, set `grafanaAdminObjectId` in the [central configuration](lab.config.json.example), use the optional **Grafana administrator object ID** portal field, or set Terraform's `grafana_admin_object_id`. Use a Microsoft Entra user or group **object ID** in the deployment tenant, not an application/client ID. Empty defaults to the deployment identity; automation otherwise grants its service principal access rather than the human operator.

The deploying identity needs `Microsoft.Authorization/roleAssignments/write` at the lab scope, such as Owner or Contributor plus Role Based Access Control Administrator. After deployment, allow up to an hour for Grafana role propagation and sign in with the assigned account. Updating the repository alone does not repair an already-deployed instance; redeploy its lab/Stage B template with the correct operator ID. For view-only participants, grant Grafana Viewer separately. See [Grafana post-deployment checks](docs/POST-DEPLOYMENT.md#grafana-access).

### Lab Control Center

Normal deployment publishes the [Lab Control Center](docs/LAB-CONTROL-CENTER.md) from the checked-out branch and automatically configures sign-in, health access, and its independent Azure job runner. Open the lab's **App Service**, select **Browse**, and sign in as an approved operator. The tabs are **Infra Health**, **Traffic & Faults**, **Lab Operations**, **SRE MCP Assistant**, and **Foundry Playground**. The [six script operations](workloads/webapp/LAB-OPERATIONS.md) need no GitHub credentials or manual enablement. Foundry requires Stage AI; the SRE assistant requires both AI and SRE stages. No separate frontend build is needed for checked-in assets. See the [developer reference](workloads/webapp/README.md).

Scripted deployment and Terraform with Stage B complete this automatically. Portal/raw templates still require their normal workload-publication wrapper, which includes the same console initialization. Noninteractive deployment supplies approved user object IDs through `-ConsoleOperatorObjectIds` or Terraform's `console_operator_object_ids`; an interactive deployment defaults to its signed-in user.

Scripted, staged, and portal/Cloud Shell paths use the same packaging helper. If an SRE Agent is present, the Linux MCP runtime is included automatically. The portal template alone provisions infrastructure; complete its Cloud Shell post-deployment step to publish this application.

Monitoring links and resource context are discovered during publishing. Hosted SRE/Foundry execution remains opt-in: configure App Service Authentication, scoped managed-identity access, and the model settings described in [SRE MCP setup](workloads/webapp/SRE-MCP.md) and [Foundry setup](workloads/webapp/README.md#enable-foundry-access). The console's health, latency, error, checkout, and traffic controls are available without enabling model usage.

For an existing lab, [deploy-webapp.ps1](scripts/deploy-webapp.ps1) updates only the App Service. The optional [hosted access setup](scripts/setup-webapp-agent-access.ps1) configures operator-only sign-in and scoped agent permissions with an explicit opt-in. Both support `-WhatIf` and require explicit subscription and tenant parameters.

## Cost and lifecycle

The full lab is roughly **EUR 6-11 / USD 7-12 per day** when left running 24/7, based on the indicative list-price estimate in [REFERENCE.md](docs/REFERENCE.md#cost-notes-north-europe-list-pricing-may-2026). The USD range uses a planning rate of EUR 1 = USD 1.10 and is rounded to whole dollars. The optional AI stage adds model usage when `setup-ai.ps1` generates traffic. Do not leave the environment deployed when it is not needed: stop or deallocate compute between sessions, or run `./scripts/teardown.ps1 -Yes` and redeploy the stages for the next demo. Actual costs vary by region, currency conversion, usage, retention, and Azure pricing.

When the lab is no longer needed, set `$rg` to the resource group where you deployed the lab, then run the command below. If you used the default configuration, use `rg-azure-monitor-lab`.

```powershell
$rg = "rg-azure-monitor-lab"   # change this to the RG used for your deployment
./scripts/teardown.ps1 -ResourceGroup $rg -Yes   # deletes the whole resource group
```

## Documentation

| Doc | What's in it |
|---|---|
| [REFERENCE.md](docs/REFERENCE.md) | Full capability matrix · every deployed resource · demo walkthrough · cost breakdown · folder layout · optional add-ons · troubleshooting |
| [Lab Control Center](docs/LAB-CONTROL-CENTER.md) | Application guide, screenshot, traffic and agent capabilities, safety boundaries, and links to the guided scenarios |
| [DEMO-SCENARIOS.md](docs/DEMO-SCENARIOS.md) | All 58 demo scenarios, each with a story, a click-path, and a "killer line", plus audience-pivoted shortlists |
| [POST-DEPLOYMENT.md](docs/POST-DEPLOYMENT.md) | Required post-deployment commands by deployment option, conditional stage setup, and optional scenario preparation |
| [docs/DEPLOY-BICEP-STEP-BY-STEP.md](docs/DEPLOY-BICEP-STEP-BY-STEP.md) · [docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md) | Staged deployment tutorials |
| Stage notes: [A](docs/STAGE-A-FOUNDATION.md) · [B](docs/STAGE-B-WORKLOADS.md) · [C](docs/STAGE-C-ALERTING.md) · [D](docs/STAGE-D-SECURITY-POSTURE.md) · [E](docs/STAGE-E-OPTIONAL-ADVANCED.md) · [AI](docs/STAGE-AI.md) · [SRE Agent](docs/STAGE-SRE-AGENT.md) | Per-stage speaker notes, including optional AI FinOps and SRE Agent evaluation stages |
| [docs/CUSTOMER-STAGE-HANDOUT.md](docs/CUSTOMER-STAGE-HANDOUT.md) | Per-stage time + cost cheat sheet |

## Contributing & license

Contributions are welcome. See [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the [Code of Conduct](.github/CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](.github/SECURITY.md).

Licensed under the [MIT License](LICENSE): free to use, modify, and redistribute (including for microhacks, hackathons, and your own demos), and provided as-is without warranty.
