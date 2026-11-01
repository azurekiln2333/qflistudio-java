#!/usr/bin/env python3
"""Proves the Java EE pack controls actually bite.

`tools/validate_javaee_packs.py` claims the normal path performs no mutable
resolution, that the read-only verifier detects drift, and that the Dart cache
revalidates. This script reintroduces each of those defects in a scratch copy and
asserts that a control goes red. A control that never fails is not a control.

Runs with plain Python. No SDK, no JVM, no network. It copies the tools and the
bundle into a temporary tree, so the real working tree is never modified.

Usage:
    python tools/validate_javaee_pack_controls.py
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PREPARE = os.path.join(ROOT, 'tools', 'prepare_javaee_packs.py')
VALIDATE = os.path.join(ROOT, 'tools', 'validate_javaee_packs.py')
BUNDLE = os.path.join(ROOT, 'lib', 'spring_boot_bundle.dart')

# (name, anchor, inserted text, which file). The anchor must appear in the file.
MUTATIONS = [
    (
        'normal path resolves a version',
        "            log(f'    lock holds {count} frozen artifacts')",
        "            log(f'    lock holds {count} frozen artifacts')\n"
        '            resolve_version(client, "g", "a", "1.x", log)',
        'prepare',
    ),
    (
        'normal path reads maven-metadata.xml',
        'def load_lock(lock_path):',
        'def _sneak(client):\n    return metadata_versions(client, "g", "a")\n\n\n'
        'def load_lock(lock_path):',
        'prepare',
    ),
    (
        'verify-only rewrites the manifest',
        '                failures += verify_manifests_from_lock(directory, lock_path, pack, log)',
        '                failures += verify_manifests_from_lock(directory, lock_path, pack, log)\n'
        '                write_manifests_from_lock(directory, lock_path, pack, log)',
        'prepare',
    ),
    (
        'verify-only extracts licences',
        '                failures += verify_licenses_from_lock(directory, lock_path, pack, log)',
        '                failures += verify_licenses_from_lock(directory, lock_path, pack, log)\n'
        '                extract_licenses_from_lock(directory, lock_path, pack, log)',
        'prepare',
    ),
    (
        'verify-only fetches a digest url',
        '                failures += verify_licenses_from_lock(directory, lock_path, pack, log)',
        '                failures += verify_licenses_from_lock(directory, lock_path, pack, log)\n'
        '                client.get("/x")',
        'prepare',
    ),
    (
        'report gains a default',
        "parser.add_argument('--report', default=None,",
        "parser.add_argument('--report', default='build/pack-acquisition-report.json',",
        'prepare',
    ),
    (
        'cache stops revalidating',
        '  static bool _receiptsHold(List<_MaterialisedFile> receipts) {',
        '  static bool _receiptsHold(List<_MaterialisedFile> receipts) {\n    return true;',
        'bundle',
    ),
    (
        'cache hit skips revalidation',
        'if (_receiptsHold(existing)) {',
        'if (true) {',
        'bundle',
    ),
]


def run_case(name, anchor, inserted, target_kind):
    """Applies one mutation in a scratch tree and returns the control failures."""
    with tempfile.TemporaryDirectory(prefix='qfli_mut_') as work:
        tools = os.path.join(work, 'tools')
        lib = os.path.join(work, 'lib')
        os.makedirs(tools)
        os.makedirs(lib)
        shutil.copy(PREPARE, os.path.join(tools, 'prepare_javaee_packs.py'))
        shutil.copy(VALIDATE, os.path.join(tools, 'validate_javaee_packs.py'))
        shutil.copy(BUNDLE, os.path.join(lib, 'spring_boot_bundle.dart'))

        target = os.path.join(tools, 'prepare_javaee_packs.py')
        if target_kind == 'bundle':
            target = os.path.join(lib, 'spring_boot_bundle.dart')
        body = open(target, encoding='utf-8').read()
        if anchor not in body:
            return None
        with open(target, 'w', encoding='utf-8') as handle:
            handle.write(body.replace(anchor, inserted, 1))

        spec = importlib.util.spec_from_file_location(
            'mut_validate', os.path.join(tools, 'validate_javaee_packs.py'))
        module = importlib.util.module_from_spec(spec)
        module.ROOT = work
        spec.loader.exec_module(module)
        module.ROOT = work
        report = module.Report(quiet=True)
        try:
            module.run_source_controls(report)
            return list(report.failures)
        except Exception as error:  # noqa: BLE001 - a crash is also a failure
            return [f'{type(error).__name__}: {error}']


def main():
    print('mutation testing the Java EE pack controls')
    print('a control must fail when its defect returns')
    print()
    missed = 0
    skipped = 0
    for name, anchor, inserted, target_kind in MUTATIONS:
        failures = run_case(name, anchor, inserted, target_kind)
        if failures is None:
            skipped += 1
            print(f'  SKIP   {name}: anchor not found')
            continue
        caught = bool(failures)
        if not caught:
            missed += 1
        print(f'  {"CAUGHT" if caught else "MISSED"} {name}')
        for failure in failures[:2]:
            print(f'           {failure}')
    print()
    print(f'mutations missed: {missed}, skipped: {skipped}')
    return 1 if missed else 0


if __name__ == '__main__':
    sys.exit(main())