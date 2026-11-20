"""Build the portable Windows x64 package from a clean source checkout."""
from hashlib import file_digest
from pathlib import Path
from shutil import copyfileobj
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "dist"
PACKAGE = "Local-OpenAI-API-Manager"
ZIP_NAME = f"{PACKAGE}-win64.zip"
NODE_VERSION = "v24.22.3"
NODE_DIR = f"node-{NODE_VERSION}-win-x64"
NODE_ZIP = f"{NODE_DIR}.zip"
NODE_URL = f"https://nodejs.org/dist/{NODE_VERSION}/{NODE_ZIP}"
NODE_ZIP_SHA256 = "e612af99f626ab415ea225af6bce5c971feb448cb5cae250bb1c3fa50c5f7d9f"
NODE_EXE_SHA256 = "86fc4785327db5f5c7558dc6156c543b433c313e813a222e088086222ab4afa6"
FILES = (
    "API-Manager.cmd",
    "Stop-API-Manager.cmd",
    "Manage-Proxy.ps1",
    "Stop-Proxy.ps1",
    "Start-Codex.ps1",
    "ProxyManager.psm1",
    "proxy.mjs",
    "ccswitch-setup.mjs",
    "vendor/smol-toml.cjs",
    "vendor/SMOL-TOML-LICENSE.txt",
    "model-catalog.standard.json",
    "examples/provider.example.toml",
    "README.md",
    "LICENSE",
    "docs/CCSWITCH.md",
    "docs/TROUBLESHOOTING.md",
    "docs/THIRD-PARTY.md",
    "docs/CATALOG-NOTICE.md",
    "docs/LICENSE.codex.txt",
    "docs/NOTICE.codex.txt",
    "tests/test-manager.mjs",
    "tests/test-proxy.mjs",
)


def sha256(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def download_runtime():
    cache = ROOT / ".build"
    cache.mkdir(exist_ok=True)
    runtime = cache / NODE_ZIP
    if runtime.is_file() and sha256(runtime) == NODE_ZIP_SHA256:
        return runtime
    with TemporaryDirectory(dir=cache) as work:
        downloaded = Path(work) / NODE_ZIP
        print(f"Downloading Node.js {NODE_VERSION} for Windows x64", flush=True)
        with urlopen(NODE_URL, timeout=60) as response, downloaded.open("wb") as output:
            copyfileobj(response, output)
        if sha256(downloaded) != NODE_ZIP_SHA256:
            raise SystemExit("The official Node.js ZIP did not match its pinned checksum.")
        downloaded.replace(runtime)
    return runtime


def build():
    runtime = download_runtime()
    OUTPUT_DIR.mkdir(exist_ok=True)
    with TemporaryDirectory(dir=OUTPUT_DIR) as work:
        temporary = Path(work) / ZIP_NAME
        with ZipFile(temporary, "w", ZIP_DEFLATED, compresslevel=6) as archive, ZipFile(runtime) as node:
            for path in FILES:
                archive.write(ROOT / path, f"{PACKAGE}/{path}")
            with node.open(f"{NODE_DIR}/node.exe") as exe:
                if file_digest(exe, "sha256").hexdigest() != NODE_EXE_SHA256:
                    raise SystemExit("The bundled Node.js executable did not match its pinned checksum.")
            with node.open(f"{NODE_DIR}/node.exe") as exe, archive.open(f"{PACKAGE}/runtime/win-x64/node.exe", "w") as output:
                copyfileobj(exe, output)
            archive.writestr(f"{PACKAGE}/runtime/NODEJS-LICENSE.txt", node.read(f"{NODE_DIR}/LICENSE"))
            archive.writestr(
                f"{PACKAGE}/runtime/NODEJS-NOTICE.txt",
                f"Node.js {NODE_VERSION} for Windows x64\nSource: {NODE_URL}\n"
                f"Node.js ZIP SHA-256: {NODE_ZIP_SHA256}\nnode.exe SHA-256: {NODE_EXE_SHA256}\n",
            )
        with ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise SystemExit("ZIP integrity check failed.")
        target = OUTPUT_DIR / ZIP_NAME
        temporary.replace(target)
    print(f"{target.relative_to(ROOT)}: {target.stat().st_size:,} bytes")
    print(f"SHA-256: {sha256(target)}")


if __name__ == "__main__":
    build()
