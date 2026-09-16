# Post-deployment guide

Use the section for your deployment method first. Then complete only the conditional or scenario-specific steps that apply to the features you enabled and the demonstrations you plan to run.

**The Control Center needs no separate setup after successful normal deployment.** Scripted deployment and Terraform with Stage B automatically publish the app and configure its sign-in, health access, Azure job runner/image, and selected optional agents. Portal/raw templates remain infrastructure-only; their normal workload wrapper performs the same console initialization. See [console deployment prerequisites](../workloads/webapp/LAB-OPERATIONS.md#prerequisites), including tenant registration permission and ACR Tasks availability.

Set these values before running the commands in this guide:

```powershell
$subscriptionId = '<subscription-id>'
$tenantId = '<tenant-id>'
$resourceGroup = '<resource-group>'
$namePrefix = 'amlab'
az account set --subscription $subscriptionId
$active = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $active.id -ne $subscriptionId -or $active.tenantId -ne $tenantId) { throw 'Subscription or tenant mismatch.' }
```

## Portal deployment

The Deploy to Azure button creates the Azure resources selected in the portal wizard. It does not publish the sample application or configure the Kubernetes demo workloads.

### Required

Cloud Shell's automatic credential does not support every data-plane token audience. The SLI helper queries Managed Prometheus, which uses `https://prometheus.monitor.azure.com`. Sign in explicitly as your lab operator before running the wrapper, then verify the selected account:

```powershell
az login --tenant $tenantId --use-device-code
az account set --subscription $subscriptionId
$active = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $active.id -ne $subscriptionId -or $active.tenantId -ne $tenantId) { throw 'Subscription or tenant mismatch.' }
```

Complete the device-code sign-in in your browser. This uses your user credentials, not the Cloud Shell token broker; no application secret or role change is needed for the unsupported-audience error. See [Microsoft's Cloud Shell troubleshooting guidance](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting#terminal-output---audience-service-audience-url-is-not-a-supported-msi-token-audience).

Run the Cloud Shell wrapper after the portal deployment succeeds:

```powershell
git clone https://github.com/claestom/azure-monitor-lab.git
cd azure-monitor-lab
./scripts/post-cloud-shell-deploy.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroup $resourceGroup -NamePrefix $namePrefix
```

The wrapper:

- Publishes the .NET sample to App Service.
- Automatically configures console operator sign-in, health access, the seven-operation Azure job runner, and available optional agent integrations.
- Applies the AKS frontend, load generator, and OpenTelemetry workloads.
- Creates the hourly summary rule.
- Creates the Service Group and its resource-group membership.
- Uses the Health Model deployed by the portal template and verifies the SLI identity prerequisites.
- Verifies that the Managed Prometheus source metrics for the SLI examples are flowing.
- Discovers and validates a deployed SRE Agent and its monitoring connectors. Failed discovery or validation stops completion.

### Conditional

- **AI stage enabled:** the workload wrapper already prepares the console's demo agents. Run `./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -NamePrefix $namePrefix` only when generating optional background scenario traffic. The models are billable.
- **SRE Agent stage enabled:** the workload wrapper already validates it; no separate validation command is required after success. Complete the portal authoring steps under [SRE Agent](#sre-agent) only for those incident scenarios, not for Control Center MCP use.
- **AI or SRE Agent stage disabled:** skip its setup. The corresponding scenarios are not available until that stage is enabled and deployed.

Continue with [Manual scenario setup](#manual-scenario-setup).

### Recover Prometheus Authentication

If the wrapper already stopped in [the SLI helper](../scripts/setup-slis.ps1) with `Audience https://prometheus.monitor.azure.com is not a supported MSI token audience`, the token request failed before querying metrics. This does not show that AKS stopped scraping or that the SLI identity lacks permissions. The workload publication steps ran earlier; a full redeployment is unnecessary for this error.

Run the explicit sign-in and account verification above in the same Cloud Shell session, then retry just the failed step from the repository root:

```powershell
./scripts/setup-slis.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
```

Reuse any custom `-ServiceGroupId` or `-MetricWaitMinutes` values from the failed command. The helper still requires all four source metrics to be present; it does not skip verification or substitute a management-plane token. No `az logout` is required. If your tenant disallows device-code authentication, use an approved interactive sign-in from local PowerShell 7 and retry the helper there.

If the SRE Agent stage was enabled, the wrapper stopped before its final SRE validation. After the SLI check succeeds, finish that remaining step:

```powershell
./scripts/setup-sre-agent.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
```

Do not rerun AI traffic merely to recover the SLI check. Continue with the manual SLI portal fields printed by the helper and any other selected scenario steps.

## Scripted one-shot

Running `./scripts/deploy.ps1` is the most complete deployment path. Do not run a second general post-deployment wrapper after it succeeds.

`deploy.ps1` already:

- Deploys the infrastructure and monitoring resources.
- Publishes the .NET sample and configures the AKS demo workloads.
- Provisions the console runner/image and configures operator sign-in, health permissions, and selected agent access before publishing the app.
- Creates the summary rule and deployment release annotation.
- Assigns the signed-in user permission to send custom logs.
- Creates the Service Group and its resource-group membership.
- Deploys the Health Model and verifies the SLI identity permissions and source metrics.
- Runs SRE Agent validation when `stageToggles.enableStageSreAgent` is enabled.
- Runs AI setup last when `stageToggles.enableStageAI` is enabled, then starts its finite 150-conversation traffic batch in the background.

The one-shot command returns after the traffic worker acknowledges startup, without waiting for all conversations. It prints **Lab setup complete. Agent traffic started in the background.** Required console agents and access are still prepared before app publication; the final AI step does not delay SRE verification.

## Background AI Traffic

All supported AI setup entry points use the same detached worker: one-shot, standalone [AI setup](../scripts/setup-ai.ps1), and the [Cloud Shell helper](../scripts/setup-ai-cloud-shell.ps1). Traffic is always a finite background batch when requested, default 150 conversations. `-SkipTraffic` prepares agents without starting a worker; the legacy `-BackgroundTraffic` switch remains accepted but is unnecessary. Passing it as false does not select foreground mode.

Background traffic runs in a separate Python process on the deployment machine, not in the Web App or an Azure job. The process receives a snapshot of the agent IDs and inherits the configured environment without putting credentials on its command line. Each invocation starts a new finite batch, so avoid overlapping runs unless intended. Model usage remains billable and telemetry can take a few minutes to appear.

The output includes the worker PID and its log/status paths. Files are outside the repository, under `%LOCALAPPDATA%/azure-monitor-lab/ai-traffic` on Windows or `$XDG_STATE_HOME/azure-monitor-lab/ai-traffic` on Linux (default `~/.local/state`). The status records `running`, `completed`, `completed_with_errors`, or `failed`; `running` acknowledges startup, not successful model responses. Use the printed log to inspect progress and the PID to inspect or stop the process. If the process is forcibly stopped, its last status may remain `running`.

Keep the deployment machine and its Azure CLI sign-in available until the batch ends. A suspended laptop, expired sign-in, Cloud Shell session termination, or CI runner shutdown can interrupt traffic; there is no automatic restart. Standalone and Cloud Shell setup throw on failed startup or missing acknowledgment after 30 seconds. One-shot deployment catches that optional traffic failure and prints a warning instead of claiming traffic started.

Required console setup failures stop deployment. A later warning about optional AI traffic does not mean agent provisioning was skipped. To generate that scenario telemetry later:

```powershell
./scripts/setup-ai.ps1 -SubscriptionId $subscriptionId -TenantId $tenantId -ResourceGroup $resourceGroup -NamePrefix $namePrefix
```

When one-shot SRE validation succeeded, it already completed Steps 1 through 3 of the SRE Agent setup. For portal incident scenarios only, continue with [Step 4 - Verify Azure Monitor](STAGE-SRE-AGENT.md#4-verify-azure-monitor) before authoring custom investigators and response plans. These are not required for the Control Center MCP assistant.

Otherwise, continue with [Manual scenario setup](#manual-scenario-setup).

## Staged deployment

Terraform selects stages through its variables, optionally generated from the central config. Raw Bicep selects stages by deploying their dedicated templates. Complete the instructions in the relevant staged guide before running follow-up scripts:

- [Bicep staged deployment](DEPLOY-BICEP-STEP-BY-STEP.md)
- [Terraform staged deployment](DEPLOY-TERRAFORM-STEP-BY-STEP.md)

### Completion After Stage B

Terraform runs the staged wrapper automatically as part of `apply` with Stage B enabled. Do not run it again after a successful apply. Raw Bicep stage deployments remain infrastructure-only; use their normal workload completion wrapper:

```powershell
./scripts/post-staged-deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -NamePrefix $namePrefix
```

The wrapper publishes the application, initializes all baseline console dependencies and selected agent access, configures AKS workloads, and creates the summary rule. Service Group setup and SLI verification run only when Stage E is selected. The wrapper reads `stageToggles.enableStageE` from the central config and defaults to false when it is absent; an explicit `-EnableStageE $true` or `-EnableStageE $false` overrides it. Terraform passes its own selection explicitly. Existing optional resources are not deleted when this setup is skipped.

Both staged and portal completion discover deployed SRE resources for validation unless `-EnableStageSreAgent $true` or `-EnableStageSreAgent $false` is explicitly supplied. Terraform always passes its own SRE flag, independent of central config. An explicit false skips validation without deleting or disabling an existing agent. Terraform with SRE but no B runs a separate standalone validation hook; it does not publish a Web App.

### Conditional

- **Stage AI enabled:** console bootstrap prepares the agents without traffic. Run the account-scoped AI command above only for optional background traffic, or for an AI-only lab with no B/Web App. Add `-SkipTraffic` to prepare standalone agents without traffic.
- **AI or SRE added after Stage B:** Terraform apply refreshes the console automatically. Raw Bicep users must complete the conditional Web App refresh in the [staged Bicep guide](DEPLOY-BICEP-STEP-BY-STEP.md#stage-ai-deploy-optional) before optional traffic or MCP use; deploying the new template alone does not refresh app inventory/access.
- **Stage SRE without Stage B:** Terraform validates it during apply. Raw Bicep uses `./scripts/setup-sre-agent.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup`; do not call a wrapper that requires Web App and AKS. Portal investigators and response plans remain optional scenario setup.
- **Stage E enabled after the wrapper ran:** Terraform handles completion during apply. For raw Bicep, rerun the staged wrapper with `-EnableStageE $true` to configure the Service Group and verify SLI prerequisites.
- **Stage E disabled:** Health Model, SLI, Sentinel, and the other optional advanced resources from that stage are unavailable. Skip their follow-up steps.
- **Earlier stage disabled:** skip scenarios that depend on resources from that stage.

Continue with [Manual scenario setup](#manual-scenario-setup).

## Redeployment Checks

App Service infrastructure merges its telemetry settings with the app's existing settings after site creation. Existing sign-in credentials, approved-operator IDs, and console configuration are retained; those values are not template outputs. Console bootstrap still deliberately disables health/operations while required setup runs and enables them after success. A deployment that stops during bootstrap must be completed before using those controls.

Bootstrap passes the Web App's lab tags to the runner registry, environment, identity, and job and merges in resource-specific tags found before that bootstrap update. Lab-owned and component tags take precedence. This preserves custom tags present at bootstrap time; it does not recover tags already removed by an earlier infrastructure deployment or an external process.

Both Web App publishing paths embed a unique publication ID in the assembly. After ZIP upload they verify `/api/console/version` returns that exact ID, rather than accepting an older app's reachable homepage. Compression, upload, version waiting, and cleanup have explicit progress messages. An unverified version stops the deployment without submitting a second upload from the verification step; inspect App Service deployment status before retrying.

Before promoting deployment changes, test a fresh lab and a rerun with the same approved operators, then test A+B with Stage E off and on. Confirm new app-version verification, fresh operator sign-in, rejection of unapproved users, health/runner readiness, and expected tags. Offline tests do not prove tenant permissions, role propagation, regional capacity, or every live deployment path.

Resource-group deletion removes the console registry, environment, job, and runner identity. The single-tenant sign-in registration and tenant-level Service Group are separate: verify ownership and check for other consumers before deleting either. Do not delete a shared registration or Service Group as an automatic consequence of disabling a stage.

## Grafana access

The lab templates create a **Grafana Admin** role assignment at the Managed Grafana instance scope. By default, it targets the identity running the ARM deployment. Interactive portal and CLI deployments therefore grant the deploying user access. Terraform uses the same compiled Stage B assignment.

When a service principal deploys, set `grafanaAdminObjectId` (central config or Bicep parameter) or `grafana_admin_object_id` (Terraform variable) to the lab operator's or group's Microsoft Entra object ID. An explicit override replaces the deployer as the recipient. For a raw Stage B deployment, pass `grafanaAdminObjectId` to that template; it does not read the local config automatically. The portal wizard exposes the same optional field under Advanced.

If Grafana still reports that a role is required, inspect **Managed Grafana > Access control (IAM)** and verify a Grafana role for the account used to sign in. **Monitoring Reader on the Grafana managed identity is not user access**, and Azure resource ownership alone does not grant Grafana data-plane access. Newly created role assignments may take up to an hour to propagate. The deployment must have permission to create role assignments; a failed role assignment is a deployment failure, not a propagation delay.

Old deployments need the updated one-shot or Stage B template applied once with the intended operator identity. The deterministic assignment name prevents duplicate assignments on subsequent deployments for the same instance, principal, and role. Changing the selected operator does not revoke old assignments in incremental deployment mode; review IAM when operator access changes.

## Manual scenario setup

The normal deployment scripts intentionally leave some portal, data-plane, and demo-identity tasks to the presenter. Complete only the rows for scenarios you plan to use.

| Scenario | Remaining step | Applies to |
|---|---|---|
| [4 - Managed Grafana](DEMO-SCENARIOS.md#s4) | Sign in to Grafana and import dashboard `19623`. | All deployment methods when demonstrating this dashboard. |
| [27 - Granular RBAC](DEMO-SCENARIOS.md#s27) | Run `./scripts/setup-rbac-demo.ps1 -ResourceGroup $resourceGroup`, wait up to 15 minutes for ABAC propagation, and send sample records with `./scripts/send-custom-logs.ps1 -ResourceGroup $resourceGroup -Count 10`. | All deployment methods when demonstrating access as the three test identities. |
| [32 - Grafana alerting](DEMO-SCENARIOS.md#s32) | Run `./scripts/setup-grafana-alerts.ps1 -ResourceGroup $resourceGroup`. | All deployment methods when demonstrating Grafana-managed alert rules. |
| [43 - Microsoft Sentinel](DEMO-SCENARIOS.md#s43) | On first use, connect the deployed workspace to the unified Defender portal if the tenant is not already onboarded. Required Defender and workspace roles must be assigned separately. | Only when Sentinel was enabled. |
| [46 - SLIs and SLOs](DEMO-SCENARIOS.md#s46) | Create `sli-aks-pods-running` and `sli-aks-pod-start-latency` in the Azure portal using the URL and resource IDs printed by the setup script. | Only when the Health Model and SLI prerequisites were deployed. |

The SLI helper verifies prerequisites but intentionally does not create the preview `Microsoft.Monitor/slis` resources. Wait until it confirms all four source metric families are flowing, follow the exact fields in Scenario 46, and allow 10-15 minutes for evaluated metrics to appear.

## SRE Agent

This section applies only when the optional SRE Agent stage was enabled. Infrastructure deployment creates the Sweden Central agent, identities, RBAC, and monitoring connectors. The setup script validates those resources but does not create portal-owned investigators or response plans.

Before running Scenarios [55 through 59](DEMO-SCENARIOS.md#s55):

1. Open the deployed agent in `sre.azure.com`.
2. Connect Azure Monitor under **Incidents > Triggers & response plans** if it is not already connected.
3. Create `amlab-app-investigator` and `amlab-platform-investigator` using the instructions in [Stage SRE Agent](STAGE-SRE-AGENT.md).
4. Create the `amlab-app-alerts` and `amlab-platform-alerts` response plans in Review mode.
5. Confirm both response plans are On before generating incidents.

The exact investigator instructions, filters, and response-plan values are in [Scenario 54](DEMO-SCENARIOS.md#s54).

## Other conditional features

These features are deployed only when selected in the portal or enabled in the deployment configuration. They do not require another general post-deployment script.

| Feature | What remains after deployment |
|---|---|
| [Platform Logs DCR](DEMO-SCENARIOS.md#s51) | Nothing when `enablePlatformLogsDcr` was enabled successfully. If it was disabled, enable the flag and redeploy before using the scenario. |
| [Metrics Export DCR](DEMO-SCENARIOS.md#s52) | Nothing when `enableMetricsExportDcr` was enabled successfully. If it was disabled, enable the flag and redeploy before using the scenario. |
| [LAW replication](DEMO-SCENARIOS.md#s41) | Allow replication to become active when it was enabled. If disabled, enable it and provide a secondary region before redeploying. |
| [SIEM webhook](DEMO-SCENARIOS.md#s38) | Nothing when a valid `siemWebhookUrl` was supplied. Otherwise provide the external endpoint and redeploy before demonstrating fan-out. |
| [AI FinOps](DEMO-SCENARIOS.md#s53) | Allow generated telemetry to arrive after the applicable AI setup script completes. Skip this scenario when the AI stage was not enabled. |

## Optional demo data preparation

These actions are not required to complete deployment. Run them shortly before the corresponding demonstration when you need fresh or visible data.

| Scenario | Preparation |
|---|---|
| [13 - Smart Detection](DEMO-SCENARIOS.md#s13) | Run `./scripts/start-ramp.ps1 -ResourceGroup $resourceGroup` and allow time for anomaly detection. |
| [18 - Code Optimizations](DEMO-SCENARIOS.md#s18) | Run `./scripts/trigger-code-optimization.ps1 -ResourceGroup $resourceGroup`; recommendations can take 1-24 hours. |
| [19 - Predictive autoscale](DEMO-SCENARIOS.md#s19) | Allow about 14 days of metric history for the prediction chart. |
| [24 - Custom logs](DEMO-SCENARIOS.md#s24) | Run `./scripts/send-custom-logs.ps1 -ResourceGroup $resourceGroup -Count 10`. |
| [28 - Checkout metrics](DEMO-SCENARIOS.md#s28) | Send requests to `/api/checkout`. |
| [29 - Profiler and Snapshot Debugger](DEMO-SCENARIOS.md#s29) | Generate slow requests and exceptions, then allow time for collection. |
| [43 - Microsoft Sentinel](DEMO-SCENARIOS.md#s43) | Generate a new qualifying Activity Log event after ingestion is active. Historical events do not backfill. |

## Already handled

After the required wrapper for your deployment path succeeds, no separate setup is needed for the baseline Health Model, Service Group, summary rule, Managed Prometheus rule group, security posture alerts, App Service sample, or AKS OpenTelemetry workloads. Follow the individual scenario instructions only to generate demo traffic, trigger an alert, or change a feature during the presentation.

See [scripts/README.md](../scripts/README.md) for the complete script catalog and [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md) for all scenario walkthroughs.