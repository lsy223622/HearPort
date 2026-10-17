#!/usr/bin/env python3
"""Collect Rust and MsQuic license notices for a HearPort release bundle."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROVIDER_MANIFEST = PROJECT_ROOT / "security" / "spake2-provider" / "Cargo.toml"
RELEASE_TARGET = "x86_64-pc-windows-msvc"
LICENSE_PREFIXES = ("license", "copying", "notice")


class NoticeCollectionError(RuntimeError):
    pass


def _safe_component(value: str) -> str:
    component = re.sub(r"[^A-Za-z0-9._+-]+", "_", value).strip("._")
    if not component:
        raise NoticeCollectionError("Cannot create a safe notice filename")
    return component


def _cargo_metadata(cargo: str, cargo_home: Path | None, target: str) -> dict[str, Any]:
    command = [
        cargo,
        "metadata",
        "--locked",
        "--offline",
        "--filter-platform",
        target,
        "--format-version",
        "1",
        "--manifest-path",
        str(PROVIDER_MANIFEST),
    ]
    environment = None
    if cargo_home is not None:
        import os

        environment = os.environ.copy()
        environment["CARGO_HOME"] = str(cargo_home)

    result = subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise NoticeCollectionError(f"cargo metadata failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise NoticeCollectionError("cargo metadata returned invalid JSON") from error


def _package_notice_files(package: dict[str, Any]) -> tuple[list[Path], list[str]]:
    package_root = Path(package["manifest_path"]).parent
    found: list[Path] = []
    missing: list[str] = []

    declared_file = package.get("license_file")
    if declared_file:
        explicit_path = Path(declared_file)
        if not explicit_path.is_absolute():
            explicit_path = package_root / explicit_path
        if explicit_path.is_file():
            found.append(explicit_path)
        else:
            missing.append(Path(declared_file).name)

    try:
        children = package_root.iterdir()
        for candidate in children:
            if (
                candidate.is_file()
                and candidate.name.lower().startswith(LICENSE_PREFIXES)
            ):
                found.append(candidate)
    except OSError as error:
        if package.get("license") or declared_file:
            missing.append(f"cannot read package directory ({error.strerror})")

    unique: dict[str, Path] = {}
    for path in found:
        unique.setdefault(str(path.resolve()).casefold(), path)
    files = sorted(unique.values(), key=lambda path: path.name.casefold())
    if not files and (package.get("license") or declared_file):
        missing.append("no LICENSE*, COPYING*, or NOTICE* text found")
    return files, missing


def _relative_license_path(package: dict[str, Any], source: Path) -> Path:
    directory = _safe_component(f"{package['name']}-{package['version']}")
    basename = _safe_component(source.name)
    return Path("licenses") / "rust" / directory / basename


def _dependency_rows(root_package: dict[str, Any]) -> list[str]:
    rows: list[str] = []
    for dependency in sorted(
        root_package.get("dependencies", []),
        key=lambda item: (item.get("name", "").casefold(), item.get("kind") or ""),
    ):
        kind = dependency.get("kind") or "normal"
        target = dependency.get("target") or "all targets"
        optional = "yes" if dependency.get("optional") else "no"
        rows.append(
            f"| `{dependency['name']}` | `{dependency.get('req', '*')}` | "
            f"{kind} | `{target}` | {optional} |"
        )
    return rows


def _package_rows(
    packages: list[dict[str, Any]],
    copied_files: dict[str, list[str]],
) -> list[str]:
    rows: list[str] = []
    for package in sorted(packages, key=lambda item: (item["name"].casefold(), item["version"])):
        package_id = package["id"]
        files = copied_files.get(package_id, [])
        file_text = ", ".join(f"`{item}`" for item in files) if files else "none"
        license_name = package.get("license") or "not specified"
        source = package.get("source")
        if source and source.startswith("registry+"):
            source_label = "crates.io registry"
        elif source:
            source_label = "external source"
        else:
            source_label = "local provider crate"
        rows.append(
            f"| `{package['name']}` | `{package['version']}` | `{license_name}` | "
            f"{source_label} | {file_text} |"
        )
    return rows


def collect(
    output_dir: Path,
    msquic_copyright: Path | None,
    cargo: str = "cargo",
    cargo_home: Path | None = None,
    target: str = RELEASE_TARGET,
) -> None:
    """Write a self-contained notice bundle to ``output_dir``."""
    if not PROVIDER_MANIFEST.is_file():
        raise NoticeCollectionError(f"Provider manifest not found: {PROVIDER_MANIFEST}")
    if msquic_copyright is not None and not msquic_copyright.is_file():
        raise NoticeCollectionError("MsQuic copyright file not found")

    metadata = _cargo_metadata(cargo, cargo_home, target)
    packages = metadata.get("packages", [])
    workspace_members = set(metadata.get("workspace_members", []))
    roots = [package for package in packages if package["id"] in workspace_members]
    if len(roots) != 1:
        raise NoticeCollectionError(
            f"Expected one provider workspace package, found {len(roots)}"
        )
    root_package = roots[0]

    package_files: dict[str, list[tuple[Path, Path]]] = {}
    missing_legal_text: list[str] = []
    seen_destinations: set[str] = set()
    for package in packages:
        files, missing = _package_notice_files(package)
        if missing:
            missing_legal_text.append(
                f"{package['name']} {package['version']} "
                f"({package.get('license') or 'license not specified'}): "
                + ", ".join(missing)
            )
        destinations: list[tuple[Path, Path]] = []
        for source in files:
            relative = _relative_license_path(package, source)
            key = relative.as_posix().casefold()
            if key in seen_destinations:
                raise NoticeCollectionError(
                    f"Notice path collision for {package['name']} {package['version']}"
                )
            seen_destinations.add(key)
            destinations.append((source, relative))
        package_files[package["id"]] = destinations

    if missing_legal_text:
        details = "\n  - ".join(missing_legal_text)
        raise NoticeCollectionError(
            "License text is missing for resolved Cargo package(s):\n  - " + details
        )

    project_license = PROJECT_ROOT / "LICENSE"
    summary = PROJECT_ROOT / "THIRD_PARTY_NOTICES.md"
    if not project_license.is_file() or not summary.is_file():
        raise NoticeCollectionError("Project license or THIRD_PARTY_NOTICES.md not found")

    copied_files: dict[str, list[str]] = {}
    for package in packages:
        package_id = package["id"]
        relative_names: list[str] = []
        for source, relative in package_files[package_id]:
            relative_names.append(relative.as_posix())
        copied_files[package_id] = relative_names

    dependency_rows = _dependency_rows(root_package)
    package_rows = _package_rows(packages, copied_files)
    markdown = [
        "# Rust SPAKE2 provider dependency inventory",
        "",
        f"Generated from `cargo metadata --locked --offline` for `{target}`.",
        "Cargo metadata includes the provider's direct development dependencies and the locked package graph for this target.",
        "The package list records license declarations and discovered legal files; it does not assert that each package is shipped as a separate file.",
        "",
        "## Direct provider dependencies",
        "",
        "| Crate | Requirement | Kind | Target | Optional |",
        "|---|---|---|---|---|",
        *dependency_rows,
        "",
        "## Resolved package inventory",
        "",
        "| Crate | Version | Declared license | Source | Collected legal files |",
        "|---|---:|---|---|---|",
        *package_rows,
        "",
    ]

    output_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(summary, output_dir / "THIRD_PARTY_NOTICES.md")
    project_license_copy = output_dir / "licenses" / "hearport" / "LICENSE"
    msquic_copy = output_dir / "licenses" / "msquic" / "copyright"
    project_license_copy.parent.mkdir(parents=True, exist_ok=True)
    if msquic_copyright is not None:
        msquic_copy.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(project_license, project_license_copy)
    if msquic_copyright is not None:
        shutil.copyfile(msquic_copyright, msquic_copy)
    for destinations in package_files.values():
        for source, relative in destinations:
            destination = output_dir / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
    (output_dir / "rust-dependencies.md").write_text(
        "\n".join(markdown), encoding="utf-8", newline="\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--msquic-copyright", type=Path)
    parser.add_argument("--target", default=RELEASE_TARGET, choices=[RELEASE_TARGET, "aarch64-apple-ios"])
    parser.add_argument("--cargo", default="cargo")
    parser.add_argument("--cargo-home", type=Path)
    arguments = parser.parse_args(argv)
    if arguments.target == RELEASE_TARGET and arguments.msquic_copyright is None:
        parser.error("Windows notices require --msquic-copyright")
    try:
        collect(
            arguments.output_dir,
            arguments.msquic_copyright,
            arguments.cargo,
            arguments.cargo_home,
            arguments.target,
        )
    except (NoticeCollectionError, OSError, subprocess.SubprocessError) as error:
        print(f"collect_notices.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
