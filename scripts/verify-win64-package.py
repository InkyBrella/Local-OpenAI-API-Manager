import json
import os
from pathlib import Path
import re
import socket
import subprocess
from tempfile import mkdtemp
import time
import tomllib
from runpy import run_path
from urllib.request import ProxyHandler, Request, build_opener
from zipfile import ZipFile


scripts = Path(__file__).resolve().parent
build = run_path(str(scripts / "build-win64.py"))
root = build["ROOT"]
zip_path = build["OUTPUT_DIR"] / build["ZIP_NAME"]
results = root / ".build" / "test-runs"
results.mkdir(exist_ok=True)
extract_dir = Path(mkdtemp(prefix="发布验证 中文 & [路径]! ", dir=results))
with ZipFile(zip_path) as archive:
    names = archive.namelist()
    prefix = build["PACKAGE"] + "/"
    expected = set(build["FILES"]) | {
        "runtime/win-x64/node.exe", "runtime/NODEJS-LICENSE.txt", "runtime/NODEJS-NOTICE.txt",
    }
    assert len(names) == len(expected) and set(names) == {prefix + item for item in expected}
    readme = archive.read(prefix + "README.md").decode("utf-8")
    for target in re.findall(r"\]\(([^)]+)\)", readme):
        assert prefix + target.split("#", 1)[0] in names, target
    assert archive.testzip() is None
    for name in names:
        assert name.startswith("Local-OpenAI-API-Manager/")
        assert not ({".local", "logs", ".env"} & set(name.split("/")))
        assert "arm64" not in name and not name.endswith(".bak")
        if not name.endswith(".exe"):
            data = archive.read(name)
            assert not re.search(rb"(?i)[a-z]:[/\\]+Users[/\\]|lp-[a-f0-9]{64}|sk-(?:proj-)?[a-z0-9_-]{24,}|gh[pousr]_[a-z0-9]{30,}|BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY", data), name
    archive.extractall(extract_dir)

package = extract_dir / build["PACKAGE"]
system_root = Path(os.environ["SystemRoot"])
ps = system_root / "System32/WindowsPowerShell/v1.0/powershell.exe"
cmd = system_root / "System32/cmd.exe"
env = os.environ.copy()
env["PATH"] = str(system_root / "System32")
env["PSModulePath"] = str(ps.parent / "Modules")
env.pop("OPENAI_API_KEY", None)
env.pop("CODEX_PROXY_KEY", None)
# Keep optional proxy environment settings from altering the smoke test.
for variable in list(env):
    if variable.upper().startswith("LOCAL_PROXY_"):
        env.pop(variable)
node = package / "runtime/win-x64/node.exe"
assert not list(package.glob(".local"))
assert not list(package.glob("logs"))
assert subprocess.check_output([str(node), "--version"], cwd=package, env=env).strip() == build["NODE_VERSION"].encode()


def run_cmd(name, *args):
    return subprocess.run(
        [str(cmd), "/d", "/v:on", "/c", name, *args], cwd=package, env=env,
        input=b"\r\n", capture_output=True, timeout=20,
    )


def wait_for_health(port, process, token):
    opener = build_opener(ProxyHandler({}))
    request = Request(f"http://127.0.0.1:{port}/health", headers={"Authorization": f"Bearer {token}"})
    for _ in range(50):
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError(f"Manager exited early: {stdout!r} {stderr!r}")
        try:
            with opener.open(request, timeout=0.5) as response:
                if json.load(response)["ok"]:
                    return
        except OSError:
            time.sleep(0.1)
    raise AssertionError("Local proxy did not start")


def port_is_open(port):
    with socket.socket() as client:
        client.settimeout(0.2)
        return client.connect_ex(("127.0.0.1", port)) == 0


with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]

result = run_cmd("API-Manager.cmd", "-Port", str(port), "-Check")
assert result.returncode == 0 and b"Manager OK:" in result.stdout, (result.stdout, result.stderr)
assert not port_is_open(port)
config_path = package / ".local/connection/ccswitch-config.toml"
config = tomllib.loads(config_path.read_text(encoding="utf-8"))
assert Path(config["model_catalog_json"]) == package / "model-catalog.standard.json"
provider = config["model_providers"]["custom"]
assert provider["base_url"] == f"http://127.0.0.1:{port}/v1"
assert provider["wire_api"] == "responses"
token = provider["experimental_bearer_token"]
assert re.fullmatch(r"lp-[0-9a-f]{64}", token)
vault_path = package / ".local/vault.json"
assert json.loads(vault_path.read_text(encoding="utf-8"))["keys"] == []
assert token not in vault_path.read_text(encoding="utf-8")
print("PASS: x64 ZIP contents, bundled Node startup without PATH, Unicode and special-character path, generated TOML, clean first-run vault and check-mode cleanup.")

with subprocess.Popen(
    [str(ps), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(package / "Manage-Proxy.ps1")],
    cwd=package, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    creationflags=subprocess.CREATE_NO_WINDOW,
) as manager:
    try:
        wait_for_health(port, manager, token)
        restarted = tomllib.loads(config_path.read_text(encoding="utf-8"))
        assert restarted["model_providers"]["custom"]["experimental_bearer_token"] == token
        manager.kill()
        manager.wait(timeout=5)
        assert port_is_open(port)
    finally:
        if manager.poll() is None:
            manager.kill()
            manager.wait(timeout=5)
        result = run_cmd("Stop-API-Manager.cmd")
        assert result.returncode == 0, (result.stdout, result.stderr)
assert not port_is_open(port), "Stop CMD left the proxy listening"
print("PASS: token survives restart and Stop CMD releases an orphaned packaged proxy on the saved port.")

with socket.socket() as unrelated:
    unrelated.bind(("127.0.0.1", 0))
    unrelated.listen()
    other_port = unrelated.getsockname()[1]
    result = run_cmd("Stop-API-Manager.cmd", "-Port", str(other_port))
    assert result.returncode == 1
    assert port_is_open(other_port)
    result = run_cmd("API-Manager.cmd", "-Port", str(other_port), "-Check")
    assert result.returncode != 0 and b"already in use" in result.stderr, (result.stdout, result.stderr)
    assert port_is_open(other_port)
print("PASS: an unrelated listener is preserved and startup reports the busy port.")

subprocess.run(
    [str(node), "--test", "tests/test-proxy.mjs", "tests/test-manager.mjs"], cwd=package, env=env,
    timeout=20, check=True,
)
