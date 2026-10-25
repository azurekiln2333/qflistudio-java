"""Pure local artifact controls; no SDK, compiler, build or device commands."""
from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
import verify_java_ohos_binding as binding


class ArtifactBindingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="qfli_java_hap_binding_")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.repo = self.root / "java"
        # Deliberately not the conventional sibling name: resolved config owns
        # the dependency, so an accidental hard-coded core path is detectable.
        self.core = self.root / "actual-local-dependency"
        self.vendor = self.core / "vendor/re_editor"
        self.asset_only = self.root / "asset-only-package"
        (self.asset_only / "assets").mkdir(parents=True)
        (self.asset_only / "assets/icon.ttf").write_bytes(b"fixture-font")
        for directory in (self.repo, self.core, self.vendor):
            (directory / "lib").mkdir(parents=True)
            (directory / "lib/source.dart").write_text("const value = 1;\n", encoding="utf-8")
            (directory / "pubspec.yaml").write_text("name: fixture\n", encoding="utf-8")
        self.write("tools/java_runtime_acceptance.dart", "void main() {}\n")
        self.write("tools/build_ohos_audit.ps1", "# fixture only\n")
        self.write("ohos/entry/build-profile.json5", "original fixture profile\n")
        self.write("ohos/entry/src/main/ets/entryability/EntryAbility.ets", "// local offline entry\n")
        self.write("ohos/entry/src/main/module.json5", "{}\n")
        self.write("ohos/entry/src/main/resources/base/profile/main_pages.json", '{"src":["pages/Index"]}\n')
        self.write("ohos/entry/src/main/resources/rawfile/jdk-x86_64.json", b'{"version":1}')
        self.write("ohos/entry/src/main/resources/rawfile/jdk-x86_64.zip", b"fixture-jdk-data")
        self.native = bytearray(b"\x7fELF\x02\x01" + b"\0" * 14)
        self.native[18:20] = (62).to_bytes(2, "little")
        self.write("ohos/entry/libs/x86_64/libqfli_java.so", bytes(self.native))
        (self.vendor / "ohos/src/main/ets").mkdir(parents=True)
        (self.vendor / "ohos/src/main/ets/Plugin.ets").write_text("// plugin\n", encoding="utf-8")
        self.write(".dart_tool/package_config.json", json.dumps({"configVersion": 2, "packages": [
            {"name": "qfli_java", "rootUri": "../", "packageUri": "lib/"},
            {"name": "qfli_studio_core", "rootUri": self.core.as_uri(), "packageUri": "lib/"},
            {"name": "re_editor", "rootUri": self.vendor.as_uri(), "packageUri": "lib/"},
            {"name": "asset_only", "rootUri": self.asset_only.as_uri(), "packageUri": "lib/"},
        ]}))
        self.manifest = binding.capture_inputs(self.repo, "tools/java_runtime_acceptance.dart")
        self.manifest_path = self.root / "inputs.json"
        binding.write_json(self.manifest_path, self.manifest)
        self.entries = {
            "module.json": json.dumps({"app": {"bundleName": binding.BUNDLE}}).encode(),
            "libs/x86_64/libqfli_java.so": bytes(self.native),
            "resources/rawfile/jdk-x86_64.json": b'{"version":1}',
            "resources/rawfile/jdk-x86_64.zip": b"fixture-jdk-data",
        }
        self.hap = self.root / "entry-default-signed.hap"
        self.repack()
        profile = binding.file_hash(self.repo / "ohos/entry/build-profile.json5")
        source = next(row["sha256"] for row in self.manifest["inputs"]
                      if row["key"] == "java/native/ets/entryability/EntryAbility.ets")
        self.build = {
            "buildExitCode": 0, "error": None, "profileRestored": True,
            "environmentRestored": True, "originalProfileSha256": profile,
            "restoredProfileSha256": profile,
            "temporaryProfileSha256": hashlib.sha256(b"temporary fixture profile").hexdigest(),
            "target": "tools/java_runtime_acceptance.dart", "platform": "ohos-x64",
            "inputBinding": {"buildNonce": "a" * 32, "manifestPath": str(self.manifest_path),
                             "manifestSha256": self.manifest["manifestSha256"],
                             "sourceUnchangedDuringBuild": True},
            "nativeOfflineBinding": {"sourceUnchangedDuringBuild": True, "entryAbilitySha256": source},
            "hap": {"sha256": binding.file_hash(self.hap), "bytes": self.hap.stat().st_size,
                    "signedOutput": True, "abi": "x86_64", "bundleName": binding.BUNDLE},
        }
        self.runtime = {
            "kind": "java-runtime-acceptance", "status": "complete", "operatingSystem": "ohos",
            "expectedBundleName": binding.BUNDLE, "runtime": {"osArch": "amd64"},
            "buildBinding": {"hasEmbeddedBinding": True, "buildNonce": "a" * 32,
                             "inputManifestSha256": self.manifest["manifestSha256"]},
            "nativeOffline": {"sourceBinding": {"verifiedCurrentNativeHapByDriver": True,
                                                "entryAbilitySha256": source}},
            "ok": True, "deviceGatePassed": True, "cleanupConfirmed": True,
            "diagnosticsDeviceGatePassed": True, "debuggerDeviceGatePassed": True,
            "studioDebuggerDeviceGatePassed": True, "nativeOfflineDeviceGatePassed": True,
        }

    def write(self, relative, value):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else value.encode())
        return path

    def repack(self):
        with zipfile.ZipFile(self.hap, "w") as archive:
            for name, value in self.entries.items():
                archive.writestr(name, value)
        if hasattr(self, "build"):
            self.build["hap"].update(sha256=binding.file_hash(self.hap), bytes=self.hap.stat().st_size)

    def verify(self):
        build, runtime = self.root / "build.json", self.root / "runtime.json"
        binding.write_json(build, self.build)
        binding.write_json(runtime, self.runtime)
        return binding.verify_artifacts(build, runtime, self.hap)

    def reject(self, text):
        with self.assertRaisesRegex(binding.BindingError, text):
            self.verify()

    def test_valid_association_never_claims_install_or_signature_acceptance(self):
        result = self.verify()
        self.assertTrue(result["artifactBindingValid"])
        self.assertFalse(result["installedPackageProven"])
        self.assertFalse(result["deviceIdentityProven"])
        self.assertFalse(result["signatureAcceptanceProven"])
        self.assertTrue(result["requiresExternalInstallEvidence"])
        self.assertEqual(self.manifest["roots"]["package:qfli_studio_core"], str(self.core.resolve()))
        self.assertIn("package/re_editor/lib/source.dart", {row["key"] for row in self.manifest["inputs"]})
        self.assertIn("package/asset_only/assets/icon.ttf", {row["key"] for row in self.manifest["inputs"]})

    def test_asset_only_package_bytes_are_checked(self):
        (self.asset_only / "assets/icon.ttf").write_bytes(b"other-font")
        self.reject("Current build input set or bytes")

    def test_native_plugin_source_bytes_are_checked(self):
        (self.vendor / "ohos/src/main/ets/Plugin.ets").write_text("// changed\n", encoding="utf-8")
        self.reject("Current build input set or bytes")

    def test_stale_runtime_nonce_is_rejected(self):
        self.runtime["buildBinding"]["buildNonce"] = "c" * 32
        self.reject("nonce or input identity")

    def test_runtime_manifest_mismatch_is_rejected(self):
        self.runtime["buildBinding"]["inputManifestSha256"] = "c" * 64
        self.reject("nonce or input identity")

    def test_manifest_for_another_entry_cannot_bind_the_runtime_build(self):
        self.manifest = binding.capture_inputs(self.repo, "lib/source.dart")
        binding.write_json(self.manifest_path, self.manifest)
        self.build["inputBinding"]["manifestSha256"] = self.manifest["manifestSha256"]
        self.runtime["buildBinding"]["inputManifestSha256"] = self.manifest["manifestSha256"]
        self.reject("Input manifest/build target mismatch")

    def test_target_outside_the_java_repository_is_rejected(self):
        with self.assertRaisesRegex(binding.BindingError, "target must be a Dart entry inside"):
            binding.capture_inputs(self.repo, self.core / "lib/source.dart")

    def test_remote_package_root_is_rejected(self):
        config_path = self.repo / ".dart_tool/package_config.json"
        config = binding.read_json(config_path)
        config["packages"][1]["rootUri"] = "https://example.invalid/package/"
        binding.write_json(config_path, config)
        with self.assertRaisesRegex(binding.BindingError, "must resolve to a local file URI"):
            binding.capture_inputs(self.repo, "tools/java_runtime_acceptance.dart")

    def test_package_library_outside_its_root_is_rejected(self):
        config_path = self.repo / ".dart_tool/package_config.json"
        config = binding.read_json(config_path)
        config["packages"][1]["packageUri"] = "../java/lib/"
        binding.write_json(config_path, config)
        with self.assertRaisesRegex(binding.BindingError, "Package library escapes its package root"):
            binding.capture_inputs(self.repo, "tools/java_runtime_acceptance.dart")

    def test_unbound_runtime_is_rejected(self):
        self.runtime["buildBinding"] = {}
        self.reject("nonce or input identity")

    def test_hap_file_tamper_is_rejected(self):
        self.hap.write_bytes(self.hap.read_bytes() + b"tamper")
        self.reject("HAP bytes")

    def test_same_abi_native_replacement_is_rejected_after_hap_hash_refresh(self):
        self.entries["libs/x86_64/libqfli_java.so"] += b"wrong-build"
        self.repack()
        self.reject("Packaged/staged native library")

    def test_wrong_actual_bundle_is_rejected(self):
        self.entries["module.json"] = b'{"app":{"bundleName":"wrong.bundle"}}'
        self.repack()
        self.reject("Wrong actual HAP bundle")

    def test_wrong_elf_machine_is_rejected(self):
        self.native[18:20] = (183).to_bytes(2, "little")
        self.entries["libs/x86_64/libqfli_java.so"] = bytes(self.native)
        self.repack()
        self.reject("Invalid packaged ELF64")

    def test_jdk_asset_replacement_is_rejected(self):
        self.entries["resources/rawfile/jdk-x86_64.zip"] = b"other-jdk"
        self.repack()
        self.reject("Packaged/staged JDK asset")

    def test_changed_java_source_is_rejected(self):
        self.write("lib/source.dart", "const value = 2;\n")
        self.reject("Current build input set or bytes")

    def test_new_core_source_is_rejected(self):
        (self.core / "lib/new_source.dart").write_text("// new source\n", encoding="utf-8")
        self.reject("Current build input set or bytes")

    def test_removed_input_cannot_be_hidden_by_rehashing_manifest(self):
        self.manifest["inputs"] = [row for row in self.manifest["inputs"]
                                   if row["key"] != "package/re_editor/lib/source.dart"]
        payload = {key: value for key, value in self.manifest.items() if key != "manifestSha256"}
        self.manifest["manifestSha256"] = binding.canonical_hash(payload)
        binding.write_json(self.manifest_path, self.manifest)
        self.build["inputBinding"]["manifestSha256"] = self.manifest["manifestSha256"]
        self.runtime["buildBinding"]["inputManifestSha256"] = self.manifest["manifestSha256"]
        self.reject("Current build input set or bytes")

    def test_failed_build_and_unrestored_environment_are_rejected(self):
        for field, value, message in [("buildExitCode", 1, "build did not complete"),
                                      ("profileRestored", False, "restoration is unproven"),
                                      ("environmentRestored", False, "restoration is unproven")]:
            original = copy.deepcopy(self.build)
            with self.subTest(field=field):
                self.build[field] = value
                self.reject(message)
            self.build = original

    def test_restored_profile_bytes_are_checked_separately(self):
        self.write("ohos/entry/build-profile.json5", "changed profile\n")
        self.reject("Current restored entry profile")

    def test_host_and_incomplete_runtime_are_rejected(self):
        for field, value in [("operatingSystem", "windows"), ("status", "running")]:
            original = copy.deepcopy(self.runtime)
            with self.subTest(field=field):
                self.runtime[field] = value
                self.reject("Wrong or incomplete runtime report")
            self.runtime = original

    def test_runtime_gate_failure_is_not_hidden_by_overall_success(self):
        self.runtime["studioDebuggerDeviceGatePassed"] = False
        self.reject("required runtime capability gate")

    def test_native_source_mismatch_is_rejected(self):
        self.runtime["nativeOffline"]["sourceBinding"]["entryAbilitySha256"] = "c" * 64
        self.reject("Native source association")

    def test_build_native_source_mismatch_is_rejected(self):
        self.build["nativeOfflineBinding"]["entryAbilitySha256"] = "c" * 64
        self.reject("Build/native source association")


if __name__ == "__main__":
    unittest.main()
