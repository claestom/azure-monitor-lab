# Customer Handout - Stage Rollout Time and Cost

This one-pager helps customers decide how far to go in a workshop or pilot.

## Assumptions

- Region: North Europe (App Service and the default Observability Agent workspace pin to West Europe; optional AI, SRE Agent, and Health Model resources pin to Sweden Central)
- Pricing basis: list price guidance from this lab's README; Observability Agent guidance checked September 26, 2026
- Cost values are directional ranges, not quotes
- Currency conversion: USD estimates use a planning rate of EUR 1 = USD 1.10 and are rounded to whole dollars
- Monthly impact assumes resources are left running 24/7
- Stopping VMs/AKS between demos materially reduces cost

## Stage-by-stage estimate

| Stage | High-level scenario theme | Typical deployment time | Incremental monthly cost impact | Main cost drivers |
|---|---|---|---|---|
| Stage A - Foundation | Telemetry backbone, workspace and policy foundations (scenarios 1, 5, 6, 9 baseline) | 8-15 min | EUR 5-25 / USD 6-28 | Log ingestion, storage transactions, baseline monitor resources |
| Stage B - Workloads and dashboards | VM/AKS/App Service telemetry and dashboards (scenarios 2, 3, 4, 22, 28-32, 34-36, 42) | 20-35 min | EUR 95-145 / USD 105-160 | AKS node(s), two VMs, App Service plan, additional ingestion |
| Stage C - Alerts and response | Alerting, Action Group, auto-mitigation, processing rules (scenarios 7, 8, 12, 15, 17, 19, 23, 37) | 5-12 min | EUR 0-10 / USD 0-11 | Alert evaluations, action executions, extra logs from tests |
| Stage D - Security posture | Monitor-native detections for drift, IAM changes, exfil signals (scenarios 27, 47, 48, 49) | 5-12 min | EUR 0-15 / USD 0-17 | AzureActivity ingestion and scheduled query alerts |
| Stage E - Optional advanced add-ons | Sentinel/reliability/archival extras (scenarios 43, 44, 45, 46) | 10-20 min | EUR 0-40 / USD 0-44 | Sentinel analytics usage, archive/restore/search workloads, preview feature telemetry |
| Stage AI - Optional GenAI workload | Microsoft Foundry account + models (chat/embed/optimize/router), token alerts, AI FinOps observability | 5-10 min + traffic | EUR 5-30 / USD 6-33 | Per-token model usage while the traffic simulator runs (small at capacity 10; stop it to zero it out); minimal idle cost |
| Stage SRE Agent - Optional incident investigation | Azure SRE Agent investigation and Review-mode response workflows (scenarios 54-59) | 5-10 min + portal setup | Variable; check current SRE Agent pricing | Active Agent Unit usage during an eligible 30-day always-on charge waiver; fixed always-on and usage charges after the waiver |
| Stage Observability Agent - Optional autonomous operations | Agentic-application alert correlation and deterministic broken/fixed trace investigations (scenarios 61-67) | 5-10 min + telemetry/investigation time | Variable; `AAC consumed × current regional AAC price`, plus workspace data charges | Dedicated Azure Monitor workspace; chat and deep investigation AAC usage; automatic investigation is off by default and each deep investigation is capped at 500 AAC |

## Cumulative monthly range by stop point

| Stop after stage | Expected monthly range |
|---|---|
| Stage A | EUR 5-25 / USD 6-28 |
| Stage B | EUR 100-170 / USD 110-187 |
| Stage C | EUR 100-180 / USD 110-198 |
| Stage D | EUR 105-195 / USD 116-215 |
| Stage E | EUR 105-235 / USD 116-259 |
| Stage AI (add-on) | + EUR 5-30 / USD 6-33 while traffic runs |
| Stage SRE Agent (add-on) | Variable usage during an eligible 30-day waiver; fixed always-on plus usage pricing afterward |
| Stage Observability Agent (add-on) | Variable AAC and workspace data usage; as checked September 26, 2026, correlation is unbilled in preview, while chat and deep investigations are billable |

## Practical guidance for customer conversations

1. Start with Stage A + B for technical proof of value.
2. Add Stage C when on-call and response workflow are in scope.
3. Add Stage D for security posture outcomes without requiring SIEM.
4. Add Stage E only when customer explicitly wants Sentinel/reliability-preview and accepts extra complexity.
5. Add Stage AI when the customer wants a GenAI/FinOps observability story (token/cost telemetry, model-router, token-spike alerts). It is independent of Stages B-E and only needs Stage A.
6. Add Stage SRE Agent when the customer wants AI-assisted incident investigation and Review-mode response plans. It depends only on Stage A, is hard pinned to Sweden Central, and remains off by default because usage is billable.
7. Add Stage Observability Agent when the customer wants autonomous alert correlation and trace-based troubleshooting for agentic applications. It depends on Stage A; the Control Center scenario runner also needs Stage B.

## Cost optimization notes

1. Stop AKS and deallocate VMs outside workshop windows.
2. Keep LAW caps and table plans under review.
3. Use staged rollout so customers only pay for scenarios they are currently validating.
4. Delete the SRE Agent before day 31 when the evaluation will not continue; stopping it does not stop the fixed always-on charge after the waiver.
5. Keep Observability Agent deep investigations manual unless the customer explicitly accepts automatic Azure Agent Credit consumption.

For a customer quote, multiply actual or planned AAC consumption by the current regional AAC rate and add the dedicated workspace's ingestion, retention, and query charges. Use the current [Observability Agent billing guidance](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-billing) and [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/); do not use the variable row above as a fixed price.
