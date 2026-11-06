#!/usr/bin/env python3
"""Deterministic staged CLI audit. Never starts BuildrAI or installs hooks."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from staged_report_checks import verify_report


def verify(binary, source):
    checks = []

    def run(name, args, expected=0, json_output=True):
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=10)
        if result.returncode != expected:
            raise RuntimeError(f"{name}: exit {result.returncode}, expected {expected}: {result.stderr}")
        assert "SENSITIVE_SENTINEL" not in result.stdout + result.stderr
        assert "DecodingError" not in result.stderr
        value = json.loads(result.stdout) if json_output else result.stdout
        checks.append({"name": name, "exitStatus": result.returncode})
        return value

    version = run("version", ["--version"], json_output=False).strip()
    assert version == (source / "VERSION").read_text().strip()
    capabilities = run("capabilities", ["capabilities", "--json"])
    assert capabilities["version"] == 1  # Capability schema version; CLI version comes from --version.
    bridge = capabilities["reportingTracking"]
    assert bridge["protocolVersions"] == [1] and bridge["contractRevision"] == "1.0.0"
    operations = ["discover", "resolve", "prepare", "finalize", "cancel",
                  "recordCommit", "recordRewrite", "acknowledge"]
    assert bridge["implementedOperations"] == operations
    for operation in operations:
        ready = run(operation + "-ready", ["capabilities", "--json", "--protocol-version", "1",
                                         "--operation", operation])
        assert ready["status"] == "ready"
    assert run("incompatible", ["capabilities", "--json", "--protocol-version", "2",
                               "--operation", "discover"], 30)["status"] == "incompatible"
    assert run("unsupported", ["capabilities", "--json", "--protocol-version", "1",
                              "--operation", "future"], 31)["status"] == "unsupported"
    for command, subcommands in [("report", ["discover", "resolve", "prepare", "finalize", "cancel"]),
                                 ("tracking", ["record-commit", "record-rewrite", "replay", "acknowledge"])]:
        help_text = run(command + "-help", [command, "--help"], json_output=False)
        assert all(command_name in help_text for command_name in subcommands)
    bundles = ["BuildrHooksCLI_BuildrHooksCLI.bundle", "BuildrHooksCLI_BuildrBridgeContracts.bundle"]
    assert all((binary.parent / bundle).is_dir() for bundle in bundles)
    fixtures = binary.parent / bundles[1] / "Contents/Resources/Fixtures"
    assert len(list(fixtures.glob("*.json"))) == 55

    with tempfile.TemporaryDirectory(prefix="buildr-distribution-", dir=source / ".build") as temporary:
        root = Path(temporary)  # Keep the audited checkout spelling used by Foundation.
        scope = {"repository": {"host": "github.com", "owner": "example", "name": "project"},
                 "projectID": "distribution-smoke", "rootPath": str(root)}

        def write(name, value):
            path = root / name
            path.write_text(json.dumps(value))
            return str(path)

        scope_path = write("scope.json", scope)
        tracking = ["--scope", scope_path]
        assert run("tracking-missing-setup", ["tracking", "replay", *tracking], 33)["status"] == "missingSetup"
        config = root / ".buildrai/tracking/v1"
        config.mkdir(parents=True)
        (config / "config.json").write_text(json.dumps({"version": 1, "scope": scope, "enabled": True}))
        # Synthetic tool completion fixtures; these do not establish real commit creation.
        execution = {"invocationID": "smoke-commit", "session": {"source": "codex", "sessionID": "smoke"},
                     "repository": scope["repository"], "rootPath": str(root),
                     "argv": ["git", "commit", "-m", "fixture"], "exitCode": 0,
                     "headBefore": "a" * 40, "headAfter": "b" * 40}
        completion = write("completion.json", execution)
        queued = run("offline-commit", ["tracking", "record-commit", *tracking, "--execution", completion])
        assert queued["status"] == "queued" and len(queued["records"]) == 1
        rewrite = {"invocationID": "smoke-rewrite", "repository": scope["repository"],
                   "rootPath": str(root), "kind": "rebase",
                   "mappings": [{"original": "a" * 40, "replacement": "c" * 40},
                                {"original": "b" * 40, "replacement": "c" * 40}]}
        rewrite_path = write("rewrite.json", rewrite)
        rewritten = run("offline-rewrite", ["tracking", "record-rewrite", *tracking, "--execution", rewrite_path])
        assert rewritten["status"] == "queued" and len(rewritten["rewrites"][0]["receipt"]["mappings"]) == 2
        replay = run("offline-replay", ["tracking", "replay", *tracking])
        assert len(replay["records"]) == 1 and len(replay["rewrites"]) == 1
        execution["exitCode"] = 1
        failed = run("failed-commit", ["tracking", "record-commit", *tracking,
                                     "--execution", write("failed.json", execution)], 33)
        assert failed["status"] == "invalidInput"
        verify_report(run, root, scope, scope_path, fixtures, write)
        assert len(run("tracking-survives-report-cleanup", ["tracking", "replay", *tracking])["records"]) == 1
        ids = [queued["records"][0]["receipt"]["recordID"], rewritten["rewrites"][0]["receipt"]["recordID"]]
        ack = write("ack.json", {"recordIDs": ids})
        assert run("acknowledge", ["tracking", "acknowledge", *tracking, "--acknowledgement", ack])["status"] == "acknowledged"
        replay = run("acknowledged-replay", ["tracking", "replay", *tracking])
        assert not replay["records"] and not replay["rewrites"]
    return {"binary": str(binary), "version": version, "contractRevision": "1.0.0",
            "checks": checks, "passed": len(checks),
            "limitations": ["No real app/agent/GitHub, install/update or release acceptance.",
                             "Report responder fixtures and explicit launch controls do not establish real app launch or source collection."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    result = verify(args.binary.resolve(), source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Staged bridge: {result['passed']} checks passed; evidence: {args.output}")
