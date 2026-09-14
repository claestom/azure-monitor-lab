import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import ModuleType
import unittest
from unittest.mock import Mock, patch


SOURCE = Path(__file__).resolve().parents[1] / "background_traffic.py"
SPEC = importlib.util.spec_from_file_location("background_traffic", SOURCE)
background = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(background)


class BackgroundTrafficTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ai traffic test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.agents = {"triage": {"id": "test-agent", "name": "Test Agent"}}
        (self.root / "agents.json").write_text(
            json.dumps(self.agents), encoding="utf-8"
        )
        self.environment = patch.dict(os.environ, {
            "AZURE_AI_PROJECT_ENDPOINT": (
                "https://example.services.ai.azure.com/api/projects/test"
            ),
            "APPLICATIONINSIGHTS_CONNECTION_STRING": "private-telemetry-value",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_launch_detaches_and_returns_without_waiting_for_batch(self):
        process = Mock(pid=4321)
        process.poll.return_value = None

        def start(command, **options):
            directory = Path(command[-1])
            request = json.loads((directory / "run.json").read_text())
            self.assertEqual(150, request["conversations"])
            self.assertEqual(
                self.agents,
                json.loads((directory / "agents.json").read_text()),
            )
            self.assertNotIn("private-telemetry-value", " ".join(command))
            self.assertEqual(
                "private-telemetry-value",
                options["env"]["APPLICATIONINSIGHTS_CONNECTION_STRING"],
            )
            self.assertEqual(subprocess.DEVNULL, options["stdin"])
            self.assertEqual(subprocess.STDOUT, options["stderr"])
            self.assertTrue(options["close_fds"])
            if os.name == "nt":
                self.assertEqual(
                    subprocess.DETACHED_PROCESS
                    | subprocess.CREATE_NEW_PROCESS_GROUP,
                    options["creationflags"],
                )
            else:
                self.assertTrue(options["start_new_session"])
            background.write_status(
                directory, "running", processId=process.pid
            )
            return process

        with patch.object(
            background.subprocess, "Popen", side_effect=start
        ) as spawn:
            result = background.launch(150, self.root, self.root / "state")
        self.assertEqual(4321, result["processId"])
        self.assertEqual("running", result["state"])
        self.assertTrue(Path(result["logPath"]).exists())
        self.assertNotIn("private-telemetry-value", json.dumps(result))
        self.assertEqual(1, spawn.call_count)
        process.wait.assert_not_called()
        process.terminate.assert_not_called()
        (self.root / "agents.json").write_text("{}", encoding="utf-8")
        snapshot = Path(result["statusPath"]).with_name("agents.json")
        self.assertEqual(self.agents, json.loads(snapshot.read_text()))

    def test_startup_failure_does_not_report_running(self):
        process = Mock(pid=4321)
        process.poll.return_value = 1

        def start(command, **options):
            background.write_status(
                Path(command[-1]), "failed", errorType="ImportError"
            )
            return process

        with (
            patch.object(background.subprocess, "Popen", side_effect=start),
            self.assertRaisesRegex(RuntimeError, "startup failed"),
        ):
            background.launch(150, self.root, self.root / "state")
        process.terminate.assert_not_called()

    def test_status_replace_recovers_from_a_sharing_conflict(self):
        replace = Path.replace
        attempts = 0

        def sharing_conflict(source, target):
            nonlocal attempts
            attempts += 1
            if attempts < 3:
                raise PermissionError("Test file-sharing conflict.")
            return replace(source, target)

        with (
            patch.object(Path, "replace", sharing_conflict),
            patch.object(background.time, "sleep") as delay,
        ):
            background.write_status(self.root, "running")
        self.assertEqual(3, attempts)
        self.assertEqual(2, delay.call_count)
        status = json.loads((self.root / "status.json").read_text())
        self.assertEqual("running", status["state"])

    def test_status_replace_failure_is_bounded_and_keeps_old_status(self):
        background.write_status(self.root, "starting")
        with (
            patch.object(
                Path, "replace", side_effect=PermissionError("Test lock.")
            ) as replace,
            patch.object(background.time, "sleep") as delay,
            self.assertRaises(PermissionError),
        ):
            background.write_status(self.root, "running")
        self.assertEqual(20, replace.call_count)
        self.assertEqual(19, delay.call_count)
        status = json.loads((self.root / "status.json").read_text())
        self.assertEqual("starting", status["state"])

    def test_real_worker_continues_after_launcher_returns(self):
        shutil.copyfile(SOURCE, self.root / "background_traffic.py")
        (self.root / "simulate_traffic.py").write_text(
            "import time\n"
            "from pathlib import Path\n"
            "def main(arguments, on_started):\n"
            "    directory = Path(arguments[3]).parent\n"
            "    on_started()\n"
            "    deadline = time.monotonic() + 10\n"
            "    while not (directory / 'release').exists():\n"
            "        if time.monotonic() >= deadline:\n"
            "            raise RuntimeError('Test worker was not released.')\n"
            "        time.sleep(0.01)\n"
            "    return {'runs': 2}\n",
            encoding="utf-8",
        )
        real_popen = subprocess.Popen
        processes = []

        def start(*arguments, **options):
            process = real_popen(*arguments, **options)
            processes.append(process)
            return process

        try:
            with patch.object(
                background.subprocess, "Popen", side_effect=start
            ):
                result = background.launch(
                    2, self.root, self.root / "state", startup_timeout=5
                )
            process = processes[0]
            self.assertIsNone(process.poll())
            self.assertEqual("running", result["state"])
            status_path = Path(result["statusPath"])
            status_path.with_name("release").touch()
            self.assertEqual(0, process.wait(timeout=5))
            status = json.loads(status_path.read_text(encoding="utf-8"))
            self.assertEqual("completed", status["state"])
            self.assertEqual(2, status["conversations"])
            self.assertEqual(2, status["successfulRuns"])
        except RuntimeError:
            logs = [
                path.read_text(encoding="utf-8", errors="replace")
                for path in self.root.glob("state/run-*/traffic.log")
            ]
            self.fail("Fake worker startup failed:\n" + "\n".join(logs))
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_startup_timeout_stops_only_the_new_worker(self):
        process = Mock(pid=4321)
        process.poll.return_value = None
        with (
            patch.object(background.subprocess, "Popen", return_value=process),
            self.assertRaisesRegex(RuntimeError, "acknowledge startup"),
        ):
            background.launch(
                150, self.root, self.root / "state", startup_timeout=0
            )
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)
        process.kill.assert_not_called()

    def test_invalid_input_does_not_start_a_process(self):
        with patch.object(background.subprocess, "Popen") as spawn:
            with self.assertRaises(ValueError):
                background.launch(0, self.root)
            with (
                patch.dict(os.environ, {"AZURE_AI_PROJECT_ENDPOINT": ""}),
                self.assertRaises(ValueError),
            ):
                background.launch(150, self.root)
            spawn.assert_not_called()

    def test_worker_records_startup_and_finite_batch_outcome(self):
        for totals, expected_state, exit_code in (
            ({"runs": 2}, "completed", 0),
            ({"runs": 2, "errors": 1}, "completed_with_errors", 0),
            ({"runs": 0, "errors": 1}, "failed", 1),
        ):
            with self.subTest(state=expected_state):
                (self.root / "run.json").write_text(
                    json.dumps({"conversations": 150}), encoding="utf-8"
                )
                simulator = ModuleType("simulate_traffic")

                def simulate(arguments, on_started):
                    self.assertEqual(
                        [
                            "--conversations", "150", "--agents-file",
                            str(self.root / "agents.json"),
                        ],
                        arguments,
                    )
                    on_started()
                    status_path = self.root / "status.json"
                    self.assertEqual(
                        "running", json.loads(status_path.read_text())["state"]
                    )
                    return totals

                simulator.main = simulate
                with patch.dict(sys.modules, {"simulate_traffic": simulator}):
                    self.assertEqual(
                        exit_code, background.run_worker(self.root)
                    )
                status_path = self.root / "status.json"
                self.assertEqual(
                    expected_state,
                    json.loads(status_path.read_text())["state"],
                )

    def test_worker_failure_records_only_exception_type(self):
        (self.root / "run.json").write_text(
            json.dumps({"conversations": 150}), encoding="utf-8"
        )
        simulator = ModuleType("simulate_traffic")
        simulator.main = Mock(
            side_effect=RuntimeError("private-upstream-detail")
        )
        with (
            patch.dict(sys.modules, {"simulate_traffic": simulator}),
            patch("builtins.print"),
        ):
            self.assertEqual(1, background.run_worker(self.root))
        status = (self.root / "status.json").read_text()
        self.assertNotIn("private-upstream-detail", status)
        self.assertEqual("failed", json.loads(status)["state"])


if __name__ == "__main__":
    unittest.main()
