"""Contract-compatible local responder checks for the staged public executable."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json
import time
import uuid


def verify_report(run, root, scope, scope_path, fixtures, write):
    requests = root / ".buildrai/reporting/v1/requests"
    handled = set()
    options = ["--scope", scope_path, "--timeout", "2", "--no-launch"]

    def omit_nulls(value):
        # Swift's typed optional fields encode as absent; fixture JSON may use null.
        if isinstance(value, dict):
            return {key: omit_nulls(item) for key, item in value.items() if item is not None}
        if isinstance(value, list):
            return [omit_nulls(item) for item in value]
        return value

    def shared(name):
        return omit_nulls(json.loads((fixtures / (name + ".json")).read_text()))

    def exchange(name, operation, arguments, reply, expected=0):
        # Only the process boundary is injected; the executable owns real transport,
        # validation, packet retention, deadlines and cleanup.
        with ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(run, name, ["report", operation, *options, *arguments], expected)
            deadline = time.monotonic() + 8
            while not pending.done() and time.monotonic() < deadline:
                for path in requests.glob("*/request.json"):
                    request = json.loads(path.read_text())
                    identifier = request["requestID"]
                    if identifier in handled:
                        continue
                    handled.add(identifier)
                    assert request["scope"] == scope
                    assert operation in request["body"]
                    response = {"version": 1, "requestID": identifier,
                                "scope": scope, "body": reply(request)}
                    temporary = path.parent / "response.pending"
                    temporary.write_text(json.dumps(response))
                    temporary.replace(path.parent / "response.json")
                time.sleep(0.01)
            return pending.result(timeout=2)

    preparation = shared("prepare-partial")["request"]["body"]["prepare"]["_0"]
    target = preparation["target"]
    target_path = write("target.json", target)
    discovery = shared("discover-success")["response"]["body"]
    discovered = exchange("report-discover", "discover", ["--target", target_path], lambda _: discovery)
    assert discovered["body"] == discovery
    resolution = {"resolved": {"_0": {"query": "session-1", "choices":
                  discovery["discovered"]["_0"]["candidates"]}}}
    resolved = exchange("report-resolve", "resolve", ["--query", "session-1"], lambda _: resolution)
    assert resolved["body"] == resolution

    preparation_path = write("preparation.json", preparation)

    def prepare(request):
        assert request["body"]["prepare"]["_0"] == preparation
        packet = deepcopy(shared("prepare-partial")["response"]["body"]["prepared"]["_0"])
        packet["snapshot"].update(scope=scope, requestID=request["requestID"],
                                  capturedAt=request["createdAt"])
        return {"prepared": {"_0": packet}}

    prepared = exchange("report-prepare", "prepare", ["--preparation", preparation_path], prepare)
    packet = prepared["body"]["prepared"]["_0"]
    snapshot = packet["snapshot"]
    assert packet["rollupMetrics"]["inputTokens"] == {"unavailable": {"_0": "not reported"}}
    assert packet["rollupMetrics"]["outputTokens"] == {"available": {"_0": 0}}
    generated = shared("finalize-success")["request"]["body"]["finalize"]["_0"]
    generated["snapshot"] = snapshot
    generated_path = write("generated.json", generated)
    markdown = "# App report\r\n\r\nRésumé 🛠  \n<!-- exact -->\n"

    def finalize(request):
        assert request["body"]["finalize"]["_0"] == generated
        assert request["requestID"] != snapshot["requestID"]
        return {"finalized": {"_0": {"snapshot": snapshot, "markdown": markdown}}}

    finalized = exchange("report-finalize", "finalize", ["--generated", generated_path], finalize)
    report = finalized["body"]["finalized"]["_0"]
    assert report["markdown"].encode("utf-8") == markdown.encode("utf-8")
    assert report["snapshot"] == snapshot
    assert not (requests / snapshot["requestID"]).exists()

    # Cancellation uses a genuinely prepared workflow, rather than seeded internal files.
    prepared = exchange("report-prepare-to-cancel", "prepare", ["--preparation", preparation_path], prepare)
    identifier = prepared["requestID"]
    cancelled = run("report-cancel", ["report", "cancel", "--scope", scope_path, "--request", identifier])
    assert cancelled["body"]["cancelled"]["_0"]["targetRequestID"] == identifier
    assert not (requests / identifier).exists()
    ended = run("report-ended-workflow", ["report", "cancel", "--scope", scope_path, "--request", identifier], 32)
    assert ended["body"]["error"]["_0"]["code"] == "invalidInput"

    unavailable = run("report-missing-app", ["report", "discover", "--scope", scope_path,
                      "--target", target_path, "--app-bundle-identifier",
                      "app.buildrhooks.staged.missing." + uuid.uuid4().hex], 32)
    assert unavailable["body"]["error"]["_0"]["code"] == "appUnavailable"
    for code in ["missingSetup", "missingAccess"]:
        failure = {"error": {"_0": {"code": code, "action": "Configure the fixture project."}}}
        result = exchange("report-" + code, "discover", ["--target", target_path], lambda _: failure, 32)
        assert result["body"] == failure
    timeout = run("report-silent-responder", ["report", "discover", "--scope", scope_path,
                  "--target", target_path, "--timeout", "0.1", "--no-launch"], 32)
    assert timeout["body"]["error"]["_0"]["code"] == "timeout"

    malformed = deepcopy(preparation)
    malformed["selection"][0]["source"] = "SENSITIVE_SENTINEL"
    invalid = run("report-malformed-input", ["report", "prepare", *options,
                  "--preparation", write("malformed.json", malformed)], 32)
    assert invalid["body"]["error"]["_0"]["code"] == "invalidInput"
    generated["rollupMetrics"] = {"inputTokens": {"available": {"_0": 999999}}}
    invalid = run("report-replacement-metrics", ["report", "finalize", *options,
                  "--generated", write("metrics.json", generated)], 32)
    assert invalid["body"]["error"]["_0"]["code"] == "invalidInput"
