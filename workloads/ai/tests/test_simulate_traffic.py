import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class SimulatorStartupTests(unittest.TestCase):
    def setUp(self):
        modules = {
            name: ModuleType(name)
            for name in (
                "azure", "azure.ai", "azure.ai.agents", "azure.identity",
                "openai", "opentelemetry", "create_agents", "dotenv",
            )
        }
        self.client = Mock()
        self.client.__enter__ = Mock(return_value=self.client)
        self.client.__exit__ = Mock(return_value=False)
        modules["azure.ai.agents"].AgentsClient = Mock(
            return_value=self.client
        )
        modules["azure.identity"].DefaultAzureCredential = Mock()
        modules["azure.identity"].get_bearer_token_provider = Mock()
        modules["openai"].AzureOpenAI = Mock()
        span = Mock()
        span.__enter__ = Mock(return_value=span)
        span.__exit__ = Mock(return_value=False)
        modules["opentelemetry"].trace = Mock()
        tracer = modules["opentelemetry"].trace.get_tracer.return_value
        tracer.start_as_current_span.return_value = span
        modules["create_agents"].CACHING_SYSTEM_PROMPT = "test prompt"
        modules["create_agents"].AGENTS = [
            {"key": "triage", "instructions": "test instructions"}
        ]
        modules["dotenv"].load_dotenv = Mock()
        source = Path(__file__).resolve().parents[1] / "simulate_traffic.py"
        spec = importlib.util.spec_from_file_location(
            "traffic_simulator", source
        )
        self.simulator = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules):
            spec.loader.exec_module(self.simulator)

    def test_snapshot_and_acknowledgment_precede_first_run(self):
        started = Mock()

        def run(**arguments):
            started.assert_called_once_with()
            self.assertEqual("snapshot-agent", arguments["agent_id"])
            return SimpleNamespace(
                usage=SimpleNamespace(prompt_tokens=12, completion_tokens=3),
                model="test-model",
            )

        self.client.create_thread_and_process_run.side_effect = run
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "agents.json"
            snapshot.write_text(
                json.dumps({
                    "triage": {"id": "snapshot-agent", "name": "Test Agent"}
                }),
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {
                    "AZURE_AI_PROJECT_ENDPOINT": (
                        "https://example.services.ai.azure.com"
                        "/api/projects/test"
                    ),
                }),
                patch.object(self.simulator, "setup_tracing"),
                patch.object(
                    self.simulator.random, "choice",
                    side_effect=lambda values: values[0],
                ),
                patch.object(self.simulator.time, "sleep"),
                patch("builtins.print"),
            ):
                totals = self.simulator.main(
                    [
                        "--conversations", "1", "--max-turns", "1",
                        "--agents-file", str(snapshot),
                    ],
                    on_started=started,
                )
        self.assertEqual({"prompt": 12, "completion": 3, "runs": 1}, totals)
        self.client.create_thread_and_process_run.assert_called_once()

    def test_missing_snapshot_never_acknowledges_startup(self):
        started = Mock()
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict(os.environ, {
                "AZURE_AI_PROJECT_ENDPOINT": (
                    "https://example.services.ai.azure.com/api/projects/test"
                ),
            }),
            self.assertRaises(SystemExit),
        ):
            self.simulator.main(
                ["--agents-file", str(Path(directory) / "missing.json")],
                on_started=started,
            )
        started.assert_not_called()
        self.client.create_thread_and_process_run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
