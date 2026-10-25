"""Bind local build/HAP/runtime artifacts without installing or querying a device.

An artifact match is not proof of installation, signature acceptance or device
identity. The device driver must retain that independent evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse
import urllib.request
import zipfile


BUNDLE = "com.azurekiln.qfli.java"
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
NONCE = re.compile(r"[0-9a-f]{32}\Z")


class BindingError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise BindingError(message)


def file_hash(path):
    result = hashlib.sha256()
    with pathlib.Path(path).open("rb") as source:
        for part in iter(lambda: source.read(1024 * 1024), b""):
            result.update(part)
    return result.hexdigest()


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(",", ":")).encode("utf-8")).hexdigest()


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))


def resolve_package(config_path, uri, *, strict=True):
    resolved = urllib.parse.urlsplit(urllib.parse.urljoin(config_path.as_uri(), uri))
    require(resolved.scheme == "file" and resolved.netloc in ("", "localhost"),
            "A build dependency must resolve to a local file URI")
    return pathlib.Path(urllib.request.url2pathname(resolved.path)).resolve(strict=strict)


def capture_inputs(repo, target):
    """Enumerate actual resolved package sources and local shipped inputs.

    The managed entry profile is bound separately by the builder's original,
    temporary and restored hashes; it is deliberately absent from this stable
    source inventory so normal restoration does not invalidate the manifest.
    Signing key/certificate/store contents and generated build trees are omitted.
    Config files are hashed as opaque bytes; their contents are never reported.
    """
    repo = pathlib.Path(repo).resolve(strict=True)
    target = pathlib.Path(target)
    target = (target if target.is_absolute() else repo / target).resolve(strict=True)
    require(target.is_relative_to(repo) and target.suffix == ".dart",
            "The target must be a Dart entry inside this Java repository")
    config_path = repo / ".dart_tool/package_config.json"
    config = read_json(config_path)
    packages = config.get("packages")
    require(isinstance(packages, list) and packages, "Missing resolved Dart packages")
    names = [package.get("name") for package in packages]
    require(len(names) == len(set(names)) and names.count("qfli_studio_core") == 1,
            "Expected exactly one resolved qfli_studio_core dependency")
    inputs = {}
    roots = {"java": str(repo)}

    def add(path, key):
        path = pathlib.Path(path).resolve(strict=True)
        require(path.is_file(), "Expected input file: " + key)
        require(key not in inputs, "Repeated input identity: " + key)
        inputs[key] = {"key": key, "path": str(path), "bytes": path.stat().st_size,
                       "sha256": file_hash(path)}

    def optional(path, key):
        if path.is_file():
            add(path, key)

    def tree(root, prefix, suffix=None):
        if not root.is_dir():
            return
        for path in sorted(root.rglob("*")):
            if path.is_file() and (suffix is None or path.suffix == suffix):
                relative = path.relative_to(root)
                if not any(part in ("build", ".git", ".dart_tool", "node_modules")
                           for part in relative.parts):
                    add(path, prefix + relative.as_posix())

    for package in sorted(packages, key=lambda value: value["name"]):
        name = package["name"]
        root = resolve_package(config_path, package["rootUri"])
        library = resolve_package(config_path, urllib.parse.urljoin(
            root.as_uri().rstrip("/") + "/", package.get("packageUri", "lib/")), strict=False)
        require(library.is_relative_to(root), "Package library escapes its package root: " + name)
        roots["package:" + name] = str(root)
        tree(library, "package/" + name + "/lib/", ".dart")
        for config_name in ("pubspec.yaml", "pubspec.lock", "pubspec_overrides.yaml"):
            optional(root / config_name, "package/" + name + "/" + config_name)
        # Assets can affect the installed curriculum and fonts independently of
        # Dart edits. Hash assets of every resolved package that ships them.
        tree(root / "assets", "package/" + name + "/assets/")
        # Asset-only packages (for example cupertino_icons) legitimately have
        # no lib directory. Native plugin inputs also live outside lib/assets.
        for config_name in ("build-profile.json5", "oh-package.json5",
                            "oh-package-lock.json5", "hvigorfile.ts"):
            optional(root / "ohos" / config_name, "package/" + name + "/ohos/" + config_name)
        for directory in ("src", "libs"):
            tree(root / "ohos" / directory, "package/" + name + "/ohos/" + directory + "/")

    core = pathlib.Path(roots["package:qfli_studio_core"])
    require((core / "lib").is_dir(), "Resolved core has no lib directory")
    for root, prefix in ((repo, "java/"), (core, "core/")):
        for name in (".dart_tool/package_config.json", "analysis_options.yaml"):
            optional(root / name, prefix + name)
    tree(repo / "tools", "java/tools/", ".dart")
    add(target, "java/target/" + target.relative_to(repo).as_posix())
    add(pathlib.Path(__file__), "audit/verify_java_ohos_binding.py")
    optional(repo / "tools/build_ohos_audit.ps1", "audit/build_ohos_audit.ps1")
    optional(repo / ".flutter-plugins-dependencies", "java/.flutter-plugins-dependencies")
    for name in ("build-profile.json5", "oh-package.json5", "oh-package-lock.json5",
                 "hvigorfile.ts", "hvigorconfig.ts", "hvigor/hvigor-config.json5",
                 "entry/oh-package.json5",
                 "entry/oh-package-lock.json5", "entry/hvigorfile.ts",
                 "AppScope/app.json5"):
        optional(repo / "ohos" / name, "java/ohos/" + name)
    for name in ("ets", "cpp"):
        tree(repo / "ohos/entry/src/main" / name, "java/native/" + name + "/")
    add(repo / "ohos/entry/src/main/module.json5", "java/native/module.json5")
    resources = repo / "ohos/entry/src/main/resources"
    for path in sorted(resources.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(resources)
        if "flutter_assets" in relative.parts or path.name.startswith("jdk-arm64-v8a."):
            continue
        add(path, "java/native/resources/" + relative.as_posix())
    staged = repo / "ohos/entry/libs/x86_64"
    libraries = sorted(staged.glob("*.so"))
    require(libraries, "No staged x86_64 JDK libraries")
    for library in libraries:
        add(library, "java/staged/x86_64/" + library.name)
    for extension in ("json", "zip"):
        require("java/native/resources/rawfile/jdk-x86_64." + extension in inputs,
                "Missing staged x86_64 JDK " + extension)
    payload = {"schemaVersion": 1, "target": target.relative_to(repo).as_posix(),
               "managedEntryProfile": "ohos/entry/build-profile.json5",
               "roots": roots, "inputs": [inputs[key] for key in sorted(inputs)]}
    return {**payload, "manifestSha256": canonical_hash(payload)}


def validate_manifest(manifest, current=False):
    require(isinstance(manifest, dict) and manifest.get("schemaVersion") == 1,
            "Unsupported input manifest")
    value = dict(manifest)
    digest = value.pop("manifestSha256", None)
    require(isinstance(digest, str) and HEX64.fullmatch(digest) and canonical_hash(value) == digest,
            "Input manifest identity mismatch")
    rows = manifest.get("inputs")
    require(isinstance(rows, list) and rows, "Empty input manifest")
    keys = [row.get("key") for row in rows]
    require(all(isinstance(key, str) and key for key in keys) and len(keys) == len(set(keys)),
            "Missing/repeated manifest input key")
    require("java/native/ets/entryability/EntryAbility.ets" in keys,
            "EntryAbility is missing from the input manifest")
    if current:
        actual = capture_inputs(manifest["roots"]["java"], manifest["target"])
        require(actual == manifest, "Current build input set or bytes differ from the captured manifest")
    return {row["key"]: row for row in rows}


def verify_artifacts(build_path, runtime_path, hap_path):
    build, runtime = read_json(build_path), read_json(runtime_path)
    hap_path = pathlib.Path(hap_path).resolve(strict=True)
    require(build.get("buildExitCode") == 0 and build.get("error") is None,
            "The build did not complete successfully")
    require(build.get("profileRestored") is True and build.get("environmentRestored") is True,
            "Build profile/environment restoration is unproven")
    original_profile = build.get("originalProfileSha256")
    require(isinstance(original_profile, str) and HEX64.fullmatch(original_profile)
            and build.get("restoredProfileSha256") == original_profile
            and isinstance(build.get("temporaryProfileSha256"), str)
            and HEX64.fullmatch(build["temporaryProfileSha256"]), "Managed entry profile identity is missing")
    require(build.get("target") == "tools/java_runtime_acceptance.dart"
            and build.get("platform") == "ohos-x64", "Wrong build target/platform")
    binding = build.get("inputBinding", {})
    require(binding.get("sourceUnchangedDuringBuild") is True, "Build input stability is unproven")
    nonce, manifest_hash = binding.get("buildNonce"), binding.get("manifestSha256")
    require(isinstance(nonce, str) and NONCE.fullmatch(nonce), "Missing/invalid fresh build nonce")
    manifest = read_json(binding["manifestPath"])
    inputs = validate_manifest(manifest, current=True)
    require(manifest.get("target") == build["target"],
            "Input manifest/build target mismatch")
    require(file_hash(pathlib.Path(manifest["roots"]["java"]) / manifest["managedEntryProfile"])
            == original_profile, "Current restored entry profile differs from its captured original")
    require(manifest["manifestSha256"] == manifest_hash, "Build/manifest association mismatch")
    native_source_hash = inputs["java/native/ets/entryability/EntryAbility.ets"]["sha256"]
    built_native = build.get("nativeOfflineBinding", {})
    require(built_native.get("sourceUnchangedDuringBuild") is True
            and built_native.get("entryAbilitySha256") == native_source_hash,
            "Build/native source association mismatch")
    hap = build.get("hap", {})
    require(hap.get("signedOutput") is True and hap_path.name.endswith("-signed.hap"),
            "The recorded signed build output is required")
    require(hap.get("abi") == "x86_64" and hap.get("bundleName") == BUNDLE,
            "Wrong recorded HAP ABI/bundle")
    require(hap.get("sha256") == file_hash(hap_path) and hap.get("bytes") == hap_path.stat().st_size,
            "HAP bytes differ from the recorded build output")
    with zipfile.ZipFile(hap_path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Repeated HAP archive entry")
        modules = [name for name in names if re.search(r"(^|/)module\.json$", name)]
        require(len(modules) == 1, "Expected one packed module.json")
        module = json.loads(archive.read(modules[0]))
        require(module.get("app", {}).get("bundleName") == BUNDLE, "Wrong actual HAP bundle")
        native = [name for name in names if re.fullmatch(r"libs/[^/]+/[^/]+\.so", name)]
        require(native and all(name.startswith("libs/x86_64/") for name in native), "Wrong native HAP ABI")
        for name in native:
            header = archive.read(name)[:20]
            require(len(header) == 20 and header[:6] == b"\x7fELF\x02\x01"
                    and int.from_bytes(header[18:20], "little") == 62, "Invalid packaged ELF64 x86_64")
        for key, row in inputs.items():
            if key.startswith("java/staged/x86_64/"):
                name = "libs/x86_64/" + key.rsplit("/", 1)[1]
                require(name in names and hashlib.sha256(archive.read(name)).hexdigest() == row["sha256"],
                        "Packaged/staged native library differs: " + name)
            elif key.startswith("java/native/resources/rawfile/jdk-x86_64."):
                asset = key.rsplit("/", 1)[1]
                matches = [name for name in names if name.endswith("/" + asset)]
                require(len(matches) == 1 and hashlib.sha256(archive.read(matches[0])).hexdigest() == row["sha256"],
                        "Packaged/staged JDK asset differs: " + asset)
    reported = runtime.get("buildBinding", {})
    require(reported.get("hasEmbeddedBinding") is True
            and reported.get("buildNonce") == nonce
            and reported.get("inputManifestSha256") == manifest_hash,
            "Runtime/build nonce or input identity mismatch")
    require(runtime.get("kind") == "java-runtime-acceptance"
            and runtime.get("status") == "complete" and runtime.get("operatingSystem") == "ohos"
            and runtime.get("expectedBundleName") == BUNDLE, "Wrong or incomplete runtime report")
    require(runtime.get("runtime", {}).get("osArch") in ("amd64", "x86_64"), "Wrong runtime ABI")
    require(runtime.get("ok") is True and runtime.get("deviceGatePassed") is True
            and runtime.get("cleanupConfirmed") is True, "Runtime acceptance did not pass")
    require(all(runtime.get(name) is True for name in (
        "diagnosticsDeviceGatePassed", "debuggerDeviceGatePassed",
        "studioDebuggerDeviceGatePassed", "nativeOfflineDeviceGatePassed")),
        "A required runtime capability gate did not pass")
    native_binding = runtime.get("nativeOffline", {}).get("sourceBinding", {})
    require(native_binding.get("verifiedCurrentNativeHapByDriver") is True
            and native_binding.get("entryAbilitySha256") == native_source_hash,
            "Native source association mismatch")
    return {"kind": "java-ohos-artifact-binding", "artifactBindingValid": True,
            "buildNonce": nonce, "inputManifestSha256": manifest_hash, "hapSha256": hap["sha256"],
            "bundleName": BUNDLE, "abi": "x86_64", "installedPackageProven": False,
            "deviceIdentityProven": False, "signatureAcceptanceProven": False,
            "requiresExternalInstallEvidence": True,
            "scope": "Local artifact association only; retain actual exact-target install/launch/pull evidence separately"}


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture")
    capture.add_argument("--repo", type=pathlib.Path, required=True)
    capture.add_argument("--target", required=True)
    capture.add_argument("--output", type=pathlib.Path, required=True)
    current = commands.add_parser("verify-inputs")
    current.add_argument("--manifest", type=pathlib.Path, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--build-report", type=pathlib.Path, required=True)
    verify.add_argument("--runtime-report", type=pathlib.Path, required=True)
    verify.add_argument("--hap", type=pathlib.Path, required=True)
    verify.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            manifest = capture_inputs(args.repo, args.target)
            write_json(args.output, manifest)
            print(json.dumps({"manifestSha256": manifest["manifestSha256"], "inputs": len(manifest["inputs"])}))
        elif args.command == "verify-inputs":
            manifest = read_json(args.manifest)
            validate_manifest(manifest, current=True)
            print(json.dumps({"sourceUnchanged": True, "manifestSha256": manifest["manifestSha256"]}))
        else:
            result = verify_artifacts(args.build_report, args.runtime_report, args.hap)
            write_json(args.output, result)
            print(json.dumps(result))
    except (BindingError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print("Artifact binding failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
