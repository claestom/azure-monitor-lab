# SRE MCP Assistant

The web tab behaves as an MCP host: a configured Foundry model interprets natural-language questions, selects a direct MCP management tool, and explains the returned data. The ASP.NET backend calls Azure MCP Server over stdio using `ModelContextProtocol.Core`. The native runtime is pinned to `3.0.0-beta.42`.

No SRE thread, investigation, or autonomous follow-up is created. Chat history is stored only in the app instance. This is not a conversation delegated to the SRE Agent. No new model deployment or hosted agent is provisioned, and the app cannot reuse a developer's VS Code MCP connection.

The model client uses the official OpenAI SDK against the Azure OpenAI `/openai/v1/` endpoint with Entra authentication. Its token-policy constructor is currently marked experimental; the `OPENAI001` acknowledgement is scoped to that constructor. Fake-transport tests verify reasoning-model `max_completion_tokens` serialization and zero retries.

## Supported Operations

| Area | Direct MCP capabilities | Example question |
|---|---|---|
| Agents | List/get resources and tools; create/delete subagents after approval | List the SRE agents in this resource group. |
| Connectors | List/get; create Kusto connectors, test or delete after approval | Create a Kusto connector named prod-logs with this cluster URL and database. |
| Scheduled tasks | List/get; pause/resume/delete after approval | Pause the nightly scheduled task. |
| Incidents | List active incidents and response plans | List active incidents on this agent. |
| Knowledge | List/search memories; add/delete/reindex after approval | Search memories for deployment failures. |
| Skills and prompts | List/get where supported; create/delete after approval | List the available common prompts. |
| Workflows | Generate/validate YAML and produce architecture plans | Generate a workflow for a Kusto query tool. |

The exact available tools are listed in the UI. The server allowlist intentionally excludes all thread tools, investigations, automatic approvals, safety-hook changes, arbitrary MCP connector commands, incident creation, scheduled-task creation, and workflow application. Unsupported operations are not silently mapped to investigations. Resuming an existing scheduled task can trigger future work and requires explicit approval. Connector tests also require approval because they contact the configured destination.

## Enable Hosted Chat

With both AI and SRE stages selected, normal deployment automatically packages MCP, discovers the existing chat model, and configures sign-in and scoped access. There is no separate hosted-chat setup command or enablement flag to set afterward. The AI stage supplies the host model; the SRE stage alone does not.

The [setup-webapp-agent-access.ps1](../../scripts/setup-webapp-agent-access.ps1) helper is called by the deployment bootstrap. It verifies the subscription/tenant, creates or reuses the single-tenant Entra registration, restricts access to approved users, and grants the four roles below. It preserves anonymous demo traffic endpoints. For a targeted administrative repair only, review `-WhatIf` before applying:

```powershell
../../scripts/setup-webapp-agent-access.ps1 `
  -SubscriptionId '<lab-subscription-id>' -TenantId '<lab-tenant-id>' `
  -ResourceGroup '<lab-resource-group>' -WebAppName '<lab-web-app>' `
  -SreAgentName '<sre-agent>' -FoundryAccountName '<foundry-account>' `
  -FoundryProjectName '<foundry-project>' -ModelDeployment '<model-deployment>' `
  -AllowedUserObjectIds @('<operator-object-id>') -WhatIf
```

Normal deployment requires permission to manage the Entra registration and assign Azure roles. The 180-day sign-in credential is transferred in memory to a protected App Service setting, never printed or committed. Its expiry is recorded in `LabConsole__SignInCredentialExpiresAt`; redeployment automatically renews missing, expired, or near-expiry credentials and reuses healthy ones. No scheduled renewal service is installed. Deleting the lab resource group does not delete the tenant registration; review it separately during cleanup.

App Service requests the OpenID Connect hybrid response `code id_token`, so the Entra web registration must enable **ID tokens** (`web.implicitGrantSettings.enableIdTokenIssuance`). This is compatible with confidential-client code redemption; it does not require implicit access tokens. New registrations enable ID tokens and leave implicit access tokens disabled. Rerunning the helper repairs a missing ID-token flag on a compatible existing registration without changing its redirect URIs, access-token policy, or credential. A callback HTTP 401 can result from this mismatch; validate the requested response type as well as the initial sign-in redirect.

1. Deployment configures Entra sign-in and the operator allowlist. Every admitted operator can invoke the backend's scoped SRE permissions; chat ownership does not enforce that user's Azure RBAC. This is a shared-identity lab, not a multi-tenant authorization gateway.
2. The app receives **Reader** and **SRE Agent Administrator** on the selected SRE Agent, **Cognitive Services OpenAI User** on the model account, and **Foundry User** on its project. SRE management is broad within that one agent. The Web UI never grants roles.
3. [prepare-webapp-package.ps1](../../scripts/prepare-webapp-package.ps1) bundles native Linux MCP. The bootstrap selects the unique deployed `gpt-5-mini` host model and configures the verified tenant and resource scope. Ambiguous targets or required setup failures stop deployment.
4. The bootstrap enables chat after access setup succeeds. Packaging alone still leaves it disabled; local development and a plain `dotnet publish` do not provision Azure access.

| Setting | Value |
|---|---|
| `LabConsole__Sre__Enabled` | Set by normal deployment when both required stages exist; unconfigured/local builds default to `false` |
| `LabConsole__Sre__SubscriptionId` | Intended lab subscription GUID, never an implicit CLI default |
| `LabConsole__Sre__TenantId` | Lab tenant GUID |
| `LabConsole__Sre__AgentName` | Existing SRE Agent resource name |
| `LabConsole__ResourceGroup` | Resource group containing the agent |
| `LabConsole__Sre__McpExecutable` | `mcp/azmcp` for the bundled Linux runtime, or an operator-managed absolute native executable path |
| `LabConsole__Sre__ModelEndpoint` | HTTPS Azure OpenAI account root, such as `https://<account>.openai.azure.com/` |
| `LabConsole__Sre__ModelDeployment` | Existing tool-capable deployment name; the lab preview uses `gpt-5-mini` |
| `LabConsole__AllowedPrincipalIds__0` | First approved operator's Entra object ID; add numbered entries for additional approved operators |

The browser receives no credentials or executable paths. Hosted calls pin `ManagedIdentityCredential` and clear the user-assigned client ID. Both agent tabs require the platform's authenticated principal to match `LabConsole:AllowedPrincipalIds`; missing or empty allowlists deny access. The tabs display a Sign In link for unauthenticated users. Do not expose the app behind a proxy that allows forged `X-MS-*` headers. The integration expects the App Service Authentication proxy, not a generic reverse proxy.

## Local Preview

From the webapp directory, install the Windows native runtime outside the source tree and generate configuration:

```powershell
../../scripts/install-sre-mcp.ps1 -Platform win32-x64 -Destination "$env:TEMP/amlab-sre-mcp"
../../scripts/write-webapp-console-config.ps1 `
  -SubscriptionId '<lab-subscription-id>' -ResourceGroup '<lab-resource-group>' `
  -TenantId '<lab-tenant-id>' -SreMcpExecutable "$env:TEMP/amlab-sre-mcp/azmcp.exe" `
  -SreModelEndpoint 'https://<account>.openai.azure.com/' -SreModelDeployment '<deployment-name>' `
  -EnableSreAssistant -OutputPath ./lab-console.json
dotnet run --no-launch-profile --urls http://localhost:5189
```

Use a fresh destination directory for the installer. Existing Azure CLI login, SRE access, and model inference permissions in the intended tenant are required before sending. Local calls require both a loopback connection and a loopback Host header; the credential is pinned to `AzureCliCredential`. Each question requires consent to model usage and read-only MCP calls. Writes require a separate approval of the exact operation. Generating this file replaces its previous configuration; add `-EnableFoundryPlayground` when you also intend to enable the Foundry playground locally. The former `-EnableSreConversation` switch remains an alias, but now also requires model settings and never enables investigations.

The connection check performs MCP initialization and `tools/list` only. It does not verify Azure RBAC or model permissions and incurs no model usage. A connected runtime can still return an authentication or permission error when a question is submitted.

## Native Packaging

The installer requires PowerShell 7, npm, and tar on the packaging machine. It preserves the package license/notices and verifies archive SHA-512 integrity. The pinned Linux runtime adds about 158 MB uncompressed and requires a compatible Linux x64 host. Node.js is not required at app runtime.

For manual packaging, first publish the app, then run the installer with `-Platform linux-x64 -Destination '<publish-directory>/mcp'`, and generate deployment configuration into that publish directory. Set the executable to `mcp/azmcp`. Do not enable chat until authentication and scoped permissions are ready. Do not check native binaries into git.

On Linux, the app copies the bundled runtime into a private temporary directory and sets executable permissions. This accommodates ZIP permission loss and read-only deployment mounts. Temporary files are removed on normal shutdown; an abrupt process termination may leave them for host cleanup. Linux execution must be validated on the target host before enabling chat.

`dotnet publish` excludes local `lab-console.json`, avoiding accidental publication of enabled local settings. The post-deployment helper generates fresh disabled-by-default configuration after publishing. A plain publish without that helper requires explicit configuration through environment settings.

## Boundaries And Recovery

- Only explicitly allowed management tools are exposed. Runtime annotations and model output cannot add capabilities or change the read/write policy. The model cannot override subscription, tenant, resource group, agent, or confirmation flags. The server injects that scope and validates arguments against the MCP JSON Schema before any call.
- Chat handles and write proposals are bound to the authenticated principal. Local browsers use protected HttpOnly, SameSite=Strict session cookies. Chats expire after two idle hours, are capped at 100 per instance and ten questions per chat, and disappear on restart. There are no corresponding remote SRE threads.
- Use a single app instance for this demo. Scale-out requires a distributed ownership store, shared data-protection keys, and distributed limits. Session affinity alone does not preserve state after recycling.
- One active assistant request, six question/approval submissions, and thirty discovery/chat reads per fixed minute per instance. Questions are limited to 4,000 characters and request bodies to 100,000 bytes. Tool arguments and each logged/model-visible tool result are limited to 16,000 characters; large results are explicitly truncated. Model answers are bounded to 24,000 characters.
- A question can make at most three direct read calls and four model calls. Each model call has a 4,096 output-token cap including reasoning tokens. The whole question has a 150-second deadline. The final model call has no tools. Model retries are disabled, and failed MCP operations are not automatically retried by the app. Schema descriptions, prior turns, and results contribute to input-token usage; use model-account budgets and quotas.
- Writes create a frozen tool-and-arguments proposal that expires after five minutes. Only its owner can approve or decline it. The proposal is consumed before execution, and confirmation performs no additional model call. Replayed confirmations are rejected. Invalid, unsupported, or out-of-scope proposals never reach MCP.
- An approved operation has a 60-second deadline. If its response is lost or times out, the state becomes unknown, further questions in that chat are blocked, and the approval cannot be replayed. Check Azure before attempting the action in a new chat. Stop Waiting ends the browser wait, not a guaranteed cancellation of model inference or an already-approved Azure operation. Refresh reads local chat state only; it never repeats an MCP operation.
- The operation log is the execution record; model wording alone is not proof of a change. MCP responses, descriptions, and memory contents are untrusted input to the model. Human review remains necessary, especially for deletion, configuration changes, and resuming schedules.
- `SreMcpOperation` telemetry records successful tool names, read/write classification, and duration, not arguments or results. Model token counts are reported by the service; missing usage stays unavailable. No cost estimate is fabricated. HTTP trace IDs remain available, and all model/tool text is rendered inertly.

## Verification

```powershell
dotnet test ../webapp.Tests/AmlabHello.Tests.csproj -c Release
npm test
./tests/console-config.Tests.ps1
./tests/webapp-package.Tests.ps1
./tests/webapp-access.Tests.ps1
```

Playwright forces both integrations off for its own server and mocks successful chat responses. Unit tests use fake model and MCP adapters for scope validation, ownership, one-time approval, refusal of investigation tools, bounded reads, cancellation, and unknown write outcomes. Model SDK tests use a fake HTTP transport to check token limits, tool serialization, and disabled retries. These tests create no paid traffic or Azure mutations. Native runtime discovery is a separate `GET /api/sre/availability` check; live model inference, MCP operations, and hosted permissions need validation in the intended environment.

See the [Azure SRE Agent MCP documentation](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-server) for current preview behavior and role requirements.