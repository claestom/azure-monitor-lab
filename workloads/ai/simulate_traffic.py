#!/usr/bin/env python3
"""Simulate traffic against the demo agents to generate token / trace / cost telemetry.

Enables OpenTelemetry tracing to Application Insights so each agent run emits traces,
token usage, and latency — the GenAI signals that light up the Foundry portal's
Observability/Tracing views and land in the lab's Application Insights.

Env:
  AZURE_AI_PROJECT_ENDPOINT              project endpoint
  APPLICATIONINSIGHTS_CONNECTION_STRING  App Insights connection string (enables tracing)
Usage:
  python simulate_traffic.py --conversations 150
"""
import argparse
import json
import os
import random
import sys
import time
from pathlib import Path

from azure.ai.agents import AgentsClient
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AzureOpenAI
from opentelemetry import trace

from create_agents import CACHING_SYSTEM_PROMPT, AGENTS

# Load a local .env (git-ignored) if python-dotenv is available; no-op otherwise.
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).with_name(".env"))
except ImportError:
    pass

tracer = trace.get_tracer("amlab.ai.traffic")

# Per-agent instructions, reused to build cached system prompts.
INSTRUCTIONS = {a["key"]: a["instructions"] for a in AGENTS}

# Personas routed through direct chat-completions with the shared >1024-token
# CACHING_SYSTEM_PROMPT prefix. That identical leading prefix is what the Azure
# OpenAI prompt cache keys on, so all of them report cached tokens; only the
# short task-specific suffix (and the user turn) differs between them.
CACHING_AGENTS = {"caching", "finops", "summarizer"}


def _extract_cached_tokens(usage) -> int:
    """Best-effort read of cached input tokens from a run's usage object.

    The Agents run usage may surface prompt token details (with cached_tokens)
    as an attribute or a dict, depending on SDK version; return 0 if absent.
    """
    for attr in ("prompt_tokens_details", "prompt_token_details"):
        details = getattr(usage, attr, None)
        if details is None and isinstance(usage, dict):
            details = usage.get(attr)
        if details is None:
            continue
        val = getattr(details, "cached_tokens", None)
        if val is None and isinstance(details, dict):
            val = details.get("cached_tokens")
        if val:
            return int(val)
    return 0


def _run_caching_completion(aoai, deployment, user_prompt, extra_instruction=""):
    """Direct chat-completions call for a caching-enabled persona.

    The Foundry Agents run usage does not surface cached tokens, so these
    personas go straight to Azure OpenAI, which returns
    usage.prompt_tokens_details.cached_tokens once the identical >1024-token
    CACHING_SYSTEM_PROMPT prefix warms the prompt cache. Every caching persona
    shares that same leading prefix; only the optional task suffix differs, so
    they all hit the same cache entry.
    Returns (prompt_tokens, completion_tokens, cached_tokens, response_model).
    """
    system = CACHING_SYSTEM_PROMPT if not extra_instruction else (
        CACHING_SYSTEM_PROMPT + "\n\n# Task-specific instructions\n" + extra_instruction)
    resp = aoai.chat.completions.create(
        model=deployment,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_prompt},
        ],
    )
    u = resp.usage
    details = getattr(u, "prompt_tokens_details", None)
    cached = getattr(details, "cached_tokens", 0) if details else 0
    return u.prompt_tokens or 0, u.completion_tokens or 0, cached or 0, resp.model or deployment


def _run_router_completion(aoai, deployment, user_prompt):
    """Call the Model Router deployment; `resp.model` reveals the routed model.

    Model Router picks a cheaper/stronger underlying model per prompt, so the
    response model differs from the requested `model-router` deployment. That
    routed model is emitted as gen_ai.response.model for the distribution tile.
    Returns (prompt_tokens, completion_tokens, cached_tokens, routed_model).
    """
    resp = aoai.chat.completions.create(
        model=deployment,
        messages=[{"role": "user", "content": user_prompt}],
    )
    u = resp.usage
    details = getattr(u, "prompt_tokens_details", None)
    cached = getattr(details, "cached_tokens", 0) if details else 0
    return u.prompt_tokens or 0, u.completion_tokens or 0, cached or 0, resp.model or deployment
PROMPTS = {
    "triage": [
        "My invoice shows a charge I don't recognize.",
        "The app crashes when I upload a file.",
        "I can't reset my password.",
        "How do I export my data?",
        "The dashboard is loading very slowly today.",
    ],
    "finops": [
        "When should I use the Batch API instead of standard deployments?",
        "How do PTUs get billed and when are reservations worth it?",
        "What is prompt caching and how much can it save?",
        "How does the model router reduce cost?",
        "How do I attribute AI cost per team?",
    ],
    "summarizer": [
        "Summarize: Provisioned throughput reserves capacity billed hourly or via reservations.",
        "Summarize: Batch processing offers 50% lower cost with a 24h turnaround for async jobs.",
        "Summarize: Prompt caching discounts repeated long prefixes over 1024 tokens.",
        "Summarize: The model router picks a cheaper model when quality allows.",
    ],
    # Short, varied user messages on top of a large static system prompt -> the
    # long identical prefix caches, so these calls produce cached-input-token hits.
    "caching": [
        "Estimate the monthly cost of 5M input and 1M output tokens on gpt-5-mini.",
        "When is Provisioned Throughput cheaper than pay-as-you-go for us?",
        "How should we attribute AI cost per team?",
        "Which levers cut our token spend fastest?",
        "Give me a chargeback table approach for our three environments.",
        "What guardrails prevent a runaway token spike?",
    ],
    # Prompts of varying difficulty sent to the Model Router deployment; the
    # router picks a cheaper/stronger underlying model per prompt (surfaced as
    # gen_ai.response.model) so the routed-model distribution tile lights up.
    "router": [
        "What is 2 + 2?",
        "What is the capital of France?",
        "Summarize the plot of Hamlet in one sentence.",
        "Write a Python function for the nth Fibonacci number using memoization.",
        "Prove that the square root of 2 is irrational.",
        "Walk through, step by step, how to solve a scrambled Rubik's cube.",
    ],
}


def setup_tracing():
    conn = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if not conn:
        print("No APPLICATIONINSIGHTS_CONNECTION_STRING set — running without tracing export.")
        return
    os.environ.setdefault("AZURE_TRACING_GEN_AI_CONTENT_RECORDING_ENABLED", "true")
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
        configure_azure_monitor(connection_string=conn)
        try:
            from azure.ai.agents.telemetry import AIAgentsInstrumentor
            AIAgentsInstrumentor().instrument()
        except Exception as exc:  # instrumentation is best-effort
            print(f"Agent instrumentation unavailable ({exc}); traces may be limited.")
        print("Tracing to Application Insights enabled.")
    except Exception as exc:
        print(f"Could not enable Azure Monitor tracing: {exc}")


def main(argv=None, on_started=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--conversations", type=int, default=150)
    parser.add_argument("--max-turns", type=int, default=2)
    parser.add_argument(
        "--agents-file", type=Path,
        default=Path(__file__).with_name("agents.json"),
    )
    parser.add_argument("--loop", action="store_true",
                        help="Run continuously, feeding traffic in repeated batches.")
    parser.add_argument("--interval", type=float, default=30,
                        help="Seconds to wait between batches when --loop is set.")
    args = parser.parse_args(argv)
    if args.conversations < 1 or args.max_turns < 1:
        parser.error("Conversation and turn counts must be positive.")

    endpoint = os.environ.get("AZURE_AI_PROJECT_ENDPOINT")
    if not endpoint:
        sys.exit("Set AZURE_AI_PROJECT_ENDPOINT.")
    model = os.environ.get("AZURE_CHAT_DEPLOYMENT", "gpt-5-mini")
    router_deployment = os.environ.get("AZURE_ROUTER_DEPLOYMENT", "model-router")

    agents_file = args.agents_file
    if not agents_file.exists():
        sys.exit("agents.json not found — run create_agents.py first.")
    agents = json.loads(agents_file.read_text(encoding="utf-8"))

    setup_tracing()

    client = AgentsClient(
        endpoint=endpoint,
        credential=DefaultAzureCredential(exclude_managed_identity_credential=True),
    )
    # Direct Azure OpenAI client for the caching persona (see _run_caching_completion).
    aoai = AzureOpenAI(
        azure_endpoint=endpoint.split("/api/projects")[0],
        azure_ad_token_provider=get_bearer_token_provider(
            DefaultAzureCredential(exclude_managed_identity_credential=True),
            "https://cognitiveservices.azure.com/.default",
        ),
        api_version="2024-12-01-preview",
    )
    # 'router' is a synthetic persona (not in agents.json): traffic sent through
    # the Model Router deployment to exercise routed-model + cost monitoring.
    keys = list(agents.keys()) + ["router"]
    totals = {"prompt": 0, "completion": 0, "runs": 0}

    with client:
        if on_started is not None:
            on_started()
        batch = 0
        while True:
            batch += 1
            for i in range(args.conversations):
                key = random.choice(keys)
                is_router = key == "router"
                agent = (agents[key] if not is_router
                         else {"name": "Model Router", "id": router_deployment})
                turns = random.randint(1, args.max_turns)
                for _ in range(turns):
                    prompt = random.choice(PROMPTS.get(key, ["Hello"]))
                    # Wrap each run in a GenAI span so the Foundry observability tiles
                    # (Agent Runs, Models, Token Consumption by Model) get the standard
                    # dimensions the auto-instrumentation doesn't emit here.
                    is_caching = key in CACHING_AGENTS
                    req_model = router_deployment if is_router else model
                    with tracer.start_as_current_span(f"invoke_agent {agent['name']}") as span:
                        span.set_attribute("gen_ai.operation.name", "invoke_agent")
                        span.set_attribute("gen_ai.system",
                                           "az.ai.openai" if (is_caching or is_router) else "az.ai.agents")
                        span.set_attribute("gen_ai.agent.name", agent["name"])
                        span.set_attribute("gen_ai.agent.id", agent["id"])
                        span.set_attribute("gen_ai.request.model", req_model)
                        try:
                            if is_router:
                                pt, ct, cached, resp_model = _run_router_completion(
                                    aoai, router_deployment, prompt)
                            elif is_caching:
                                extra = "" if key == "caching" else INSTRUCTIONS.get(key, "")
                                pt, ct, cached, resp_model = _run_caching_completion(
                                    aoai, model, prompt, extra)
                            else:
                                run = client.create_thread_and_process_run(
                                    agent_id=agent["id"],
                                    thread={"messages": [{"role": "user", "content": prompt}]},
                                )
                                usage = getattr(run, "usage", None)
                                pt = (getattr(usage, "prompt_tokens", 0) or 0) if usage else 0
                                ct = (getattr(usage, "completion_tokens", 0) or 0) if usage else 0
                                cached = _extract_cached_tokens(usage) if usage else 0
                                resp_model = getattr(run, "model", model) or model
                        except Exception as exc:  # survive transient auth/network errors
                            totals["errors"] = totals.get("errors", 0) + 1
                            span.set_attribute("error.type", type(exc).__name__)
                            print(f"run error (skipped): {exc}")
                            continue
                        totals["prompt"] += pt
                        totals["completion"] += ct
                        span.set_attribute("gen_ai.usage.input_tokens", pt)
                        span.set_attribute("gen_ai.usage.output_tokens", ct)
                        if cached:
                            totals["cached"] = totals.get("cached", 0) + cached
                            span.set_attribute("gen_ai.usage.cached_input_tokens", cached)
                        span.set_attribute("gen_ai.response.model", resp_model)
                        totals["runs"] += 1
                if (i + 1) % 10 == 0:
                    print(f"batch {batch} · {i + 1}/{args.conversations} conversations · "
                          f"{totals['runs']} runs · "
                          f"{totals['prompt']}+{totals['completion']} tokens")
                time.sleep(0.2)  # gentle pacing

            if not args.loop:
                break
            print(f"batch {batch} done — sleeping {args.interval}s before next batch "
                  f"(Ctrl+C to stop)...")
            time.sleep(args.interval)

    print("\nDone.")
    print(f"Conversations: {args.conversations} · runs: {totals['runs']}")
    print(f"Tokens — prompt: {totals['prompt']:,} · completion: {totals['completion']:,} · "
          f"total: {totals['prompt'] + totals['completion']:,}")
    if totals.get("cached"):
        print(f"Cached input tokens: {totals['cached']:,}")
    print("Traces/metrics flow to Application Insights (allow a few minutes to appear).")
    return totals


if __name__ == "__main__":
    main()
