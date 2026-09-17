# Stage A — Foundation

> **Goal of this stage:** stand up the observability *substrate* — every workspace, sink, baseline transform, and "starter dashboard" that every other stage depends on. By the end of Stage A the lab has zero workloads, but it has *everything that observes workloads*.
>
> **Maps to scenarios:** 1, 5, 6, 9 (foundation portions).

## 1) What gets created

| Group | Resource(s) | Purpose |
|---|---|---|
| Log Analytics workspaces | `law-amlab-central`, `law-amlab-appinsights` | Two-workspace pattern: one for infra/platform logs, one dedicated to App Insights. Daily cap = 1 GB. Solutions on central: **VMInsights**, **ContainerInsights**. |
| Workspace-based App Insights | `appi-amlab` | Pinned to `law-amlab-appinsights`. Connection string + ikey are used later by App Service and availability tests. |
| Azure Monitor workspace (Prometheus) | `amw-amlab` | The Prometheus-compatible workspace consumed by AKS Managed Prometheus and Managed Grafana in Stage B. |
| Data Collection Endpoint | `dce-amlab` (Linux kind) | Required for DCR-based collection on Linux + AMA. |
| Data Collection Rules | `dcr-amlab-vminsights` (Perf counters + ServiceMap), `dcr-amlab-workspace-transforms` | Inline VM Insights DCR is created here so Stage B VMs can attach to it. Workspace-transforms DCR adds an `AzureActivity` shaping rule. |
| Networking | `vnet-amlab` (with `snet-workload`), `nsg-amlab` | One VNet/subnet shared by all later workloads, plus a baseline NSG. |
| Storage account | `st<amlab><suffix>` | Diagnostic destination, archive target, flow logs target. Diagnostic settings already point at `law-amlab-central`. |
| Event Hub namespace | `evhns-amlab-<suffix>` (+ `diagstream` event hub, `RootManageSharedAccessKey`) | Diagnostic streaming target; later used by App Service diagnostics. |
| Key Vault | `kv-amlab-<suffix>` | Diagnostic settings already routed to `law-amlab-central`. |
| Governance | Policy assignments (diagnostic-settings policies) | Ensures any future resource gets diagnostic settings pointed to the central LAW. |
| Saved queries + KQL functions | Many | Drop the "starter pack" of KQL into the workspace `Queries` pane so demos start with curated assets. |
| Workbooks | Traffic-Lights workbook (display: `wb-amlab-trafficlights`), Cost-of-Monitoring workbook (display: `wb-amlab-cost`) | Two pinned workbooks the customer will see in the next demo step. |

> All resources are tagged `purpose=azure-monitor-lab`, `owner=demo-lab`.

## 2) Speaker notes

Use these one-liners when guiding a customer through Stage A:

1. **"This stage builds the plumbing, not the apps."**
   Nothing is generating telemetry yet. The point is that the *receiving end* is fully ready — workspaces, sinks, DCRs, governance — so when Stage B onboards workloads they immediately light up.

2. **"Two workspaces, on purpose."**
   We separate App Insights from platform telemetry so cost/retention/RBAC can diverge later. This is the pattern most enterprise customers land on.

3. **"DCRs are the new diagnostic settings."**
   Show that the VM Insights DCR (`dcr-amlab-vminsights`) is already in place. Stage B VMs will just *attach*. This is the modern AMA + DCR pattern replacing the MMA pipeline.

4. **"Governance is automatic from day one."**
   Diagnostic-settings policies are assigned right at the foundation — anything you deploy next will be force-monitored.

5. **"Workbooks first, alerts later."**
   The Traffic-Lights workbook is intentionally empty right now. Open it; show "🟢/🟠/🔴" cells with no data. In Stage B those cells light up. This is a powerful "before/after" moment.

6. **"Daily cap = 1 GB."**
   We deliberately cap ingestion so the lab is safe to leave running. Customers nod hard at this.

## 3) Portal walkthrough (UI)

Resource group: **`rg-azure-monitor-lab-terraform-test`** in **North Europe** (the App Service tier auto-pins to West Europe).

1. **Resource group overview** — show the resource list, point out the tag column (`owner=demo-lab`). This is the "everything in one box" story.
2. **`law-amlab-central` → Solutions** — show VMInsights and ContainerInsights pre-installed.
3. **`law-amlab-central` → Usage and estimated costs → Daily cap** — show the 1 GB cap.
4. **`law-amlab-central` → Tables → AzureActivity** *(if visible)* — table is shaped by the workspace-transform DCR.
5. **`appi-amlab` → Overview** — explain it's *workspace-based* (no separate ingestion).
6. **`amw-amlab` → Overview** — call out "this is the Prometheus side; AKS will write here in Stage B."
7. **Monitor → Workbooks → Browse** — open `wb-amlab-trafficlights` and `wb-amlab-cost`. They render empty/sparse right now. Promise the customer this is the "before" picture.
8. **Monitor → Data Collection Rules** — open `dcr-amlab-vminsights`, click *Resources*. Empty list. "Stage B fills this."
9. **Policy → Assignments** — show the diagnostic-settings policy assignments scoped at this RG.

## 4) CLI validation

```powershell
$sub = '<your-subscription-id>'
$rg  = 'rg-azure-monitor-lab-terraform-test'
az account set --subscription $sub

# Resource inventory
az resource list -g $rg --query "[].{name:name,type:type}" -o table

# Central workspace + customer ID (used later for cross-workspace KQL)
az monitor log-analytics workspace show -g $rg -n law-amlab-central --query "{name:name,customerId:customerId,retentionInDays:retentionInDays}" -o table

# App Insights connection string (drives Stage B's App Service auto-instrumentation)
az monitor app-insights component show -g $rg -a appi-amlab --query "{name:name,connectionString:connectionString}" -o table

# AMW exists
az monitor account show -g $rg -n amw-amlab --query "{name:name,defaultIngestionSettings:defaultIngestionSettings}" -o table

# VM Insights DCR is ready and currently has no associations
az monitor data-collection rule show -g $rg -n dcr-amlab-vminsights --query "name" -o tsv
az monitor data-collection rule association list --rule-name dcr-amlab-vminsights -g $rg -o table

# Workbooks exist
az resource list -g $rg --resource-type "Microsoft.Insights/workbooks" --query "[].{name:name,displayName:tags.\"hidden-title\"}" -o table

# Daily cap and saved queries
az monitor log-analytics workspace show -g $rg -n law-amlab-central --query "workspaceCapping" -o json
az monitor log-analytics saved-search list -g $rg --workspace-name law-amlab-central --query "[].{name:name,category:category}" -o table
```

## 5) Done-when

1. `az resource list` shows all resources in the table above.
2. Both workbooks render in the portal (even if empty).
3. `dcr-amlab-vminsights` exists with zero associations.
4. Diagnostic-settings policy assignments are visible at the RG scope.
5. The Traffic-Lights workbook is the obvious "we have nothing to look at *yet*" moment — perfect runway into Stage B.
