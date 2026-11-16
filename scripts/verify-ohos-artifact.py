"""Download and independently verify OHOS native GitHub Actions artifacts."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe(name):
    path = PurePosixPath(name)
    assert not path.is_absolute() and ".." not in path.parts, name
    assert "\\" not in name and ":" not in name, name
    return path.as_posix()


def tar_inventory(data, machine, keep=False):
    hashes, contents, elf_names = {}, {}, []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        seen = set()
        for member in archive:
            name = safe(member.name)
            assert name not in seen, name
            seen.add(name)
            assert member.isdir() or member.isfile(), name
            if member.isdir():
                continue
            body = archive.extractfile(member).read()
            hashes[name] = sha(body)
            if keep:
                contents[name] = body
            if body.startswith(b"\x7fELF"):
                assert body[4:6] == b"\x02\x01", name
                assert struct.unpack_from("<H", body, 18)[0] == machine, name
                elf_names.append(name)
    return hashes, contents, elf_names


def verify(filename, abi, commit, repository="azurekiln2333/qflistudio-java", expected_run=None):
    machine = {"arm64-v8a": 183, "x86_64": 62}[abi]
    prefix = f"openjdk-ohos-{abi}"
    image_name, staged_name = f"{prefix}-image.tar.gz", f"{prefix}-staged.tar.gz"
    with zipfile.ZipFile(filename) as outer:
        assert outer.testzip() is None
        assert len(outer.namelist()) == 4
        assert set(outer.namelist()) == {
            image_name, staged_name, "SHA256SUMS", "provenance.json"
        }
        checks = {}
        for line in outer.read("SHA256SUMS").decode().splitlines():
            digest, name = line.split(maxsplit=1)
            name = name.lstrip("*")
            assert safe(name) == name and name not in checks
            checks[name] = digest
        assert set(checks) == {image_name, staged_name, "provenance.json"}
        for name, digest in checks.items():
            assert sha(outer.read(name)) == digest, name
        provenance = json.loads(outer.read("provenance.json"))
        assert provenance["platform"] == "ohos"
        assert provenance["abi"] == abi and provenance["commit"] == commit
        assert provenance["device_runtime_verified"] is False
        assert provenance["repository"] == repository
        if expected_run is not None:
            assert provenance["run"] == expected_run
        assert provenance["sdk"]["sha256"] == "a315834ac133625efc912bd078f3e2b2550868d04aef1b5aa4f9679c8b3c9d8e"
        image, _, image_elf = tar_inventory(outer.read(image_name), machine)
        staged, contents, staged_elf = tar_inventory(outer.read(staged_name), machine, True)
    for required in ("bin/java", "bin/javac", "bin/jar", "bin/javap", "bin/jshell", "lib/modules", "release"):
        assert required in image, required
    assert sha(provenance["jdk_release"].encode()) == image["release"]
    assert not any(n.endswith(".debuginfo") or n == "lib/src.zip" for n in image)
    lib_root = f"native/build/ohos/jniLibs/{abi}/"
    asset_root = "native/build/ohos/assets/"
    manifest_name = f"jdk-{abi}.json"
    zip_name = f"jdk-{abi}.zip"
    manifest = json.loads(contents[asset_root + manifest_name])
    assert manifest["version"] == 1
    assert re.fullmatch(rf"ohos-{re.escape(abi)}-[a-f0-9]{{64}}", manifest["id"])
    expected_libs = {"libqfli_java.so", "libqfli_javac.so"}
    source_paths = set()
    for record in manifest["libraries"]:
        source, library = record["path"], record["library"]
        assert safe(source) == source and PurePosixPath(library).name == library
        assert source not in source_paths, source
        source_paths.add(source)
        assert image[source] == staged[lib_root + library], record
        expected_libs.add(library)
    expected_sources = {
        name for name in image if name.startswith("lib/")
        and (re.search(r"\.so(?:\.[0-9]+)*$", name) or name in {"lib/jspawnhelper", "lib/jexec"})
    }
    assert source_paths == expected_sources, (source_paths ^ expected_sources)
    for tool in ("java", "javac"):
        assert image[f"bin/{tool}"] == staged[lib_root + f"libqfli_{tool}.so"]
    assert {n[len(lib_root):] for n in staged if n.startswith(lib_root)} == expected_libs
    assert len([n for n in staged_elf if n.startswith(lib_root)]) == len(expected_libs)
    with zipfile.ZipFile(io.BytesIO(contents[asset_root + zip_name])) as data_zip:
        assert data_zip.testzip() is None
        assert len(set(data_zip.namelist())) == len(data_zip.namelist())
        assert json.loads(data_zip.read("layout.json")) == manifest
        data_names = set(data_zip.namelist()) - {"layout.json"}
        for name in data_names:
            assert safe(name) == name
            assert sha(data_zip.read(name)) == image[name], name
        expected_data = {
            name for name in image
            if (name.startswith(("conf/", "lib/", "legal/")) or name == "release")
            and not re.search(r"\.so(?:\.[0-9]+)*$|\.debuginfo$", name)
            and PurePosixPath(name).name not in {"src.zip", "jspawnhelper", "jexec"}
        }
        assert data_names == expected_data, (data_names ^ expected_data)
        legal = {name for name in image if name.startswith("legal/")}
        assert legal <= data_names
        for notice in ("legal/qfli-alsa-lib/COPYING", "legal/qfli-libffi/LICENSE", "legal/qfli-build-inputs.json"):
            assert notice in legal, notice
        assert json.loads(data_zip.read("legal/qfli-build-inputs.json")) == provenance["retained_inputs"]
    mirror_libs = f"ohos/entry/libs/{abi}/"
    mirror_assets = "ohos/entry/src/main/resources/rawfile/"
    for library in expected_libs:
        assert staged[lib_root + library] == staged[mirror_libs + library], library
    for asset in (manifest_name, zip_name):
        assert staged[asset_root + asset] == staged[mirror_assets + asset], asset
    expected_staged = {lib_root + n for n in expected_libs} | {mirror_libs + n for n in expected_libs}
    expected_staged |= {root + n for root in (asset_root, mirror_assets) for n in (manifest_name, zip_name)}
    assert set(staged) == expected_staged, (set(staged) ^ expected_staged)
    report = {
        "artifact": str(Path(filename).resolve()), "bytes": Path(filename).stat().st_size,
        "abi": abi, "commit": commit, "image_elf_count": len(image_elf),
        "staged_native_count": len(expected_libs), "legal_files": len(legal),
        "image_files": len(image), "staged_files_including_ohos_copies": len(staged),
        "data_files": len(data_names), "device_runtime_verified": False,
        "verification": "passed",
    }
    return report


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep the GitHub API credential out of artifact storage requests."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SecureRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_https(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def require_https(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise ValueError("Artifact storage must use HTTPS without URL credentials")


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Expected an owner/repository name")
        if not token:
            raise ValueError("GH_TOKEN is required")
        self.base = f"https://api.github.com/repos/{repository}"
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "qfli-native-artifact-verifier",
        }
        self.api_opener = urllib.request.build_opener(NoRedirect())

    def request(self, path):
        return urllib.request.Request(self.base + path, headers=self.headers)

    def json(self, path):
        try:
            with self.api_opener.open(self.request(path), timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"GitHub API failed with HTTP {error.code}") from None
        except urllib.error.URLError:
            raise RuntimeError("GitHub API connection failed") from None

    def download(self, artifact, destination):
        digest = artifact.get("digest", "")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError("Artifact API metadata has no SHA-256 digest")
        expected_size = artifact["size_in_bytes"]
        if not isinstance(expected_size, int) or expected_size <= 0:
            raise ValueError("Artifact API metadata has an invalid size")
        try:
            with self.api_opener.open(
                self.request(f"/actions/artifacts/{artifact['id']}/zip"), timeout=60
            ):
                raise RuntimeError("GitHub artifact endpoint did not redirect")
        except urllib.error.HTTPError as error:
            if error.code != 302:
                raise RuntimeError(f"Artifact endpoint failed with HTTP {error.code}") from None
            location = error.headers.get("Location", "")
        except urllib.error.URLError:
            raise RuntimeError("Artifact endpoint connection failed") from None
        require_https(location)
        # This opener receives no API headers, so authorization cannot cross hosts.
        storage = urllib.request.build_opener(SecureRedirect())
        partial = destination.with_suffix(".zip.part")
        hasher = hashlib.sha256()
        received = 0
        try:
            try:
                with storage.open(location, timeout=60) as response, partial.open("wb") as output:
                    while chunk := response.read(1024 * 1024):
                        received += len(chunk)
                        if received > expected_size:
                            raise ValueError("Artifact exceeds its API size")
                        hasher.update(chunk)
                        output.write(chunk)
            except (urllib.error.URLError, TimeoutError):
                # Do not expose the signed storage URL through exception messages.
                raise RuntimeError("Artifact storage download failed") from None
            if received != expected_size or "sha256:" + hasher.hexdigest() != digest:
                raise ValueError("Artifact API size or SHA-256 digest mismatch")
            partial.replace(destination)
        finally:
            partial.unlink(missing_ok=True)


def verify_github(args):
    api = GitHub(args.repository, os.environ.get("GH_TOKEN", ""))
    workflow = api.json("/actions/workflows/native-build.yml")
    expected_commit = None
    if args.source_run:
        if not re.fullmatch(r"[0-9]+", args.source_run):
            raise ValueError("source_run must be a numeric GitHub Actions run ID")
        run_id = int(args.source_run)
    else:
        if not args.branch:
            raise ValueError("A branch is required when source_run is blank")
        query = urllib.parse.urlencode({"branch": args.branch, "status": "success", "per_page": 1})
        runs = api.json(f"/actions/workflows/{workflow['id']}/runs?{query}")["workflow_runs"]
        if not runs:
            raise ValueError("No successful Native OpenJDK run exists on this branch")
        run_id, expected_commit = runs[0]["id"], runs[0]["head_sha"]
    run = api.json(f"/actions/runs/{run_id}")
    assert run["id"] == run_id and run["workflow_id"] == workflow["id"]
    assert run["repository"]["full_name"] == args.repository
    assert run["status"] == "completed" and run["conclusion"] == "success"
    if expected_commit is not None:
        assert run["head_sha"] == expected_commit and run["head_branch"] == args.branch
    commit = run["head_sha"]
    assert re.fullmatch(r"[a-f0-9]{40}", commit)
    artifacts = []
    page = 1
    while True:
        result = api.json(f"/actions/runs/{run_id}/artifacts?per_page=100&page={page}")
        artifacts.extend(result["artifacts"])
        if len(artifacts) >= result["total_count"]:
            break
        if not result["artifacts"]:
            raise ValueError("Artifact API pagination ended early")
        page += 1
    args.output_dir.mkdir(parents=True, exist_ok=True)
    reports = []
    for abi in ("arm64-v8a", "x86_64"):
        name = f"native-ohos-{abi}-{commit}"
        matches = [artifact for artifact in artifacts if artifact["name"] == name]
        assert len(matches) == 1, f"Expected exactly one {name} artifact"
        artifact = matches[0]
        assert artifact["expired"] is False, f"Artifact {name} has expired"
        assert artifact["workflow_run"]["id"] == run_id
        assert artifact["workflow_run"]["head_sha"] == commit
        destination = args.output_dir / f"{name}.zip"
        api.download(artifact, destination)
        report = verify(destination, abi, commit, args.repository,
                        f"https://github.com/{args.repository}/actions/runs/{run_id}")
        report.update(run_id=run_id, artifact_id=artifact["id"], sha256=artifact["digest"][7:])
        print(json.dumps(report, indent=2), flush=True)
        notice = {key: report[key] for key in (
            "abi", "run_id", "artifact_id", "commit", "image_elf_count",
            "staged_native_count", "legal_files", "verification"
        )}
        print(f"::notice title=OHOS {abi} artifact verified::{json.dumps(notice)}", flush=True)
        reports.append(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(f"## OHOS artifact verification\n\nSource run: `{run_id}`\n\nCommit: `{commit}`\n\n")
            output.write("| ABI | Artifact ID | Image ELF files | Staged native files | Legal files | Result |\n")
            output.write("| --- | --- | --- | --- | --- | --- |\n")
            for report in reports:
                output.write(
                    f"| {report['abi']} | {report['artifact_id']} | {report['image_elf_count']} | "
                    f"{report['staged_native_count']} | {report['legal_files']} | passed |\n"
                )
            output.write("\nValidated API size/digest, archive checksums, provenance, ELF architecture, "
                         "staged data, OHOS copies, and legal notices. Device execution is not verified.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    local = commands.add_parser("local", help="Verify an already downloaded artifact ZIP")
    local.add_argument("artifact", type=Path)
    local.add_argument("abi", choices=("arm64-v8a", "x86_64"))
    local.add_argument("commit")
    github = commands.add_parser("github", help="Download both OHOS artifacts from a successful run")
    github.add_argument("--source-run", default=os.environ.get("SOURCE_RUN", ""))
    github.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    github.add_argument("--branch", default=os.environ.get("GITHUB_REF_NAME", ""))
    github.add_argument("--output-dir", type=Path,
                        default=Path(os.environ.get("RUNNER_TEMP", ".")) / "ohos-artifact-verification")
    args = parser.parse_args()
    if args.command == "local":
        print(json.dumps(verify(args.artifact, args.abi, args.commit), indent=2))
    else:
        verify_github(args)


if __name__ == "__main__":
    main()
