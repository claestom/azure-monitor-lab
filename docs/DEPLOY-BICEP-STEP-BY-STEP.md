# Azure Monitor Lab - Step-by-Step Deployment with Bicep

This guide shows how to deploy the lab in controlled stages so you can enable scenarios progressively instead of shipping everything at once.

## 1) What you have today

The repository already has seven dedicated [stage templates](../infra/stages). This guide uses those templates, with the same boundaries as Terraform. [The one-shot script](../scripts/deploy.ps1) continues to use [the full-lab template](../infra/main.bicep); it is a separate deployment path, not a foundation-only deployment.

## 2) Guardrails (must-do)

1. Select and verify the expected subscription and tenant before every write. The helper below does this before preview and again before deployment.
2. Pass the resource group and subscription explicitly; local config is not automatically consumed by raw Azure CLI commands.
3. Review each stage's what-if before confirming it. Use incremental mode. Reapplying a stage is not a teardown of stages omitted from that template.
4. Use PowerShell 7 and Azure CLI with Bicep support. Stage B completion also needs the [.NET, workload-tool, Azure RBAC, and tenant permissions](../workloads/webapp/LAB-OPERATIONS.md#prerequisites) required for the Control Center. AI needs Python; optional SRE packaging also needs npm/tar.

### Planning aid

For workshop planning and customer expectation-setting, use:
- [CUSTOMER-STAGE-HANDOUT.md](CUSTOMER-STAGE-HANDOUT.md)

### Per-stage deep dives (deployed inventory + speaker notes + UI/CLI walkthroughs)

- [STAGE-A-FOUNDATION.md](STAGE-A-FOUNDATION.md)
- [STAGE-B-WORKLOADS.md](STAGE-B-WORKLOADS.md)
- [STAGE-C-ALERTING.md](STAGE-C-ALERTING.md)
- [STAGE-D-SECURITY-POSTURE.md](STAGE-D-SECURITY-POSTURE.md)
- [STAGE-E-OPTIONAL-ADVANCED.md](STAGE-E-OPTIONAL-ADVANCED.md)
- [STAGE-AI.md](STAGE-AI.md)
- [STAGE-SRE-AGENT.md](STAGE-SRE-AGENT.md)

## 3) Stage model (recommended)

Deploy in this order.

1. Stage A - Core observability foundation
2. Stage B - Workload telemetry and dashboards
3. Stage C - Alerts and auto-mitigation
4. Stage D - Security posture scenarios
5. Stage E - Optional advanced/security add-ons
6. Stage AI - Optional Microsoft Foundry GenAI workload (off by default)
7. Stage SRE Agent - Optional Azure SRE Agent evaluation (off by default)

## 4) Stage details (scenarios + deployed services)

Use this as the workshop script: each stage adds a bounded set of capabilities and scenarios.

| Stage | High-level scenario goals | Scenario IDs (from DEMO-SCENARIOS.md) | Azure services/resources deployed |
|---|---|---|---|
| Stage A - Core observability foundation | Establish the telemetry backbone and governance baseline. | 1, 5, 6, 9 (foundation portions) | Central LAW + AppInsights LAW, workspace-based App Insights, Azure Monitor Workspace, DCE, VNet/NSG, shared storage/Event Hub/Key Vault, VM Insights and workspace-transform DCRs, diagnostic policy, saved queries, KQL functions, traffic-lights and cost workbooks. Create the resource group separately. No VMs, AKS, or Web App yet. |
| Stage B - Workload telemetry and dashboards | Onboard compute and app workloads into the monitoring plane and expose dashboards. | 2, 3, 4, 22, 28, 29, 30, 31, 32, 34, 35, 36, 42 | Optional Linux/Windows VMs + AMA/DCR associations, AKS + Container Insights + Managed Prometheus, Managed Grafana, App Service plan/web app + App Insights, console registry/job platform and custom-log ingestion, connection monitor, flow logs. The completion script publishes workloads and configures console sign-in, access, and the runner image. |
| Stage C - Alerts and response | Add actionable detection and automated response controls. | 7, 8, 12, 15, 17, 19, 23, 37 | Action Group, metric alerts, scheduled query alerts, activity log alerts (service/resource health), AMBA baseline alerts, dynamic thresholds, VMSS predictive autoscale assets, alert processing rules, auto-mitigation Logic App webhook path. |
| Stage D - Security posture (Azure Monitor native) | Build non-SIEM security posture detections directly in Azure Monitor. | 27, 47, 48, 49 | Log Analytics RBAC model (workspace/table/row scope), AzureActivity routing prerequisite, scheduled query alerts for control-plane drift, role assignment changes, and exfil early-warning correlation, alert routing via existing Action Group. |
| Stage E - Optional advanced/security add-ons | Layer advanced SOC and reliability preview capabilities. | 43, 44, 45, 46 | Optional Sentinel onboarding + analytics rule, Heartbeat data export, Managed Prometheus rule group, availability test, workload health model, SLI identity prerequisites, and optional platform-logs/metrics-export DCRs. Completion configures the Service Group and verifies SLI prerequisites; preview SLIs remain a portal step. |
| Stage AI - Optional GenAI workload | Add a Microsoft Foundry workload emitting token/trace/cost telemetry, with AI FinOps observability. Off by default (billable models, region-limited). | - | Foundry account + project in swedencentral by default, four model deployments (gpt-5-mini, text-embedding-3-small, gpt-5.4, model-router), App Insights connection, token alerts, AI FinOps query pack + workbook. Stage E can add the AI health tier after AI is deployed; a standalone AI health model is separately opt-in. Agent setup starts a finite background traffic batch unless skipped. |
| Stage SRE Agent - Optional incident investigation | Add Azure SRE Agent investigation and Review-mode response workflows. Off by default (preview and billable). | 54, 55, 56, 57, 58 | Azure SRE Agent hard pinned to swedencentral, system-assigned and user-assigned managed identities, Azure Monitor, Application Insights, and Log Analytics connectors, resource-group reader roles, and subscription-scope Monitoring Contributor. |

### Stage dependency chain

1. Stage A is mandatory for all other stages.
2. Stage B depends on Stage A outputs (workspaces/network/monitor workspace).
3. Stage C depends on Stage B resources for alert scopes.
4. Stage D depends on Stage A ingestion and Stage C action routing.
5. Stage E depends on A, B, and C. Its AI health tier additionally requires Stage AI to have been deployed.
6. Stage AI depends only on Stage A (it connects to `appi-amlab`); deploy it any time after Stage A.
7. Stage SRE Agent depends only on Stage A (Application Insights and central LAW); deploy it any time after Stage A.

The Control Center requires Stage B. Its Foundry Playground additionally requires AI; its SRE MCP Assistant requires both AI and SRE. An A+AI or A+SRE lab is valid without a Web App. Portal investigators and response plans are separate scenarios, not prerequisites for the MCP assistant.

### Stage acceptance criteria (high level)

1. Stage A done: the shared monitoring/network resources, DCRs, workbooks, and policy are present. Workload telemetry is not expected before workloads exist.
2. Stage B done: the completion script verifies the new app publication, approved console sign-in/access work, and enabled VM/AKS/App Service telemetry reaches the monitoring plane.
3. Stage C done: at least one alert test reaches the Action Group.
4. Stage D done: scenario 47/48/49 queries return data and alert rules evaluate.
5. Stage E done: optional feature endpoints/blades become accessible and testable.
6. Stage AI done: Foundry model deployments exist, App Insights receives AI telemetry, and the AI FinOps queries return data after `setup-ai.ps1` runs.
7. Stage SRE Agent done: the agent is in `swedencentral`, all three connectors are configured, and identity-specific RBAC validation passes.

## 5) Practical deployment commands (stage-by-stage)

Run these examples from the repository root in the same PowerShell 7 session. Each call previews one dedicated stage and asks for confirmation before deployment. Raw Bicep is infrastructure-only until the documented completion step succeeds.

### Step 0 - Bootstrap inputs (recommended)

Create a private config from [the example](../lab.config.json.example), fill in the subscription, tenant, resource group, prefix, region, notification address, and VM credentials, then generate the local inputs. Do not overwrite an existing config:

```powershell
if (-not (Test-Path ./lab.config.json)) { Copy-Item ./lab.config.json.example ./lab.config.json }
```

After editing the config, run:

```powershell
./scripts/sync-config.ps1
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$config = Get-Content ./lab.config.json -Raw | ConvertFrom-Json
$sub = [guid]$config.subscriptionId
$tenant = [guid]$config.tenantId
$rg = $config.resourceGroup
$sourceParameters = (Get-Content ./infra/main.parameters.json -Raw | ConvertFrom-Json -AsHashtable).parameters
$prefix = $sourceParameters.namePrefix.value
$location = $sourceParameters.location.value

. ./scripts/staged-deploy-helpers.ps1

Assert-LabAccount
az group create --subscription $sub --name $rg --location $location --output none
```

The leading dot loads [the stage helpers](../scripts/staged-deploy-helpers.ps1) into the current session. After updating the repository, rerun `. ./scripts/staged-deploy-helpers.ps1` to replace an older `Invoke-LabStage` definition. Loading this file makes no Azure calls and preserves your current inputs; it does not rerun any stage.

The helper reads each shipped compiled template's parameter schema, copies only matching inputs from the generated main parameters, and preserves secure values or ARM Key Vault references. It passes a temporary parameters-file path to Azure CLI, never the VM password itself, restricts that file to its owner on Linux, and removes it in `finally`. On Windows, use your private user temp directory. Keep the config and generated files private; do not commit them or paste secrets into `-Overrides`.

Stage-specific inputs can be supplied with `-Overrides`, for example `@{ routerModelVersion = '<available-version>' }` for AI. Inputs not supplied use that stage's defaults. Do not pass the complete main parameters file directly to a stage template. If editing Bicep, rebuild the corresponding JSON schema too, as described in [the Terraform guide](DEPLOY-TERRAFORM-STEP-BY-STEP.md#regenerating-stage-templates-from-bicep).

Config stage toggles select one-shot/Terraform stages; they do not execute these Bicep stage calls. Run only the stages you want. Rerun the bootstrap block after changing shared config. Keep the same resource group, prefix, and VM-enable settings across dependent stages.

### Stage A deploy

```powershell
Invoke-LabStage -Stage '00-foundation'
```

This deploys [foundation only](../infra/stages/00-foundation.bicep). There is no AKS node pool or Web App in Stage A.

### Stage B deploy

```powershell
Invoke-LabStage -Stage '10-workloads'
./scripts/post-staged-deploy.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -EnableStageE $false
```

Completion publishes and verifies the App Service, initializes the Control Center and approved operator access, applies AKS workloads, and creates the summary rule. It prepares available AI agents without traffic and validates any deployed SRE Agent. Stage E is explicitly off here because it has not been deployed yet. For noninteractive setup, pass approved user IDs through `-ConsoleOperatorObjectIds`; otherwise existing operators or the signed-in user are used.

### Stage C deploy

```powershell
Invoke-LabStage -Stage '20-alerting'
```

This stage requires the VMSS administrator password and notification email from the private inputs, even when the optional standalone VMs are disabled.

### Stage D deploy

Ensure AzureActivity is routed to the actual suffixed central LAW before validating the security scenarios:

```powershell
Assert-LabAccount
$workspaces = az monitor log-analytics workspace list --subscription $sub -g $rg -o json | ConvertFrom-Json
$centralLaw = $workspaces | Where-Object { $_.name -like "law-$prefix-central-*" } | Select-Object -First 1
if (-not $centralLaw.id) { throw 'Central workspace not found.' }
$logs = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
az monitor diagnostic-settings subscription create --subscription $sub --name "$prefix-activity-to-law" --location global --workspace $centralLaw.id --logs $logs
Invoke-LabStage -Stage '30-security-posture'
```

The security template reuses the Stage A LAW and Stage C action group. It does not deploy workloads or enable a SIEM.

### Stage E deploy

```powershell
. ./scripts/staged-deploy-helpers.ps1
Invoke-LabStage -Stage '40-optional-advanced' -Overrides @{ enableAi = $false }
Invoke-LabStage -Stage '41-sentinel-content'
./scripts/post-staged-deploy.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -EnableStageE $true
```

The first line refreshes the helper so an older session accepts `41-sentinel-content`. If Stage 40 already succeeded with Sentinel enabled, load the helper and resume at Stage 41, then run the completion script. Stages A through D do not need to be rerun.

Use `enableAi = $true` only when Stage AI already exists. Sentinel onboarding and the optional DCRs follow the supplied parameters or stage defaults; review the preview and billing implications. Run `41-sentinel-content` only when Sentinel is enabled. Completion configures the Service Group and verifies SLI prerequisites. Create the preview SLIs in the portal using the printed handoff.

Sentinel uses two deployments because its analytics-rule provider cannot preview a rule until the workspace is already onboarded. Stage E first creates the onboarding state, then `41-sentinel-content` previews and creates the dependent demo rule with normal provider validation.

### Stage AI deploy (optional)

Deploy after Stage A. Verify Model Router version availability for `aiLocation` before opting in; the default is `swedencentral`. If Stage B already exists, refresh its package, inventory, and agent permissions before starting optional traffic:

```powershell
Invoke-LabStage -Stage '50-ai'
$apps = az webapp list --subscription $sub --resource-group $rg -o json | ConvertFrom-Json
$webApp = $apps | Where-Object { $_.name -like "app-$prefix-*" } | Select-Object -First 1
if ($webApp) {
   ./scripts/deploy-webapp.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -WebAppName $webApp.name
}
./scripts/setup-ai.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -NamePrefix $prefix
```

The refresh uses [the existing app deployment helper](../scripts/deploy-webapp.ps1), which configures console access and verifies the new publication without reapplying AKS workloads. Its bootstrap prepares agents with `-SkipTraffic`. The final [AI setup](../scripts/setup-ai.ps1) reuses those agents and always starts a finite background batch, default 150 conversations. Add `-SkipTraffic` there to prepare agents without model traffic. The [Cloud Shell AI wrapper](../scripts/setup-ai-cloud-shell.ps1) offers the same background behavior with core ARM discovery.

Without Stage B, the refresh is skipped and the standalone AI scenario still works. Adding Stage B later initializes its console normally. To add the AI tier to an existing Stage E health model, rerun Stage E with `-Overrides @{ enableAi = $true }`; do not deploy Stage E solely for an A+AI lab. A separate AI health model can instead be requested with Stage AI's `enableHealthModel` override.

The worker prints its PID and log/status paths. Keep the deployment host and Azure CLI sign-in available until it finishes; Cloud Shell/CI termination can stop it. Startup is not evidence of successful model responses. See [background traffic details](POST-DEPLOYMENT.md#background-ai-traffic).

### Stage SRE Agent deploy (optional)

Deploy after Stage A. The template creates the `swedencentral` agent, managed identities, monitoring connectors, and RBAC. Subscription-scope role-assignment permission is required. Validate the deployed resource before refreshing any existing console:

```powershell
Invoke-LabStage -Stage '60-sre-agent'
./scripts/setup-sre-agent.ps1 -SubscriptionId $sub -ResourceGroup $rg
$apps = az webapp list --subscription $sub --resource-group $rg -o json | ConvertFrom-Json
$webApp = $apps | Where-Object { $_.name -like "app-$prefix-*" } | Select-Object -First 1
if ($webApp) {
   ./scripts/deploy-webapp.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -WebAppName $webApp.name
}
```

An A+SRE deployment needs no Web App or AKS, so it uses [the standalone validator](../scripts/setup-sre-agent.ps1), not the Stage B completion wrapper. With B and AI present, the refresh enables the Control Center's SRE MCP Assistant. The validator is read-only unless explicitly asked to grant missing roles; it does not start an investigation.

Follow [Stage SRE Agent](STAGE-SRE-AGENT.md) only when demonstrating the separate portal investigator and Review-mode response-plan scenarios. Those are not required for Control Center MCP questions and approved operations.

## 6) Stage boundaries and reruns

The stage templates resolve prior-stage resources using the resource group and shared prefix. They do not accept the full-lab parameter set or redeploy earlier workloads. Keep shared naming and VM-enable settings consistent. When rerunning an earlier stage, inspect its what-if and rerun its documented completion step if app configuration or workloads changed. Incremental deployment does not remove resources just because a stage or optional parameter is omitted.

## 7) Validation checklist per stage

After each stage:
1. Inspect the deployment named `stage-<template-stem>`, for example `stage-00-foundation`, in the selected resource group.
2. Verify expected resources exist.
3. Run at least one saved query relevant to that stage.
4. For security stage, run:

```kql
AzureActivity
| where TimeGenerated > ago(1d)
| summarize count()
```

If count is zero, security-posture scenarios 47/48/49 will not fire.

## 8) Tearing down the lab

When done, run the teardown script. It first disables LAW replication and removes nested DCR associations, DCRs, and DCEs in dependency order, then starts the resource-group deletion. Azure-managed DCEs that reject direct deletion are left for the LAW/RG cascade.

### Step 1 - Run the teardown wrapper

```powershell
$sub='<your-subscription-id>'
$rg='rg-azure-monitor-lab'   # set this to the RG where you deployed the lab; this is the default
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
./scripts/teardown.ps1 -ResourceGroup $rg -Yes
```

`teardown.ps1` validates the subscription guardrail, disables LAW replication, removes nested DCR associations and other monitoring dependencies, removes the tenant-scoped SLI and Service Group artifacts, and then deletes the resource group. This works for both staged Bicep and one-shot Bicep deployments.

### Step 2 - Clean up artifacts that live outside the RG

A few resources are subscription-scoped or live in `NetworkWatcherRG` and survive RG deletion.

1. Soft-deleted Log Analytics workspaces (14-day grace period; names stay reserved):

```powershell
# Keep the filter in PowerShell. Windows Azure CLI can strip quoted JMESPath
# expressions before az receives them, producing "] was unexpected at this time."
$deletedLaw = az monitor log-analytics workspace list-deleted-workspaces --subscription $sub -o json | ConvertFrom-Json
$deletedLaw | Where-Object { $_.name -like '*amlab*' } | Format-Table
# Permanent purge if needed:
# az rest --method delete --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.OperationalInsights/locations/northeurope/deletedWorkspaces/<name>?api-version=2023-09-01"
```

2. Soft-deleted Application Insights components (also 14-day grace):

```powershell
$deletedAppInsights = az monitor app-insights component list-deleted --subscription $sub -o json | ConvertFrom-Json
$deletedAppInsights | Where-Object { $_.name -like '*amlab*' } | Format-Table
```

3. Soft-deleted Key Vault (7-day retention, `enablePurgeProtection: null` so it can be purged). Key Vault names are deterministic (`kv-${namePrefix}-${take(suffix,5)}` from `resourceGroup().id`), so redeploying to the **same RG name** before the vault is purged fails with `VaultAlreadyExists`:

```powershell
$deletedVaults = az keyvault list-deleted --subscription $sub -o json | ConvertFrom-Json
$deletedVaults | Where-Object { $_.name -like 'kv-amlab-*' } | Format-Table name, @{n='location';e={$_.properties.location}}
# Purge before redeploying to the same RG name:
# az keyvault purge --name <vaultName> --subscription $sub
```

4. NSG/VNet flow logs in `NetworkWatcherRG` (Stage B creates them outside the lab RG):

```powershell
$flowLogs = az network watcher flow-log list -l northeurope --subscription $sub -o json | ConvertFrom-Json
$flowLogs | Where-Object { $_.name -like '*amlab*' } | Select-Object name, enabled | Format-Table
# az network watcher flow-log delete -l northeurope -n <flowLogName> --subscription $sub
```

5. Custom role definition from Stage D (`AMLAB - Granular Log Reader`). Auto-removed once no scopes reference it; force-delete if it lingers:

```powershell
az role definition list --custom-role-only true --subscription $sub --query "[?starts_with(roleName,'AMLAB - Granular Log Reader')]" -o table
# az role definition delete --name "AMLAB - Granular Log Reader" --subscription $sub
```

6. Sentinel onboarding (if Stage E enabled it) lives on the LAW, so it goes with the RG. No extra action needed.

### Step 4 - Confirm

```powershell
az group exists -n $rg --subscription $sub   # false once the async delete completes
```
