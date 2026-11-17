#!/usr/bin/env python3
"""Retain locked Android packages and their corresponding upstream sources.

The packages must already exist in --cache and match the build recipe locks.
Only public upstream sources are downloaded. No archive is extracted to disk.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
import time
import urllib.request


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PACKAGE_BASE = "https://packages.termux.dev/apt/termux-main/pool/main"


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def package_entries(cache: Path) -> list[dict[str, str]]:
    entries: dict[str, dict[str, str]] = {}
    for name in ("dependencies.lock", "dependencies-x86_64.lock"):
        for line in (HERE.parent / "android" / name).read_text().splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            sha, filename, directory = line.split()
            entry = {"filename": filename, "sha256": sha,
                     "url": f"{PACKAGE_BASE}/{directory}/{filename}"}
            if filename in entries and entries[filename] != entry:
                raise ValueError(f"Conflicting package locks: {filename}")
            path = cache / filename
            if not path.is_file() or digest(path) != sha:
                raise ValueError(f"Missing or mismatched locked package: {path}")
            entries[filename] = entry
    return [entries[key] for key in sorted(entries)]


def download(entry: dict[str, str], directory: Path) -> Path:
    path = directory / entry["filename"]
    if path.is_file() and digest(path) == entry["sha256"]:
        return path
    partial = path.with_name(path.name + ".part")
    request = urllib.request.Request(entry["url"], headers={"User-Agent": "curl/8.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as stream:
                while chunk := response.read(1024 * 1024):
                    stream.write(chunk)
            if digest(partial) != entry["sha256"]:
                raise ValueError(f"Source checksum mismatch: {entry['filename']}")
            partial.replace(path)
            return path
        except (OSError, ValueError):
            if attempt == 2:
                raise
            time.sleep(2)
    raise AssertionError("unreachable")


def source_entries(termux: Path, packages: list[dict[str, str]]) -> list[dict[str, str]]:
    result = []
    names = sorted({entry["filename"].split("_", 1)[0] for entry in packages})
    with tarfile.open(termux, "r:gz") as archive:
        members = archive.getmembers()
        for package in names:
            suffix = f"/packages/{package}/build.sh"
            member = next(item for item in members if item.name.endswith(suffix))
            stream = archive.extractfile(member)
            assert stream is not None
            recipe = stream.read().decode()

            def field(name: str) -> str:
                match = re.search(rf"^{name}=(.+)$", recipe, re.MULTILINE)
                if match is None:
                    raise ValueError(f"Missing {name} in {package} recipe")
                return match[1].strip().strip('"')

            entry = {"package": package, "version": field("TERMUX_PKG_VERSION"),
                     "license": field("TERMUX_PKG_LICENSE")}
            revision = re.search(r"^TERMUX_PKG_REVISION=(.+)$", recipe, re.MULTILINE)
            binary_version = entry["version"] + (f"-{revision[1].strip()}" if revision else "")
            for binary in packages:
                if binary["filename"].startswith(package + "_"):
                    if binary["filename"].split("_")[1] != binary_version:
                        raise ValueError(f"Source recipe does not match package version: {binary['filename']}")
            if "TERMUX_PKG_SKIP_SRC_EXTRACT=true" in recipe:
                entry["archive"] = termux.name
                entry["location"] = member.name.removesuffix("/build.sh")
            else:
                url = field("TERMUX_PKG_SRCURL")
                url = url.replace("${TERMUX_PKG_VERSION}", entry["version"])
                url = url.replace("$TERMUX_PKG_VERSION", entry["version"])
                if "$" in url or not url.startswith("https://"):
                    raise ValueError(f"Unsupported source URL in {package}: {url}")
                extension = ".tar.xz" if url.endswith(".tar.xz") else ".tar.gz"
                entry.update(url=url, sha256=field("TERMUX_PKG_SHA256"),
                             filename=f"{package}-{entry['version']}{extension}")
            result.append(entry)
    return result


def bundle(path: Path, entries: dict[str, Path | bytes]) -> None:
    # Fixed gzip/tar metadata makes the same verified input bytes reproducible.
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name, source in sorted(entries.items()):
                    info = tarfile.TarInfo(name)
                    info.mode = 0o644
                    if isinstance(source, bytes):
                        info.size = len(source)
                        archive.addfile(info, io.BytesIO(source))
                    else:
                        info.size = source.stat().st_size
                        with source.open("rb") as stream:
                            archive.addfile(info, stream)


def license_entries(termux: Path, sources: list[dict[str, str]], downloads: Path) -> dict[str, bytes]:
    notices = {}
    pattern = re.compile(r"^(COPYING|LICENSE|COPYRIGHT)(?:[._-].*)?$", re.IGNORECASE)
    for source in sources:
        path = downloads / source["filename"] if "filename" in source else termux
        found = False
        with tarfile.open(path) as archive:
            for member in archive.getmembers():
                parts = member.name.strip("/").split("/")
                expected_parent = source.get("location", parts[0])
                if not member.isfile() or "/".join(parts[:-1]) != expected_parent:
                    continue
                if not pattern.fullmatch(parts[-1]):
                    continue
                stream = archive.extractfile(member)
                assert stream is not None
                notices[f"licenses/{source['package']}/{parts[-1]}"] = stream.read()
                found = True
        if not found:
            raise ValueError(f"No source license notice found for {source['package']}")
    return notices


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True,
                        help="Existing recipe download cache containing locked .deb files")
    parser.add_argument("--output", type=Path, default=REPO / "build/native-ci-inputs")
    parser.add_argument("--write-lock", action="store_true",
                        help="Update archive hashes in the tracked inputs.lock.json")
    args = parser.parse_args()
    lock_path = HERE / "inputs.lock.json"
    lock = json.loads(lock_path.read_text())
    packages = package_entries(args.cache.resolve())
    output = args.output.resolve()
    downloads = output / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    termux = download(lock["termux_source"], downloads)
    sources = source_entries(termux, packages)
    downloadable = [entry for entry in sources if "url" in entry]
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda entry: download(entry, downloads), downloadable))
    provenance = json_bytes({"version": 1, "termux_commit": lock["termux_commit"],
                             "termux_source": lock["termux_source"],
                             "packages": packages, "sources": sources})
    notices = (
        "Retained native build inputs\n\n"
        "The dependency archive preserves original Termux .deb files unchanged.\n"
        "Each .deb includes its original package metadata and embedded notices.\n"
        "The companion source archive includes all upstream package sources and\n"
        "the complete pinned Termux repository, including recipes, patches, build\n"
        "helpers and licenses. Two Android compatibility libraries have their\n"
        "source directly in the Termux packages directory. See input-provenance.json.\n"
        "The source archive is available beside this dependency archive at:\n"
        f"{lock['sources']['url']}\n"
        "Source license notices are also retained under licenses/PACKAGE/.\n"
        "Copy licenses/ into the runtime image's legal/qfli-termux directory.\n"
    ).encode()
    dependency_files: dict[str, Path | bytes] = {
        entry["filename"]: args.cache / entry["filename"] for entry in packages
    }
    dependency_files.update({"input-provenance.json": provenance, "README.txt": notices,
                             "SHA256SUMS": "".join(
                                 f"{entry['sha256']}  {entry['filename']}\n"
                                 for entry in packages).encode()})
    dependency_files.update(license_entries(termux, sources, downloads))
    dependency_files["licenses/input-provenance.json"] = provenance
    dependency_files["licenses/README.txt"] = notices
    source_files: dict[str, Path | bytes] = {
        "termux-packages/" + termux.name: termux,
        "input-provenance.json": provenance,
        "README.txt": notices,
    }
    source_files.update({"upstream/" + entry["filename"]: downloads / entry["filename"]
                         for entry in downloadable})
    source_files["SHA256SUMS"] = "".join(
        f"{digest(path)}  {name}\n" for name, path in sorted(source_files.items())
        if isinstance(path, Path)
    ).encode()
    for key, entries in (("dependencies", dependency_files), ("sources", source_files)):
        path = output / lock[key]["filename"]
        bundle(path, entries)
        lock[key]["sha256"] = digest(path)
        print(f"{path.name}: {path.stat().st_size} bytes; SHA256 {lock[key]['sha256']}")
    (output / "input-provenance.json").write_bytes(provenance)
    (output / "inputs.lock.json").write_bytes(json_bytes(lock))
    (output / "SHA256SUMS").write_text("".join(
        f"{lock[key]['sha256']}  {lock[key]['filename']}\n"
        for key in ("dependencies", "sources")), encoding="utf-8", newline="\n")
    if args.write_lock:
        lock_path.write_bytes(json_bytes(lock))


if __name__ == "__main__":
    main()
