"""Package a clean Release build; never copy an entire build directory."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEBUG_RUNTIME = re.compile(r"^(?:ucrtbased|(?:msvcp|vcruntime|concrt|vccorlib)\d.*d)\.dll$", re.I)
VC_RUNTIME = re.compile(r"^(?:msvcp|vcruntime|concrt|vccorlib)\d", re.I)


def binary_imports(binary, dumpbin):
    data = binary.read_bytes()
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[:2] != b"MZ" or data[offset:offset + 4] != b"PE\0\0" or struct.unpack_from("<H", data, offset + 4)[0] != 0x8664:
        raise ValueError(f"Not an x64 PE binary: {binary.name}")
    result = subprocess.run([str(dumpbin), "/nologo", "/dependents", str(binary)],
                            capture_output=True, check=True)
    return re.findall(r"^\s+([\w.-]+\.dll)\s*$", result.stdout.decode(errors="replace"), re.M | re.I)


def binary_delay_imports(binary):
    data = binary.read_bytes()

    def read(fmt, offset):
        try:
            return struct.unpack_from(fmt, data, offset)
        except struct.error as error:
            raise ValueError(f"Invalid PE data: {binary.name}") from error

    pe, = read("<I", 0x3c)
    if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0" or read("<H", pe + 4)[0] != 0x8664:
        raise ValueError(f"Not an x64 PE binary: {binary.name}")
    optional = pe + 24
    if read("<H", optional)[0] != 0x20b:
        raise ValueError(f"Not a PE32+ binary: {binary.name}")
    sections = optional + read("<H", pe + 20)[0]

    def file_offset(rva):
        for index in range(read("<H", pe + 6)[0]):
            _, address, size, start = read("<IIII", sections + index * 40 + 8)
            if address <= rva < address + size:
                offset = start + rva - address
                if offset < len(data):
                    return offset
        raise ValueError(f"Unmapped PE RVA: {binary.name}")

    rva, size = read("<II", optional + 112 + 13 * 8)
    if not rva:
        return set()
    names = set()
    for index in range(size // 32):
        descriptor = read("<8I", file_offset(rva + index * 32))
        if not any(descriptor):
            return names
        if descriptor[0] != 1:
            raise ValueError(f"Delay imports must use RVAs: {binary.name}")
        offset = file_offset(descriptor[1])
        end = data.find(b"\0", offset)
        if end < 0:
            raise ValueError(f"Invalid delay import name: {binary.name}")
        names.add(data[offset:end].decode("ascii").lower())
    raise ValueError(f"Unterminated delay import table: {binary.name}")


def collect_runtime(executable, dumpbin, search_dirs, system_dir):
    files = {executable.name: executable}
    pending = [executable]
    while pending:
        for name in binary_imports(pending.pop(), dumpbin):
            name = name.lower()
            if DEBUG_RUNTIME.match(name):
                raise ValueError(f"Debug runtime dependency: {name}")
            if name in files:
                continue
            source = next((folder / name for folder in search_dirs if (folder / name).is_file()), None)
            if source:
                files[name] = source
                pending.append(source)
            elif not VC_RUNTIME.match(name) and (
                name.startswith(("api-ms-", "ext-ms-")) or (system_dir / name).is_file()
            ):
                continue
            else:
                raise ValueError(f"Missing redistributable dependency: {name}")
    return files


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_notices(directory):
    required = ("THIRD_PARTY_NOTICES.md", "rust-dependencies.md", "opus-dependencies.md",
                "licenses/hearport/LICENSE", "licenses/msquic/copyright", "licenses/opus/COPYING")
    if any(not (directory / name).is_file() for name in required):
        raise ValueError("Missing generated Windows dependency license notices")
    inventory = (directory / "rust-dependencies.md").read_text(encoding="utf-8")
    rust_files = re.findall(r"`(licenses/rust/[^`]+)`", inventory)
    if "x86_64-pc-windows-msvc" not in inventory or not rust_files or any(
        not (directory / name).is_file() for name in rust_files
    ):
        raise ValueError("Missing Rust dependency license texts or wrong notice target")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--notices-dir", required=True, type=Path)
    parser.add_argument("--runtime-dir", required=True, type=Path,
                        help="x64 Microsoft.VC143.CRT directory from the VS redistributable files")
    parser.add_argument("--dumpbin", default="dumpbin")
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    git = lambda *items: subprocess.check_output(["git", *items], cwd=ROOT, text=True).strip()
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Commit the release sources before packaging")
    commit = git("rev-parse", "HEAD")
    cache = dict(re.findall(r"^([^/#\n][^:\n]*):[^=\n]+=(.*)$",
                            (args.build_dir / "CMakeCache.txt").read_text(encoding="utf-8"), re.M))
    version = cache["CMAKE_PROJECT_VERSION"]
    source_version = re.search(r"project\(HearPort VERSION ([\d.]+)", (ROOT / "CMakeLists.txt").read_text())[1]
    ios_version = re.search(r"MARKETING_VERSION: ([\d.]+)", (ROOT / "ios/HearPortApp/project.yml").read_text())[1]
    if version != source_version or version != ios_version:
        raise ValueError("Build, Windows source and iPad versions must match")
    if "debug" in [p.lower() for p in Path(cache["HEARPORT_MSQUIC_LIBRARY"]).parts]:
        raise ValueError("Release packaging requires Release MsQuic, not the Debug build cache")
    if not Path(cache["HEARPORT_CARGO_EXECUTABLE"]).is_file():
        raise ValueError("The build must include the SPAKE2 provider")
    executable = args.build_dir / "windows/Release/hearport_sender_gui.exe"
    if "msquic.dll" not in binary_delay_imports(executable):
        raise ValueError("MsQuic must be delay-loaded after the application-local VC runtime")
    files = collect_runtime(executable, args.dumpbin, [executable.parent, args.runtime_dir],
                            Path(os.environ["SystemRoot"]) / "System32")
    if "msquic.dll" not in files:
        raise ValueError("The sender must link MsQuic")
    validate_notices(args.notices_dir)
    output = args.output_dir
    output.mkdir(parents=True, exist_ok=True)
    name = f"HearPort-{version}-windows-x64"
    zip_path = output / f"{name}.zip"
    source_path = output / f"HearPort-{version}-source.zip"
    artifacts = [zip_path, source_path]
    ipa_info = None
    if args.ipa:
        with zipfile.ZipFile(args.ipa) as archive:
            ipa_info = plistlib.loads(archive.read("Payload/HearPort.app/Info.plist"))
        if (ipa_info["CFBundleIdentifier"] != "com.lsy223622.HearPort" or
                ipa_info["CFBundleShortVersionString"] != version or
                not ipa_info["HearPortBuildID"].startswith(commit + "-")):
            raise ValueError("IPA must match this source commit and product version")
        ipa_path = output / f"HearPort-{version}-ipad-{ipa_info['CFBundleVersion']}-unsigned.ipa"
        artifacts.append(ipa_path)
    if any(p.exists() for p in artifacts):
        raise ValueError("Use a new output directory; existing release artifacts will not be overwritten")
    with tempfile.TemporaryDirectory(prefix="hearport-release-", dir=output) as temporary:
        stage = Path(temporary) / name
        stage.mkdir()
        for filename, source in files.items():
            shutil.copy2(source, stage / ("HearPort.exe" if source == executable else filename))
        for filename in ("README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT / filename, stage / filename)
        shutil.copy2(ROOT / "windows/installer/README.md", stage / "INSTALL.md")
        shutil.copytree(args.notices_dir, stage, dirs_exist_ok=True)
        metadata = {"version": version, "commit": commit, "configuration": "Release", "architecture": "x64",
                    "files": {p.relative_to(stage).as_posix(): sha256(p) for p in sorted(stage.rglob("*")) if p.is_file()}}
        (stage / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        shutil.make_archive(str(output / name), "zip", temporary, name)
    subprocess.run(["git", "archive", "--format=zip", f"--output={source_path.resolve()}", commit], cwd=ROOT, check=True)
    if args.ipa:
        shutil.copy2(args.ipa, ipa_path)
    (output / "SHA256SUMS.txt").write_text("".join(f"{sha256(p)}  {p.name}\n" for p in artifacts), encoding="ascii")
    print("\n".join(str(p) for p in artifacts))


if __name__ == "__main__":
    main()
