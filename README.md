# Azure Monitor Lab

A self-contained demo centered on Azure Monitor, AI, and Azure SRE Agent, with optional Microsoft Sentinel scenarios. Everything runs from a single config file that stays out of git, so you can stand the whole thing up in your own subscription and tear it back down when you're finished.

- One resource group: the whole lab lands in `rg-azure-monitor-lab`.
- Two ways to deploy it: Bicep or Terraform.
- Three ways to run it: a single-click [Deploy to Azure](#option-1-deploy-to-azure-portal-no-local-setup) button for the Azure portal, a scripted one-shot deployment using PowerShell, or a 5-stage workshop you can walk through piece by piece.
- 67 numbered demo scenarios that cover Azure Monitor, Sentinel, Azure SRE Agent, and optional Fabric Real-Time Intelligence.

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

The App Service Control Center starts approved lab operations in an independent **Azure Container Apps Job**, using a digest-pinned runner image from **Azure Container Registry (ACR)**.

An optional Microsoft Fabric stage (off by default) adds an F2 capacity in `swedencentral`, then provisions a workspace, Eventhouse, KQL database, and Eventstream for Real-Time Intelligence scenarios. Setup attempts to create the Event Hubs connection and publish the source-to-Eventhouse topology automatically. Some tenants reject Shared Access Key connection creation through the public Fabric API; in that case, create the connection once in the Fabric portal and rerun setup to publish the topology automatically. The architecture shows the Eventstream path from Azure Event Hubs using the official Fabric item icon, and the capacity appears under an optional Real-Time Intelligence tier in the workload Health Model. F2 costs about $0.36/hour, $8.64/day, or $262.80/month while active at indicative PAYG retail pricing, so suspend it when idle. Microsoft recommends at least F4 for Eventstreams; this lab keeps F2 for light demo traffic and cost control.

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
- For the optional Fabric stage only: the tenant must have Fabric enabled, and `fabricAdminEmail` must be a Microsoft Entra user UPN in that tenant with workspace creation and capacity administration permissions. Do not reuse an external alert alias. The F2 capacity is billable while active.
- For deployments with an SRE Agent: npm and tar on the deployment machine to package the pinned native MCP runtime. The deployed .NET app does not need Node.js.

> Two IaC paths, one config. Bicep is the primary one (`infra/`); Terraform (`terraform/`) is a parallel implementation driven from the same `lab.config.json`. Pick one and don't mix them.

## Deploy

> Recommended region: `northeurope` (the default), which has the widest feature availability. A few things pin themselves to a fixed region no matter what you pick: the Health Model preview and the optional GenAI / AI stage (Microsoft Foundry and its models) go to `swedencentral` (they aren't available in `northeurope`), and the App Service goes to `westeurope` (the sponsored lab subscriptions have no Basic App Service quota in `northeurope`). Everything else follows the region you choose.

### Option 1: Deploy to Azure (portal, no local setup)

> The public button below intentionally targets `master`, which does not include the in-progress Fabric stage. To test Fabric before merge, deploy from `feature/fabric-stage` with `scripts/deploy.ps1`, or open a Custom deployment using that branch's `infra/main.json` and `infra/createUiDefinition.json` raw URLs.

<div align="center">

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Fazure-monitor-lab%2Fmaster%2Finfra%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Fazure-monitor-lab%2Fmaster%2Finfra%2FcreateUiDefinition.json)

</div>

Opens a guided Custom deployment wizard in the Azure Portal, where you enter every value in the UI and don't need any local files. Sensible defaults are pre-filled throughout; you supply an alert email and VM admin password, plus a tenant user UPN when enabling Fabric.

| Tab | You provide |
|---|---|
| **Basics** | Resource group (recommended `rg-azure-monitor-lab`), Region (recommended `northeurope`), name prefix, alert email, VM admin username + password |
| **Workloads** | Deploy Linux/Windows VMs, VM size, AKS node size + count |
| **Monitoring & cost** | Daily ingestion cap, Sentinel, platform-logs/metrics-export DCRs, LAW replication |
| **Advanced** | Owner tag, optional Grafana administrator object ID, App Service sample repo, optional SIEM/Teams webhook, optional AI, SRE Agent, and Fabric F2 stages |

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

If you enabled Fabric, run its Cloud Shell setup to create the tenant-scoped workspace and Real-Time Intelligence items. The F2 capacity is pinned to `swedencentral` and costs about $0.36/hour, $8.64/day, or $262.80/month while active at indicative PAYG retail pricing.

```powershell
./scripts/setup-fabric-cloud-shell.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
./scripts/suspend-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

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
#      enableStageFabric deploys the optional Fabric capacity and SaaS setup.

# 3. Deploy (deploy.ps1 calls sync-config.ps1 for you)
./scripts/deploy.ps1

# Or target a custom resource group / region (created if it doesn't exist yet):
./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
```

Defaults: resource group `rg-azure-monitor-lab`, region `northeurope`. Override them with `-ResourceGroup` / `-Location` (explicit args win over `lab.config.json`, then defaults). The group is created or reused. Infrastructure provisioning, native packaging, and the cloud runner build can take tens of minutes. A successful run includes console sign-in, health, the seven-operation Azure runner, and access to selected optional agents. See [deployment reference](docs/REFERENCE.md#deploy) for config and guardrails.

<details>
<summary><b>Pre-flight check</b> (region SKU / quota validation before deploy)</summary>

Before creating anything, `deploy.ps1` runs [`scripts/preflight-check.ps1`](scripts/preflight-check.ps1), which checks in about 15 seconds that every VM SKU, vCPU quota, and PaaS resource type the lab needs is actually available in the region you picked for your subscription. It fails fast with a PASS/WARN/FAIL table instead of blowing up 20 minutes into the deployment. You can run it on its own to vet a region before committing (`./scripts/preflight-check.ps1 -Location westeurope`), or skip it with `./scripts/deploy.ps1 -SkipPreflight`.

The pre-flight checks *availability and quota*, not *live service capacity*. Transient, region-wide shortages like AKS `AksCapacityHeavyUsage` have no pre-check API and only surface at deploy time. If one hits, `deploy.ps1` catches it and points you to the fix: deploy to another region (`-Location northeurope`) or retry (`-MaxDeployRetries 3`), since capacity frees up as other clusters are deleted.

</details>

> **Next:** Follow the [post-deployment guide for the scripted one-shot option](docs/POST-DEPLOYMENT.md#scripted-one-shot) to see what `deploy.ps1` already completed and which scenario-specific steps remain.

> Optional Fabric stage. Set `stageToggles.enableStageFabric` for one-shot Bicep or `enable_stage_fabric` for Terraform. It deploys an F2 capacity pinned to `swedencentral`; then `setup-fabric.ps1` creates the Fabric SaaS items and attempts to publish the Eventstream topology. After deployment, follow the [Fabric post-deploy checklist](docs/STAGE-FABRIC.md#after-deployps1-checklist) to handle any one-time connection fallback, verify ingestion, create the Real-Time Dashboard, and suspend F2. Indicative PAYG retail cost while active is about $0.36/hour, $8.64/day, or $262.80/month, plus possible storage and usage charges.

### Option 3: Staged workshop (progressive deployment)

Use the staged approach when you want to pause between capabilities, walk through the lab with an audience, or deploy only the stages needed for a particular demo. Stages A to E can be toggled in `lab.config.json`. The optional AI, SRE Agent, and Fabric stages can be enabled separately. Bicep deploys SRE Agent with `infra/stages/60-sre-agent.bicep`; Terraform deploys the compiled stage when `enable_stage_sre_agent = true`. Fabric uses `infra/stages/60-fabric.bicep` or `enable_stage_fabric = true`; its streaming scenario needs Stage A's Event Hub.

Step-by-step guides:

- [Bicep staged deployment](docs/DEPLOY-BICEP-STEP-BY-STEP.md)
- [Terraform staged deployment](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md)

> **Next:** Follow the [post-deployment guide for the staged option](docs/POST-DEPLOYMENT.md#staged-deployment) after completing the stages you selected.

### Lab Control Center

The [Lab Control Center](docs/LAB-CONTROL-CENTER.md) runs in the lab's existing **Web App**. Use it to control the lab from your browser, including starting, breaking, and restoring it.

In **Lab Operations**, **Simulate High CPU** submits a self-expiring 10-minute CPU load to both running demo VMs after review and approval. You can also run [simulate-high-cpu.ps1](scripts/simulate-high-cpu.ps1) directly; see the [script commands](scripts/README.md#lab-lifecycle-and-demo-control) and [CPU prerequisites and limits](workloads/webapp/LAB-OPERATIONS.md#simulate-high-cpu). Existing labs need the normal [console upgrade](scripts/deploy-webapp.ps1) to receive the new button, runner image, and VM permissions.

Retrieve its URL in PowerShell or Azure Cloud Shell (PowerShell):

```powershell
$subscriptionId = Read-Host 'Subscription ID'
$resourceGroup = Read-Host 'Resource group name'
az webapp list --subscription $subscriptionId --resource-group $resourceGroup --query "[].defaultHostName" --output tsv | ForEach-Object { "https://$_" }
```

## Cost and lifecycle

The full lab is roughly **EUR 6-11 / USD 7-12 per day** when left running 24/7, based on the indicative list-price estimate in [REFERENCE.md](docs/REFERENCE.md#cost-notes-north-europe-list-pricing-may-2026). The USD range uses a planning rate of EUR 1 = USD 1.10 and is rounded to whole dollars. The optional AI stage adds model usage when `setup-ai.ps1` generates traffic. Do not leave the environment deployed when it is not needed: stop or deallocate compute between sessions, or run `./scripts/teardown.ps1 -Yes` and redeploy the stages for the next demo. Actual costs vary by region, currency conversion, usage, retention, and Azure pricing.

The optional Fabric F2 stage adds about **USD 8.64 per active day** or **USD 262.80 per active month** at indicative PAYG retail pricing, plus possible OneLake storage and other usage charges. Suspend Fabric between sessions.

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
| [DEMO-SCENARIOS.md](docs/DEMO-SCENARIOS.md) | All 67 numbered demo scenarios, each with a story, a click-path, and a "killer line", plus audience-pivoted shortlists |
| [POST-DEPLOYMENT.md](docs/POST-DEPLOYMENT.md) | Required post-deployment commands by deployment option, conditional stage setup, and optional scenario preparation |
| [docs/DEPLOY-BICEP-STEP-BY-STEP.md](docs/DEPLOY-BICEP-STEP-BY-STEP.md) · [docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md) | Staged deployment tutorials |
| Stage notes: [A](docs/STAGE-A-FOUNDATION.md) · [B](docs/STAGE-B-WORKLOADS.md) · [C](docs/STAGE-C-ALERTING.md) · [D](docs/STAGE-D-SECURITY-POSTURE.md) · [E](docs/STAGE-E-OPTIONAL-ADVANCED.md) · [AI](docs/STAGE-AI.md) · [SRE Agent](docs/STAGE-SRE-AGENT.md) · [Fabric](docs/STAGE-FABRIC.md) | Per-stage speaker notes, including the optional AI, SRE Agent, and Fabric stages |
| [docs/CUSTOMER-STAGE-HANDOUT.md](docs/CUSTOMER-STAGE-HANDOUT.md) | Per-stage time + cost cheat sheet |

## Contributing & license

Contributions are welcome. See [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the [Code of Conduct](.github/CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](.github/SECURITY.md).

Licensed under the [MIT License](LICENSE): free to use, modify, and redistribute (including for microhacks, hackathons, and your own demos), and provided as-is without warranty.
