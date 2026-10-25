"""Exercise the shipped console sender against an isolated local inbox.

Run with Python 3: tools/console_sender_validation.py --sender windows|sh
Use --shell PATH for a specific POSIX shell (including Git for Windows).
The fake receiver checks published bytes and supplies protocol fixtures; engine
dispatch, rendering, and batch scheduling are covered by the Odin validators.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def entry(command="echo hello", ok=True, lines=None, data=None):
    return {"command": command, "ok": ok, "lines": lines or [], "data": data}


def batch_result(entries, *, requested=None, complete=True, error=""):
    return {
        "ok": complete and all(item["ok"] for item in entries) and not error,
        "complete": complete,
        "requested": len(entries) if requested is None else requested,
        "completed": len(entries),
        "error": error,
        "results": entries,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sender", choices=["windows", "sh"], default="windows" if os.name == "nt" else "sh")
    parser.add_argument("--shell", default="sh")
    options = parser.parse_args()
    if options.sender == "windows" and os.name != "nt":
        parser.error("the Windows sender requires Windows Script Host")
    if options.sender == "sh" and not shutil.which(options.shell):
        parser.error("POSIX shell unavailable; supply --shell PATH")

    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    passed = 0
    with tempfile.TemporaryDirectory(prefix="console-sender-validation-", dir=build) as temporary:
        folder = Path(temporary)
        inbox = folder / "inbox with spaces"
        inbox.mkdir()
        source = folder / "commands with spaces.txt"

        def launch(arguments):
            args = ["--directory", inbox.as_posix(), *arguments]
            environment = os.environ.copy()
            if options.sender == "windows":
                # The unchanged .bat wrapper passes its raw argument text through
                # this environment variable to the built-in JScript interpreter.
                environment["RUNE_CONSOLE_ARGUMENTS"] = " ".join('"' + arg.replace('"', '""') + '"' for arg in args)
                command = ["cscript.exe", "//nologo", "//E:JScript", str(ROOT / "tools" / "console.bat")]
            else:
                command = [options.shell, (ROOT / "tools" / "console.sh").as_posix(), *args]
            return subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def run(name, *, payload=b"echo hello\n", response=None, success=True, batch=True, text=False, extra=(), no_reply=False, claimed=False, expected_output=None, reply_delay=0):
            nonlocal passed
            assert not list(inbox.iterdir()), f"{name}: previous test left inbox files"
            source.write_bytes(payload)
            arguments = ["--batch-file", source.as_posix()] if batch else ["--command", payload.decode("utf-8")]
            if not text:
                arguments.append("--json")
            arguments.extend(extra)
            process = launch(arguments)
            deadline = time.monotonic() + 8
            request = None
            while process.poll() is None and time.monotonic() < deadline:
                requests = list(inbox.glob("*.batch" if batch else "*.cmd"))
                if requests:
                    request = requests[0]
                    assert request.read_bytes() == payload, f"{name}: request bytes changed"
                    if not no_reply or claimed:
                        request.unlink()
                    if not no_reply:
                        if reply_delay:
                            time.sleep(reply_delay)
                        reply = request.with_suffix(".result.json")
                        staged = reply.with_suffix(".tmp")
                        body = response if isinstance(response, bytes) else json.dumps(response, ensure_ascii=True).encode("ascii")
                        staged.write_bytes(body)
                        staged.rename(reply)
                    break
                time.sleep(0.01)
            try:
                stdout, stderr = process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                raise AssertionError(f"{name}: sender did not finish")
            assert request is not None, f"{name}: no request published: {stderr!r}"
            assert (process.returncode == 0) == success, f"{name}: exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}"
            if expected_output is not None:
                assert expected_output in stdout, f"{name}: expected output missing: {stdout!r}"
            elif not text and not no_reply and isinstance(response, dict) and "malformed" not in name:
                assert json.loads(stdout) == response, f"{name}: JSON output differs: {stdout!r}"
            if no_reply:
                assert b"does not cancel" in stderr and b"result.json" in stderr, f"{name}: missing timeout guidance"
            assert not list(inbox.iterdir()), f"{name}: sender did not clean up its files"
            passed += 1

        quoted = 'echo "snowman \u2603 and \\slashes"'
        single = {"ok": True, "lines": [quoted], "data": {"quoted": quoted}}
        run("single JSON quoting and Unicode", payload=quoted.encode("utf-8"), response=single, batch=False)
        batch_payload = ("\ufeff# heading\r\n\r\n" + quoted + "\r\necho second\r\n").encode("utf-8")
        good = batch_result([entry(quoted, lines=[quoted], data={"text": quoted}), entry("echo second", lines=["second"], data=[1, True, None])])
        run("batch BOM CRLF quoting and Unicode", payload=batch_payload, response=good)
        run("batch text output", response=batch_result([entry(lines=["hello"], data={"value": 3})]), text=True, expected_output=b"[1/1] echo hello")
        run("single text output", payload=b"echo hello", response={"ok": True, "lines": ["hello"], "data": {"value": 3}}, batch=False, text=True, expected_output=b"hello")
        run("mixed failures", response=batch_result([entry(), entry("missing", ok=False, lines=["Unknown command: missing"]), entry()]), success=False)
        run("partial quit", response=batch_result([entry("quit")], requested=2, complete=False, error="Engine stopped before batch completed."), success=False)
        run("empty batch", payload=b"# only a comment\n\n", response=batch_result([]))
        run("fatal request error", response=batch_result([], complete=False, error="Batch exceeds 4096 lines."), success=False)
        run("invalid UTF-8 preserved for engine validation", payload=b"echo \xff\n", response=batch_result([], complete=False, error="Batch must be valid UTF-8."), success=False)
        run("batch default exceeds single timeout", response=batch_result([entry()]), reply_delay=11)
        run("malformed old envelope", response=single, success=False)
        wrong_count = batch_result([entry()])
        wrong_count["completed"] = 2
        run("malformed count", response=wrong_count, success=False)
        wrong_success = batch_result([entry(ok=False)])
        wrong_success["ok"] = True
        run("malformed success", response=wrong_success, success=False)
        run("malformed line", response=batch_result([entry(lines=[7])]), success=False)
        missing_data = batch_result([entry()])
        del missing_data["results"][0]["data"]
        run("malformed missing data", response=missing_data, success=False)
        run("malformed JSON", response=b'{"ok":true,', success=False)
        run("unclaimed timeout cleanup", no_reply=True, success=False, extra=["--timeout-seconds", "1"])
        run("claimed timeout guidance", no_reply=True, claimed=True, success=False, extra=["--timeout-seconds", "1"])

        for name, arguments in [
            ("mutually exclusive inputs", ["--batch-file", source.as_posix(), "--command", "echo hello"]),
            ("missing input", []),
            ("missing batch file", ["--batch-file", (folder / "missing.txt").as_posix()]),
            ("invalid timeout", ["--batch-file", source.as_posix(), "--timeout-seconds", "0"]),
            ("empty timeout", ["--batch-file", source.as_posix(), "--timeout-seconds", ""]),
        ]:
            process = launch(arguments)
            stdout, stderr = process.communicate(timeout=8)
            assert process.returncode != 0, f"{name}: accepted invalid arguments"
            assert not list(inbox.iterdir()), f"{name}: published an invalid request"
            passed += 1
        source.write_bytes(b"x" * 1048577)
        process = launch(["--batch-file", source.as_posix()])
        stdout, stderr = process.communicate(timeout=8)
        assert process.returncode != 0 and b"1048576" in stderr and not list(inbox.iterdir()), "oversized input was not rejected before publication"
        passed += 1
    print(f"Console {options.sender} sender validation passed ({passed} cases).")


if __name__ == "__main__":
    main()
