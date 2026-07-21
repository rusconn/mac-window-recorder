#!/usr/bin/env python3
# Copyright (C) 2026 rusconn
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <https://www.gnu.org/licenses/>.

"""Vendor ffmpeg dylibs from Homebrew into the project.

Discovers transitive dylib dependencies of core ffmpeg libraries,
copies them into vendor/ffmpeg/lib/, rewrites install names to use
@rpath, and re-signs the binaries.
"""

import shutil
import subprocess
from pathlib import Path

HOMEBREW_PREFIX = Path("/opt/homebrew")
VENDOR_LIB = Path("vendor/ffmpeg/lib")
SEED_LIBRARIES = ["libavcodec", "libavformat", "libavutil", "libswscale"]


def brew_prefix() -> Path:
    result = subprocess.run(
        ["brew", "--prefix", "ffmpeg"],
        capture_output=True, text=True, check=True,
    )
    return Path(result.stdout.strip())


def resolve_path(path: Path) -> Path:
    """Resolve to absolute path without following the final symlink."""
    return path.parent.resolve() / path.name


def homebrew_refs(dylib: Path) -> list[Path]:
    """Extract /opt/homebrew/ references from a dylib via otool."""
    result = subprocess.run(
        ["otool", "-L", str(dylib)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return []
    refs = []
    for line in result.stdout.splitlines():
        token = line.split()[0] if line.split() else ""
        if token.startswith(str(HOMEBREW_PREFIX)):
            refs.append(Path(token))
    return refs


def discover_dependencies(ffmpeg_lib: Path) -> list[Path]:
    """BFS discovery of all transitive homebrew dylib dependencies."""
    seed = [resolve_path(ffmpeg_lib / f"{name}.dylib") for name in SEED_LIBRARIES]
    visited: set[Path] = set(seed)
    queue = list(seed)

    while queue:
        current = queue.pop(0)
        for ref in homebrew_refs(current):
            resolved = resolve_path(ref)
            if resolved not in visited and resolved.is_file():
                visited.add(resolved)
                queue.append(resolved)

    return sorted(visited)


def collect_symlinks(deps: list[Path]) -> dict[Path, list[tuple[Path, Path]]]:
    """For each real dep, find symlinks in its directory that point to it.

    Returns {real_path: [(link_path, link_name), ...]}
    """
    symlink_map: dict[Path, list[tuple[Path, Path]]] = {}
    for dep in deps:
        dep_dir = dep.parent
        dep_name = dep.name
        links = []
        for entry in dep_dir.iterdir():
            if entry.suffix != ".dylib" or not entry.is_symlink():
                continue
            if entry.name == dep_name:
                continue
            target_name = entry.readlink().name
            if target_name == dep_name:
                links.append((entry, entry.name))
        if links:
            symlink_map[dep] = links
    return symlink_map


def vendor_dylibs(deps: list[Path]) -> None:
    if VENDOR_LIB.exists():
        shutil.rmtree(VENDOR_LIB)
    VENDOR_LIB.mkdir(parents=True)

    # Step 1: Copy real files
    for dep in deps:
        shutil.copy2(dep, VENDOR_LIB / dep.name)
        (VENDOR_LIB / dep.name).chmod(0o644)

    # Step 2: Recreate symlinks
    symlink_map = collect_symlinks(deps)
    for dep, links in symlink_map.items():
        for _, link_name in links:
            link_path = VENDOR_LIB / link_name
            if link_path.exists() or link_path.is_symlink():
                link_path.unlink()
            link_path.symlink_to(dep.name)

    # Step 3: Fix install names
    for entry in VENDOR_LIB.iterdir():
        if entry.suffix != ".dylib" or entry.is_symlink():
            continue
        entry.chmod(0o644)
        subprocess.run(
            ["install_name_tool", "-id", f"@rpath/{entry.name}", str(entry)],
            capture_output=True,
        )
        for ref in homebrew_refs(entry):
            ref_base = ref.name
            if ref_base == entry.name:
                continue
            if (VENDOR_LIB / ref_base).exists():
                subprocess.run(
                    ["install_name_tool", "-change", str(ref), f"@rpath/{ref_base}", str(entry)],
                    capture_output=True,
                )

    # Step 4: Re-sign (install_name_tool invalidates signatures)
    for entry in VENDOR_LIB.iterdir():
        if entry.suffix != ".dylib" or entry.is_symlink():
            continue
        subprocess.run(
            ["codesign", "--force", "--sign", "-", str(entry)],
            capture_output=True,
        )


def verify() -> bool:
    bad = []
    for entry in sorted(VENDOR_LIB.iterdir()):
        if entry.suffix != ".dylib" or entry.is_symlink():
            continue
        for ref in homebrew_refs(entry):
            bad.append(str(ref))
    if bad:
        print("WARNING: remaining Homebrew refs:")
        for ref in bad:
            print(f"  {ref}")
        return False
    print("OK: All Homebrew references replaced.")
    return True


def main() -> None:
    ffmpeg_lib = brew_prefix() / "lib"

    print("==> Discovering dependencies...")
    deps = discover_dependencies(ffmpeg_lib)
    print(f"Found {len(deps)} dylibs")

    print("==> Creating vendor directories...")
    vendor_dylibs(deps)

    print("==> Verifying...")
    if not verify():
        pass  # warning only

    print()
    print("==> Result:")
    for entry in sorted(VENDOR_LIB.iterdir()):
        print(f"  {entry.name}")
    print()

    result = subprocess.run(
        ["du", "-sh", str(VENDOR_LIB)],
        capture_output=True, text=True,
    )
    print(result.stdout.strip())


if __name__ == "__main__":
    main()
