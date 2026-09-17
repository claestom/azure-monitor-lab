// ---------------------------------------------------------------------------------
// Security operations workbook
//
// Single, opinionated security pane-of-glass for Azure Monitor Lab.
// Pulls from:
//   * AzureActivity        - control-plane CRUD, privilege escalation, lifecycle
//   * SigninLogs            - identity / Entra sign-ins (best-effort, with fallback)
//   * NTANetAnalytics       - VNet Flow Logs + Traffic Analytics (modern table)
//   * AzureDiagnostics      - Key Vault data-plane reads, Storage transactions
//
// Sections (top to bottom):
//   1. 24h headline tiles  -- one row of big numbers
//   2. Identity & sign-ins -- SigninLogs trend + top failure reasons + fallback note
//   3. Control-plane CRUD  -- top operations / callers / write+delete timeline
//   4. Privilege escalation- RBAC + elevateAccess operations
//   5. Networking & exfil  -- top egress destinations, denied flows, malicious hits
//   6. Lifecycle churn     -- creates/deletes by resource provider over time
//   7. Sensitive data-plane- Key Vault secret reads, Storage operations
//   8. Linked alerts       -- pointers to scenarios 47/48/49 security alerts
//
// NOTE on NTANetAnalytics columns: the correct byte columns are BytesSrcToDest
// and BytesDestToSrc (NOT SrcToDestBytes / DestToSrcBytes). Always filter to
// SubType == 'FlowLog' to exclude StatusMessage rows.
// ---------------------------------------------------------------------------------

@description('Workbook resource name (GUID).')
param name string

@description('Region for the workbook resource.')
param location string

@description('Central Log Analytics workspace resource ID (sourceId for the workbook).')
param centralLawId string

@description('Resource tags.')
param tags object = {}

// ----- KQL queries (each as its own var, kept readable) ---------------------------

// Headline tiles - 24h totals as a single row
var tilesQuery = '''
let activity = AzureActivity | where TimeGenerated > ago(24h) | where ActivityStatusValue == "Success";
let writes      = toscalar(activity | where OperationNameValue has_any ("/write","/delete","/action") | summarize count());
let rbac        = toscalar(activity | where OperationNameValue has_any ("roleAssignments/write","roleDefinitions/write","elevateAccess/action") | summarize count());
let kvOps       = toscalar(AzureDiagnostics | where TimeGenerated > ago(24h) | where ResourceType == "VAULTS" | summarize count());
let ntaFlows    = toscalar(NTANetAnalytics | where TimeGenerated > ago(24h) | where SubType == "FlowLog" | summarize count());
let maliciousNw = toscalar(NTANetAnalytics | where TimeGenerated > ago(24h) | where SubType == "FlowLog" | where FlowType == "MaliciousFlow" or AclName has "MaliciousFlow" | summarize count());
let signins     = toscalar(union isfuzzy=true (SigninLogs | where TimeGenerated > ago(24h) | summarize count()), (print SignInsCount = 0 | project Count = SignInsCount) | summarize sum(Count));
print
    ['Control-plane changes (24h)']  = writes,
    ['RBAC / elevation events (24h)']= rbac,
    ['Key Vault ops (24h)']          = kvOps,
    ['Network flows (24h)']          = ntaFlows,
    ['Malicious flow hits (24h)']    = maliciousNw,
    ['Entra sign-ins (24h)']         = signins
'''

// 2 - Identity / sign-ins
var signinsTrendQuery = '''
SigninLogs
| where TimeGenerated > ago(24h)
| summarize Success = countif(ResultType == 0), Failed = countif(ResultType != 0) by bin(TimeGenerated, 1h)
| render timechart
'''

var signinsFailuresQuery = '''
SigninLogs
| where TimeGenerated > ago(24h)
| where ResultType != 0
| summarize Failures = count() by ResultType = tostring(ResultType), Reason = tostring(ResultDescription)
| top 10 by Failures desc
'''

var signinsByLocationQuery = '''
SigninLogs
| where TimeGenerated > ago(24h)
| extend Country = tostring(LocationDetails.countryOrRegion)
| where isnotempty(Country)
| summarize SignIns = count() by Country
| top 10 by SignIns desc
'''

var signinsRiskyQuery = '''
SigninLogs
| where TimeGenerated > ago(7d)
| where RiskLevelDuringSignIn in ("medium","high") or RiskLevelAggregated in ("medium","high") or RiskState != "none"
| project TimeGenerated, UserPrincipalName, AppDisplayName, IPAddress, RiskLevelDuringSignIn, RiskState, ResultDescription
| order by TimeGenerated desc
| take 50
'''

// 3 - Control-plane CRUD
var topOperationsQuery = '''
AzureActivity
| where TimeGenerated > ago(24h)
| where ActivityStatusValue == "Success"
| where OperationNameValue has_any ("/write","/delete","/action")
| summarize Count = count() by OperationName = tostring(OperationNameValue)
| top 15 by Count desc
'''

var topCallersQuery = '''
AzureActivity
| where TimeGenerated > ago(24h)
| where ActivityStatusValue == "Success"
| where OperationNameValue has_any ("/write","/delete","/action")
| summarize Changes = count() by Caller = iif(isempty(Caller), "(system / managed identity)", Caller)
| top 15 by Changes desc
'''

var writeDeleteTimelineQuery = '''
AzureActivity
| where TimeGenerated > ago(24h)
| where ActivityStatusValue == "Success"
| extend Action = case(
    OperationNameValue has "/delete", "Delete",
    OperationNameValue has "/write", "Write",
    OperationNameValue has "/action", "Action",
    "Other")
| where Action != "Other"
| summarize Count = count() by bin(TimeGenerated, 30m), Action
| render timechart
'''

var failedOperationsQuery = '''
AzureActivity
| where TimeGenerated > ago(24h)
| where ActivityStatusValue in ("Failed","Failure")
| where OperationNameValue has_any ("/write","/delete","/action")
| summarize Failures = count(), Operations = make_set(OperationNameValue, 5) by Caller = iif(isempty(Caller), "(system / managed identity)", Caller)
| top 15 by Failures desc
'''

// 4 - Privilege escalation
var privEscQuery = '''
AzureActivity
| where TimeGenerated > ago(7d)
| where OperationNameValue has_any ("roleAssignments/write","roleDefinitions/write","elevateAccess/action")
| project TimeGenerated, Caller, OperationName = tostring(OperationNameValue), Status = ActivityStatusValue, Resource = _ResourceId, CorrelationId
| order by TimeGenerated desc
| take 100
'''

var privEscByCallerQuery = '''
AzureActivity
| where TimeGenerated > ago(7d)
| where OperationNameValue has_any ("roleAssignments/write","roleDefinitions/write","elevateAccess/action")
| summarize Events = count() by Caller = iif(isempty(Caller), "(system / managed identity)", Caller)
| top 10 by Events desc
'''

// 5 - Networking & exfiltration  -- USES BytesSrcToDest / BytesDestToSrc !
var topEgressQuery = '''
NTANetAnalytics
| where TimeGenerated > ago(24h)
| where SubType == "FlowLog"
| where FlowDirection == "O"
| summarize OutboundBytes = sum(BytesSrcToDest), Flows = count() by DestIp
| extend OutboundMB = round(todouble(OutboundBytes) / 1024 / 1024, 2)
| top 15 by OutboundBytes desc
| project DestIp, OutboundMB, Flows
'''

var egressTimelineQuery = '''
NTANetAnalytics
| where TimeGenerated > ago(24h)
| where SubType == "FlowLog"
| where FlowDirection == "O"
| summarize OutboundMB = round(todouble(sum(BytesSrcToDest))/1024/1024, 2) by bin(TimeGenerated, 30m)
| render timechart
'''

var deniedFlowsQuery = '''
NTANetAnalytics
| where TimeGenerated > ago(24h)
| where SubType == "FlowLog"
| where FlowStatus == "D"
| summarize DeniedFlows = count() by SrcIp, DestIp, DestPort = tostring(DestPort), L7Protocol = tostring(L7Protocol)
| top 20 by DeniedFlows desc
'''

var maliciousFlowsQuery = '''
NTANetAnalytics
| where TimeGenerated > ago(7d)
| where SubType == "FlowLog"
| where FlowType == "MaliciousFlow" or AclName has "MaliciousFlow"
| project TimeGenerated, SrcIp, DestIp, DestPort, FlowDirection, FlowStatus, L7Protocol, BytesSrcToDest, AclName
| order by TimeGenerated desc
| take 50
'''

// 6 - Lifecycle churn by resource provider
var lifecycleByProviderQuery = '''
AzureActivity
| where TimeGenerated > ago(7d)
| where ActivityStatusValue == "Success"
| where OperationNameValue has_any ("/write","/delete")
| extend Action = iif(OperationNameValue has "/delete", "Delete", "Write")
| summarize Count = count() by ResourceProvider = tostring(ResourceProviderValue), Action
| top 20 by Count desc
'''

var lifecycleTimelineQuery = '''
AzureActivity
| where TimeGenerated > ago(7d)
| where ActivityStatusValue == "Success"
| where OperationNameValue has_any ("/write","/delete")
| summarize Events = count() by bin(TimeGenerated, 1h), ResourceProvider = tostring(ResourceProviderValue)
| render timechart
'''

// 7 - Sensitive data-plane
var keyVaultOpsQuery = '''
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceType == "VAULTS"
| summarize Count = count() by OperationName, ResultType, identity_claim_upn_s = tostring(identity_claim_upn_s)
| top 25 by Count desc
'''

var keyVaultFailuresQuery = '''
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where ResourceType == "VAULTS"
| where ResultType != "Success"
| project TimeGenerated, Resource, OperationName, ResultType, ResultSignature, identity_claim_upn_s = tostring(identity_claim_upn_s), CallerIPAddress
| order by TimeGenerated desc
| take 50
'''

var storageOpsQuery = '''
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.STORAGE"
| summarize Count = count() by OperationName, statusText_s = tostring(statusText_s)
| top 20 by Count desc
'''

// 8 - Linked alert summary
var linkedAlertsQuery = '''
AlertsManagementResources
| where type == "microsoft.alertsmanagement/alerts"
| extend ruleId = tostring(properties.essentials.alertRule)
| extend ruleName = tostring(split(ruleId, "/")[-1])
| where ruleName has_any (
    "alert-security-control-plane-drift",
    "alert-security-privilege-escalation-watch",
    "alert-security-exfil-early-warning")
| extend Severity = tostring(properties.essentials.severity), State = tostring(properties.essentials.alertState),
         FiredTime = todatetime(properties.essentials.startDateTime)
| project FiredTime, ruleName, Severity, State, MonitorCondition = tostring(properties.essentials.monitorCondition)
| order by FiredTime desc
| take 50
'''

// ----- Workbook content (items array) -------------------------------------------

var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    // === Header ===
    {
      type: 1
      content: {
        json: '## 🛡️ Security operations — single pane of glass\n\nThis workbook surfaces the most useful security telemetry from Azure Monitor Lab:\n\n* **Identity** — Entra sign-ins (success / failure / risky)\n* **Control plane** — Azure Resource Manager CRUD activity, top operations & callers\n* **Privilege escalation** — RBAC role assignments / definitions / elevateAccess\n* **Network** — egress hotspots, denied flows, malicious-flow hits (from VNet Flow Logs + Traffic Analytics)\n* **Lifecycle** — resource churn by provider\n* **Sensitive data plane** — Key Vault secret reads, Storage transactions\n* **Linked alerts** — fires from scenarios 47/48/49\n\n> Time scope defaults to 24h for tiles, 7d for higher-signal panels (privilege escalation, malicious flows). All queries are pinned to the central lab workspace.'
      }
      name: 'header'
    }

    // === 1. Headline tiles ===
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: tilesQuery
        size: 3
        title: 'Last 24 hours — security snapshot'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'tiles'
        tileSettings: {
          showBorder: true
          titleContent: { columnMatch: 'Column1' }
          leftContent: { columnMatch: 'Column2', formatter: 12 }
        }
      }
      name: 'tiles24h'
    }

    // === 2. Identity & sign-ins ===
    {
      type: 1
      content: {
        json: '### 👤 Identity & sign-ins\n\nEntra ID sign-in telemetry. **If the panels below show "No data"**, Entra diagnostic settings are not yet forwarding `SigninLogs` to this workspace — see `scripts/setup-rbac-demo.ps1` and Azure portal → Entra ID → Diagnostic settings → ship `SignInLogs` to `law-amlab-central`.'
      }
      name: 'identityHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: signinsTrendQuery
        size: 1
        title: 'Sign-ins over time (last 24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'timechart'
      }
      name: 'signinsTrend'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: signinsFailuresQuery
        size: 1
        title: 'Top sign-in failure reasons (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'signinsFailures'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: signinsByLocationQuery
        size: 1
        title: 'Sign-ins by country (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'piechart'
      }
      name: 'signinsLocation'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: signinsRiskyQuery
        size: 1
        title: 'Risky sign-ins (last 7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'signinsRisky'
    }

    // === 3. Control-plane CRUD ===
    {
      type: 1
      content: {
        json: '### 🛠️ Control plane — CRUD activity\n\nAll successful `/write`, `/delete`, `/action` operations from `AzureActivity`. Look for: unusual callers, weekend bursts, sudden delete storms (linked alert: `alert-security-control-plane-drift`).'
      }
      name: 'crudHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: writeDeleteTimelineQuery
        size: 1
        title: 'Write / Delete / Action timeline (24h, 30m bins)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'timechart'
      }
      name: 'crudTimeline'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: topOperationsQuery
        size: 1
        title: 'Top 15 operations (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'crudTopOps'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: topCallersQuery
        size: 1
        title: 'Top 15 callers (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'crudTopCallers'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: failedOperationsQuery
        size: 1
        title: 'Failed control-plane operations by caller (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'crudFailures'
    }

    // === 4. Privilege escalation ===
    {
      type: 1
      content: {
        json: '### 🚨 Privilege escalation — RBAC & elevateAccess\n\nHighest-severity panel: any unexpected entry here is potentially an account compromise. Backing alert: `alert-security-privilege-escalation-watch` (severity 1).'
      }
      name: 'privEscHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: privEscByCallerQuery
        size: 1
        title: 'RBAC / elevation events by caller (7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'privEscByCaller'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: privEscQuery
        size: 1
        title: 'Recent RBAC / elevateAccess operations (7d, top 100)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'privEscDetail'
    }

    // === 5. Networking & exfiltration ===
    {
      type: 1
      content: {
        json: '### 🌐 Network — egress & exfiltration\n\nFrom VNet Flow Logs enriched by Traffic Analytics (`NTANetAnalytics`). The exfil early-warning alert fires when 30-min outbound bytes exceed 1 GB — see `alert-security-exfil-early-warning`.\n\n> Uses the modern `NTANetAnalytics` table (the legacy `AzureNetworkAnalytics_CL` from NSG flow logs is being retired Sep-2027).'
      }
      name: 'networkHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: egressTimelineQuery
        size: 1
        title: 'Outbound traffic (MB) over time — 24h'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'timechart'
      }
      name: 'egressTimeline'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: topEgressQuery
        size: 1
        title: 'Top 15 egress destinations (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'topEgress'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: deniedFlowsQuery
        size: 1
        title: 'Denied flows — top 20 (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'deniedFlows'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: maliciousFlowsQuery
        size: 1
        title: 'Malicious-flow hits (Traffic Analytics threat intel, 7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'maliciousFlows'
    }

    // === 6. Lifecycle ===
    {
      type: 1
      content: {
        json: '### 🔄 Lifecycle — resource churn by provider\n\nHow many `write` / `delete` events per resource provider in the last 7 days. Healthy labs see a small steady trickle; a flat line followed by a spike = batch deploy or batch delete (potential blast radius).'
      }
      name: 'lifecycleHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: lifecycleByProviderQuery
        size: 1
        title: 'Top 20 (provider, action) pairs (7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'lifecycleByProvider'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: lifecycleTimelineQuery
        size: 1
        title: 'Resource events by provider over time (7d)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'timechart'
      }
      name: 'lifecycleTimeline'
    }

    // === 7. Sensitive data plane ===
    {
      type: 1
      content: {
        json: '### 🔐 Sensitive data plane — Key Vault & Storage\n\nKey Vault secret/key access and Storage transactions from `AzureDiagnostics`. Spikes in `SecretGet` or `KeyGet` from unusual identities are worth pivoting to a Sentinel hunt.'
      }
      name: 'dataPlaneHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: keyVaultOpsQuery
        size: 1
        title: 'Key Vault operations (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'kvOps'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: keyVaultFailuresQuery
        size: 1
        title: 'Key Vault failures (7d, top 50)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'kvFailures'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: storageOpsQuery
        size: 1
        title: 'Storage operations (24h)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'storageOps'
    }

    // === 8. Linked alerts ===
    {
      type: 1
      content: {
        json: '### 🔔 Linked security alerts\n\nFires from the three security-posture alerts. Empty = quiet lab (good). See `DEMO-SCENARIOS.md` scenarios 47, 48, 49 to trigger each one.\n\n| Alert | Scenario | Severity |\n| --- | --- | --- |\n| `alert-security-control-plane-drift` | 47 | Sev 2 |\n| `alert-security-privilege-escalation-watch` | 48 | Sev 1 |\n| `alert-security-exfil-early-warning` | 49 | Sev 2 |'
      }
      name: 'alertsHeader'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: linkedAlertsQuery
        size: 1
        title: 'Recent fires from security alerts'
        queryType: 1
        resourceType: 'microsoft.resourcegraph/resources'
        crossComponentResources: [ 'value::selected' ]
      }
      name: 'linkedAlerts'
    }
  ]
  fallbackResourceIds: [ centralLawId ]
}

// ----- Workbook resource ---------------------------------------------------------

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: '🛡️ Azure Monitor Lab — Security operations'
    serializedData: string(workbookContent)
    category: 'workbook'
    sourceId: centralLawId
    version: '1.0'
  }
}

output id string = workbook.id
output name string = workbook.name
