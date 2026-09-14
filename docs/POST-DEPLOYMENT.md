# Post-deployment guide

Use the section for your deployment method first. Then complete only the conditional or scenario-specific steps that apply to the features you enabled and the demonstrations you plan to run.

**The Control Center needs no separate setup after successful normal deployment.** Scripted deployment and Terraform with Stage B automatically publish the app and configure its sign-in, health access, Azure job runner/image, and selected optional agents. Portal/raw templates remain infrastructure-only; their normal workload wrapper performs the same console initialization. See [console deployment prerequisites](../workloads/webapp/LAB-OPERATIONS.md#prerequisites), including tenant registration permission and ACR Tasks availability.

Set these values before running the commands in this guide:

```powershell
$subscriptionId = '<subscription-id>'
$resourceGroup = '<resource-group>'
az account set --subscription $subscriptionId
```

## Portal deployment

The Deploy to Azure button creates the Azure resources selected in the portal wizard. It does not publish the sample application or configure the Kubernetes demo workloads.

### Required

Run the Cloud Shell wrapper after the portal deployment succeeds:

```powershell
git clone https://github.com/claestom/azure-monitor-lab.git
cd azure-monitor-lab
./scripts/post-cloud-shell-deploy.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroup $resourceGroup
```

The wrapper:

- Publishes the .NET sample to App Service.
- Automatically configures console operator sign-in, health access, the six-operation Azure job runner, and available optional agent integrations.
- Applies the AKS frontend, load generator, and OpenTelemetry workloads.
- Creates the hourly summary rule.
- Creates the Service Group and its resource-group membership.
- Uses the Health Model deployed by the portal template and verifies the SLI identity prerequisites.
- Verifies that the Managed Prometheus source metrics for the SLI examples are flowing.

### Conditional

- **AI stage enabled:** the workload wrapper already prepares the console's demo agents. Run `./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup` only when generating optional scenario traffic. The models are billable.
- **SRE Agent stage enabled:** run `./scripts/setup-sre-agent.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup`. Then complete the portal authoring steps under [SRE Agent](#sre-agent).
- **AI or SRE Agent stage disabled:** skip its setup. The corresponding scenarios are not available until that stage is enabled and deployed.

Continue with [Manual scenario setup](#manual-scenario-setup).

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

Background traffic runs in a separate Python process on the deployment machine, not in the Web App or an Azure job. The process receives a snapshot of the agent IDs and inherits the configured environment without putting credentials on its command line. Each invocation starts a new finite batch, so avoid overlapping runs unless intended. Model usage remains billable and telemetry can take a few minutes to appear.

The output includes the worker PID and its log/status paths. Files are outside the repository, under `%LOCALAPPDATA%/azure-monitor-lab/ai-traffic` on Windows or `$XDG_STATE_HOME/azure-monitor-lab/ai-traffic` on Linux (default `~/.local/state`). The status records `running`, `completed`, `completed_with_errors`, or `failed`; `running` acknowledges startup, not successful model responses. Use the printed log to inspect progress and the PID to inspect or stop the process. If the process is forcibly stopped, its last status may remain `running`.

Keep the deployment machine and its Azure CLI sign-in available until the batch ends. A suspended laptop, expired sign-in, Cloud Shell session termination, or CI runner shutdown can interrupt traffic; there is no automatic restart. Startup failures or a missing acknowledgment after 30 seconds produce a warning instead of claiming traffic started. Standalone `setup-ai.ps1` still runs traffic in the foreground unless `-BackgroundTraffic` is supplied; `-SkipTraffic` still prepares agents only.

Required console setup failures stop deployment. A later warning about optional AI traffic does not mean agent provisioning was skipped. To generate that scenario telemetry later:

```powershell
./scripts/setup-ai.ps1 -ResourceGroup $resourceGroup
```

If SRE Agent was enabled, the deploy script already completed Steps 1 through 3 of the SRE Agent setup. Skip those steps and continue with [Step 4 - Verify Azure Monitor](STAGE-SRE-AGENT.md#4-verify-azure-monitor) before creating the custom investigators and response plans.

Otherwise, continue with [Manual scenario setup](#manual-scenario-setup).

## Staged deployment

A staged deployment contains only the stages enabled in `lab.config.json` or `terraform/stages.tfvars`. Complete the instructions in the relevant staged guide before running follow-up scripts:

- [Bicep staged deployment](DEPLOY-BICEP-STEP-BY-STEP.md)
- [Terraform staged deployment](DEPLOY-TERRAFORM-STEP-BY-STEP.md)

### Completion After Stage B

Terraform runs the staged wrapper automatically as part of `apply` with Stage B enabled. Do not run it again after a successful apply. Raw Bicep stage deployments remain infrastructure-only; use their normal workload completion wrapper:

```powershell
./scripts/post-staged-deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
```

The wrapper publishes the application, initializes all baseline console dependencies and selected agent access, configures AKS workloads, and creates the summary rule and Service Group. It verifies SLI prerequisites only when the Stage E identity is present. Stage B therefore does not require optional Stage E resources. It also validates SRE Agent when selected in the central config.

### Conditional

- **Stage AI enabled:** the console bootstrap prepares the agents automatically. Run `./scripts/setup-ai.ps1 -ResourceGroup $resourceGroup` only for optional scenario traffic, or for an AI-only lab with no Stage B/Web App.
- **Stage SRE Agent enabled:** if the staged wrapper did not validate it, run `./scripts/setup-sre-agent.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup`. Then complete [SRE Agent](#sre-agent).
- **Stage E enabled after the wrapper ran:** run `./scripts/setup-slis.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup` to verify the newly deployed SLI identity, permissions, and source metrics.
- **Stage E disabled:** Health Model, SLI, Sentinel, and the other optional advanced resources from that stage are unavailable. Skip their follow-up steps.
- **Earlier stage disabled:** skip scenarios that depend on resources from that stage.

Continue with [Manual scenario setup](#manual-scenario-setup).

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