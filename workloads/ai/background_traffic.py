"""Launch one finite AI traffic batch independently of the deployment shell."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def write_status(directory, state, **details):
    status = {
        "state": state,
        "processId": os.getpid(),
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        **details,
    }
    temporary = directory / "status.tmp"
    temporary.write_text(json.dumps(status, indent=2), encoding="utf-8")
    for attempt in range(20):
        try:
            temporary.replace(directory / "status.json")
            break
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.05)
    return status


def state_directory():
    if os.name == "nt":
        base = Path(
            os.environ.get("LOCALAPPDATA")
            or Path.home() / "AppData" / "Local"
        )
    else:
        base = Path(
            os.environ.get("XDG_STATE_HOME")
            or Path.home() / ".local" / "state"
        )
    return base / "azure-monitor-lab" / "ai-traffic"


def launch(conversations, ai_directory, state_root=None, startup_timeout=30):
    if conversations < 1:
        raise ValueError("Conversations must be positive.")
    if not os.environ.get("AZURE_AI_PROJECT_ENDPOINT"):
        raise ValueError("The AI project endpoint is not configured.")
    agents_file = ai_directory / "agents.json"
    agents = json.loads(agents_file.read_text(encoding="utf-8"))
    if not isinstance(agents, dict) or not agents:
        raise ValueError("Prepare the demo agents before starting traffic.")
    root = state_root or state_directory()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = Path(tempfile.mkdtemp(prefix="run-", dir=root))
    (directory / "agents.json").write_text(
        json.dumps(agents), encoding="utf-8"
    )
    (directory / "run.json").write_text(
        json.dumps({"conversations": conversations}), encoding="utf-8"
    )
    log_path = directory / "traffic.log"
    status_path = directory / "status.json"
    environment = os.environ.copy()
    environment["PYTHONUNBUFFERED"] = "1"
    options = (
        {
            "creationflags": (
                subprocess.DETACHED_PROCESS
                | subprocess.CREATE_NEW_PROCESS_GROUP
            )
        }
        if os.name == "nt"
        else {"start_new_session": True}
    )
    with log_path.open("ab", buffering=0) as output:
        process = subprocess.Popen(
            [
                sys.executable, "-u", "-B",
                str(ai_directory / "background_traffic.py"),
                "--worker", str(directory),
            ],
            cwd=ai_directory,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            close_fds=True,
            **options,
        )
    deadline = time.monotonic() + startup_timeout
    try:
        while time.monotonic() < deadline:
            if status_path.exists():
                status = json.loads(status_path.read_text(encoding="utf-8"))
                if status["state"] in (
                    "running", "completed", "completed_with_errors"
                ):
                    return {
                        "processId": process.pid,
                        "state": status["state"],
                        "conversations": conversations,
                        "logPath": str(log_path),
                        "statusPath": str(status_path),
                    }
                if status["state"] == "failed":
                    raise RuntimeError(
                        f"AI traffic startup failed. Check {log_path}."
                    )
            if process.poll() is not None:
                raise RuntimeError(
                    f"AI traffic exited during startup. Check {log_path}."
                )
            time.sleep(0.05)
        raise RuntimeError(
            "AI traffic did not acknowledge startup within "
            f"{startup_timeout} seconds. Check {log_path}."
        )
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        write_status(
            directory, "failed", processId=process.pid,
            error="Startup did not complete.",
        )
        raise


def run_worker(directory):
    try:
        request_file = directory / "run.json"
        request = json.loads(request_file.read_text(encoding="utf-8"))
        conversations = request["conversations"]
        if not isinstance(conversations, int) or conversations < 1:
            raise ValueError("Invalid conversation count.")
        write_status(directory, "starting", conversations=conversations)
        from simulate_traffic import main as simulate

        totals = simulate(
            [
                "--conversations", str(conversations),
                "--agents-file", str(directory / "agents.json"),
            ],
            on_started=lambda: write_status(
                directory, "running", conversations=conversations
            ),
        )
        runs = totals.get("runs", 0)
        errors = totals.get("errors", 0)
        state = (
            "failed" if not runs
            else "completed_with_errors" if errors else "completed"
        )
        write_status(
            directory, state, conversations=conversations,
            successfulRuns=runs, errors=errors,
        )
        return 1 if state == "failed" else 0
    except (Exception, SystemExit) as error:
        write_status(directory, "failed", errorType=type(error).__name__)
        print(
            f"AI traffic failed ({type(error).__name__}).",
            file=sys.stderr, flush=True,
        )
        return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--conversations", type=int, default=150)
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        return run_worker(args.worker)
    try:
        result = launch(args.conversations, Path(__file__).resolve().parent)
    except Exception as error:
        print(
            f"Could not start background AI traffic: {error}", file=sys.stderr
        )
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
