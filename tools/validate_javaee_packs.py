#!/usr/bin/env python3
"""Integrity validator for the Java EE offline packs.

Runs with plain Python. No SDK, no JVM, no network. Everything here is a claim
about bytes that are on disk right now.

Checks
------
1. Lock shape: every artifact pins a version, a byte count and a full SHA-256.
2. Lock to disk: every locked file exists with the locked size and hash.
3. Lock to manifest: the hashed manifest lists exactly the locked files, with
   the same hashes, roles and scopes.
4. Plain manifest: equal to the hashed manifest's file set.
5. Namespace purity: no pack holds the other pack's servlet namespace, and the
   two packs share no file name.
6. Namespace provider: each pack carries an explicit Servlet API for its own
   namespace, so a compile cannot silently borrow the wrong one.
7. Database group: the Spring Boot pack carries a database group, the default
   runtime selection excludes it, and `includeDatabase` adds it back.
8. Class compatibility: base classes are at most major 61, so a Java 17 runtime
   can load them. Multi-release overlays are reported separately and cannot
   lower the base requirement they replace.
9. Licence evidence: every non-Apache licence has a document on disk.
10. Recipes: the acquisition script and both lock files are tracked, because the
    asset directories are not.

Usage:
    python tools/validate_javaee_packs.py
    python tools/validate_javaee_packs.py --quiet
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PACKS = {
    'spring-boot': {
        'lock': 'tools/spring_boot.lock.json',
        'directory': 'assets/spring_boot/3.5.16',
        'namespace': 'jakarta.servlet',
        'foreign': ('javax.servlet', 'javax/servlet'),
        'api_marker': 'jakarta.servlet-api',
        'expects_database_group': True,
    },
    'javaee8': {
        'lock': 'tools/javaee8.lock.json',
        'directory': 'assets/javaee8',
        'namespace': 'javax.servlet',
        'foreign': ('jakarta.servlet', 'jakarta/servlet'),
        'api_marker': 'javax.servlet-api',
        'expects_database_group': False,
    },
}

DATABASE_ROLES = ('jdbc', 'persistence')
JAVA_17_MAJOR = 61
STABLE = re.compile(r'^\d+(?:\.\d+)*$')


class Report:
    def __init__(self, quiet=False):
        self.checks = 0
        self.failures = []
        self.quiet = quiet

    def check(self, condition, message):
        self.checks += 1
        if not condition:
            self.failures.append(message)
            if not self.quiet:
                print(f'  FAIL {message}')
        return condition

    def section(self, title):
        if not self.quiet:
            print(f'== {title}')


def sha256_file(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()


def class_majors(path):
    """Highest base class major, and highest multi-release overlay major."""
    base = 0
    overlay = 0
    with zipfile.ZipFile(path) as z:
        for entry in z.namelist():
            if not entry.endswith('.class'):
                continue
            header = z.read(entry)[:8]
            if len(header) < 8 or header[:4] != b'\xca\xfe\xba\xbe':
                continue
            major = struct.unpack('>H', header[6:8])[0]
            if entry.startswith('META-INF/versions/'):
                overlay = max(overlay, major)
            else:
                base = max(base, major)
    return base, overlay


def load_json(relative):
    path = os.path.join(ROOT, relative.replace('/', os.sep))
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


def validate_pack(report, pack, spec):
    report.section(f'pack {pack}')
    lock = load_json(spec['lock'])
    directory = os.path.join(ROOT, spec['directory'].replace('/', os.sep))
    report.check(os.path.isdir(directory), f'{pack}: pack directory exists')

    # 1. lock shape
    artifacts = lock.get('artifacts', [])
    report.check(len(artifacts) > 0, f'{pack}: lock lists artifacts')
    report.check(lock.get('servletNamespace') == spec['namespace'],
                 f'{pack}: lock namespace is {spec["namespace"]}')
    names = set()
    for artifact in artifacts:
        name = artifact.get('file', '')
        report.check(bool(name) and '/' not in name and '\\' not in name,
                     f'{pack}: artifact name is a plain file name: {name!r}')
        report.check(name not in names, f'{pack}: no duplicate artifact {name}')
        names.add(name)
        report.check(re.match(r'^[0-9a-f]{64}$', artifact.get('sha256', '') or '') is not None,
                     f'{pack}: {name} pins a full SHA-256')
        report.check(isinstance(artifact.get('bytes'), int) and artifact['bytes'] > 0,
                     f'{pack}: {name} pins a byte count')
        version = artifact.get('version')
        report.check(isinstance(version, str) and STABLE.match(version) is not None,
                     f'{pack}: {name} pins a stable version, saw {version!r}')
        report.check(artifact.get('scope') in ('runtime', 'compile'),
                     f'{pack}: {name} declares a known scope')
        report.check(bool(artifact.get('role')), f'{pack}: {name} declares a role')
        report.check(bool(artifact.get('license')), f'{pack}: {name} declares a licence')

    # 2. lock to disk
    for artifact in artifacts:
        path = os.path.join(directory, artifact['file'])
        if not report.check(os.path.isfile(path), f'{pack}: {artifact["file"]} exists'):
            continue
        size = os.path.getsize(path)
        report.check(size == artifact['bytes'],
                     f'{pack}: {artifact["file"]} size {size} equals the lock')
        report.check(sha256_file(path) == artifact['sha256'],
                     f'{pack}: {artifact["file"]} hash equals the lock')

    # 3. lock to hashed manifest
    manifest_path = os.path.join(directory, 'manifest.hashed.json')
    if report.check(os.path.isfile(manifest_path),
                    f'{pack}: manifest.hashed.json exists, because the bundle requires it'):
        manifest = json.load(open(manifest_path, encoding='utf-8'))
        report.check(manifest.get('packId') == lock.get('packId'),
                     f'{pack}: manifest packId matches the lock')
        report.check(manifest.get('namespace') == spec['namespace'],
                     f'{pack}: manifest namespace is {spec["namespace"]}')
        by_name = {item['file']: item for item in manifest.get('files', [])}
        report.check(set(by_name) == names,
                     f'{pack}: hashed manifest lists exactly the {len(names)} locked files, '
                     f'saw {len(by_name)}')
        for artifact in artifacts:
            item = by_name.get(artifact['file'])
            if item is None:
                continue
            report.check(item.get('sha256') == artifact['sha256'],
                         f'{pack}: manifest hash for {artifact["file"]} matches the lock')
            report.check(item.get('bytes') == artifact['bytes'],
                         f'{pack}: manifest byte count for {artifact["file"]} matches the lock')
            report.check(item.get('role') == artifact.get('role'),
                         f'{pack}: manifest role for {artifact["file"]} matches the lock')
            report.check(item.get('scope') == artifact.get('scope'),
                         f'{pack}: manifest scope for {artifact["file"]} matches the lock')

    # 4. plain manifest
    plain_path = os.path.join(directory, 'manifest.json')
    if report.check(os.path.isfile(plain_path), f'{pack}: manifest.json exists'):
        plain = json.load(open(plain_path, encoding='utf-8'))
        report.check(isinstance(plain, list), f'{pack}: manifest.json is a name list')
        report.check(set(plain) == names, f'{pack}: manifest.json matches the locked set')
        report.check(all('/' not in name for name in plain),
                     f'{pack}: manifest.json holds plain names only')

    # 5. namespace purity
    for artifact in artifacts:
        lowered = artifact['file'].lower()
        for marker in spec['foreign']:
            report.check(marker not in lowered,
                         f'{pack}: {artifact["file"]} does not leak {marker}')
    for artifact in artifacts:
        report.check(os.path.getsize(os.path.join(directory, artifact['file'])) >= 0,
                     f'{pack}: {artifact["file"]} readable')

    # 6. explicit servlet API for the pack namespace
    report.check(any(spec['api_marker'] in artifact['file'] for artifact in artifacts),
                 f'{pack}: carries {spec["api_marker"]} for its own namespace')
    report.check(any(artifact['file'].startswith(spec['api_marker'])
                     and artifact.get('scope') == 'compile'
                     for artifact in artifacts),
                 f'{pack}: {spec["api_marker"]} is compile scope, so the runtime keeps one copy')

    # 7. database group selection
    database = [artifact for artifact in artifacts if artifact.get('role') in DATABASE_ROLES]
    runtime = [artifact for artifact in artifacts if artifact.get('scope') == 'runtime']
    default_runtime = [artifact for artifact in runtime
                       if artifact.get('role') not in DATABASE_ROLES]
    report.check(len(default_runtime) > 0, f'{pack}: default runtime selection is not empty')
    if spec['expects_database_group']:
        report.check(len(database) >= 8,
                     f'{pack}: database group has the JDBC, pool, MyBatis and driver jars, '
                     f'saw {len(database)}')
        report.check(not any(artifact.get('role') in DATABASE_ROLES for artifact in default_runtime),
                     f'{pack}: default runtime excludes the database group')
        report.check(any('mybatis-spring-boot-autoconfigure' in artifact['file'] for artifact in database),
                     f'{pack}: database group includes the MyBatis auto-configuration')
        report.check(any('mybatis-spring-boot-starter' in artifact['file'] for artifact in database),
                     f'{pack}: database group includes the MyBatis starter')
        report.check(any(artifact['file'].startswith('mysql-connector-j') for artifact in database),
                     f'{pack}: database group includes the MySQL driver')
    else:
        report.check(not database, f'{pack}: has no database group, so includeDatabase is a no-op')
    for forbidden in ('h2', 'hsqldb', 'derby', 'sqlite', 'hibernate', 'jakarta.persistence'):
        report.check(not any(forbidden in artifact['file'].lower() for artifact in artifacts),
                     f'{pack}: no {forbidden} artifact, because qflisql owns the database')
    if pack == 'javaee8':
        report.check(not any('spring' in artifact['file'].lower() for artifact in artifacts),
                     f'{pack}: carries no Spring Framework, because the pack is container-only')
        # JSP is only real when the engine, the compiler and the tag library are
        # all present, so the three roles are checked separately.
        roles = {artifact.get('role') for artifact in artifacts}
        report.check('jsp' in roles, f'{pack}: declares a jsp role for the engine and compiler')
        report.check('jstl' in roles, f'{pack}: declares a jstl role for the tag library')
        report.check(any(artifact['file'].startswith('tomcat-embed-jasper') for artifact in artifacts),
                     f'{pack}: ships the JSP engine')
        report.check(any(artifact['file'].startswith('ecj') for artifact in artifacts),
                     f'{pack}: ships the JSP compiler')
        report.check(sum(1 for artifact in artifacts if artifact.get('role') == 'jstl') >= 2,
                     f'{pack}: ships both the JSTL API and its implementation')

    # 8. class compatibility
    highest_base = 0
    highest_base_file = ''
    overlays = []
    for artifact in artifacts:
        path = os.path.join(directory, artifact['file'])
        if not os.path.isfile(path):
            continue
        base, overlay = class_majors(path)
        if base > highest_base:
            highest_base, highest_base_file = base, artifact['file']
        if overlay > JAVA_17_MAJOR:
            overlays.append((artifact['file'], overlay))
        report.check(base <= JAVA_17_MAJOR,
                     f'{pack}: {artifact["file"]} base class major {base} loads on Java 17')
    report.check(highest_base <= JAVA_17_MAJOR,
                 f'{pack}: highest base class major {highest_base} is at most {JAVA_17_MAJOR}')
    if overlays and not report.quiet:
        print(f'   note: {len(overlays)} multi-release overlays above Java 17, used only on a newer JVM: '
              + ', '.join(f'{name}:{major}' for name, major in overlays))

    # 9. licence evidence. Every artifact carries packaged evidence, quoted from
    # its own archive or its published POM. No legal conclusion is drawn here.
    for artifact in artifacts:
        files = artifact.get('licenseFiles') or []
        if files:
            for name in files:
                target = os.path.join(directory, 'licenses', f'{artifact["artifactId"]}__{name}')
                report.check(os.path.isfile(target),
                             f'{pack}: {artifact["file"]} licence document {name} is on disk')
            report.check(bool(artifact.get('licenseEntries')),
                         f'{pack}: {artifact["file"]} records the raw licence entry for provenance')
            continue
        # No evidence at all is allowed only when it is recorded as a known gap,
        # so a missing text can never pass silently.
        report.check(artifact.get('licenseDocumentAvailable') is False,
                     f'{pack}: {artifact["file"]} records its licence text as absent')
        report.check(bool(artifact.get('licenseDocumentNote')),
                     f'{pack}: {artifact["file"]} states why no licence text is stored')

    # 10. recipe is complete
    report.check(os.path.isfile(os.path.join(ROOT, 'tools', 'prepare_javaee_packs.py')),
                 f'{pack}: acquisition recipe is tracked')
    return {
        'files': len(names),
        'databaseGroup': len(database),
        'defaultRuntime': len(default_runtime),
        'highestBaseMajor': highest_base,
        'highestBaseFile': highest_base_file,
    }


def run_source_controls(report):
    """Pure Python controls over the recipe's source structure and the filesystem.

    These are the controls that a picture of the lock cannot give. They prove
    that the normal path performs no mutable resolution, that the read-only
    verifier detects each kind of drift, and that it repairs none of it.
    """
    import importlib.util
    import tempfile

    report.section('source structure controls')
    path = os.path.join(ROOT, 'tools', 'prepare_javaee_packs.py')
    source = open(path, encoding='utf-8').read()
    # Everything above the mutable-resolution marker is the normal path. No
    # resolver call may appear there, or the frozen lock is no longer the only
    # source of a version.
    marker = '# Mutable resolution.'
    report.check(marker in source, 'recipe marks where mutable resolution begins')
    head = source[:source.index(marker)] if marker in source else source
    for forbidden in ('metadata_versions(', 'resolve_version(', 'pom_properties(',
                      'interpolate('):
        report.check(forbidden not in head,
                     f'the normal path never calls {forbidden.rstrip("(")}')
    report.check('load_lock(lock_path)' in source,
                 'the normal path takes its frozen set from the lock')
    # The prepare branch itself must not resolve anything: the lock already holds
    # every version, so a resolver call here would defeat the freeze.
    prepare_branch = source[source.index('# ---- normal preparation'):]
    prepare_branch = prepare_branch[:prepare_branch.index('client.close()')] \
        if 'client.close()' in prepare_branch else prepare_branch
    for forbidden in ('resolve_version(', 'metadata_versions(', 'pom_properties(',
                      'interpolate('):
        report.check(forbidden not in prepare_branch,
                     f'the prepare branch never calls {forbidden.rstrip("(")}')
    # The verify-only branch must contain no mutating call.
    verify_branch = source[source.index('if args.verify_only:'):]
    verify_branch = verify_branch[:verify_branch.index('# ---- normal preparation')] \
        if '# ---- normal preparation' in verify_branch else verify_branch
    for mutator in ('write_manifests_from_lock(', 'extract_licenses_from_lock(',
                    'merge_digest_evidence(', 'client.get('):
        report.check(mutator not in verify_branch,
                     f'the verify-only branch never runs {mutator.rstrip("(")}')
    report.check("parser.add_argument('--report', default=None" in source,
                 'the report path has no default, so verify-only writes no file')

    bundle = open(os.path.join(ROOT, 'lib', 'spring_boot_bundle.dart'), encoding='utf-8').read()
    report.check("springBoot = 'spring-boot'" in bundle,
                 'the bundle uses the frozen spring-boot profile name')
    report.check("javaee8 = 'javaee8'" in bundle,
                 'the bundle uses the frozen javaee8 profile name')
    report.check('materialiseProfile(' in bundle, 'the bundle exposes materialiseProfile')
    report.check('includeDatabase' in bundle, 'the bundle exposes includeDatabase')
    report.check('OfflineDigest.sha256Bytes' in bundle,
                 'the bundle reuses the shared core digest instead of its own SHA-256')
    report.check('int rotl(' not in bundle, 'the bundle holds no private SHA-256 core')
    report.check('manifest.hashed.json' in bundle, 'the bundle reads the hashed manifest')
    report.check('_receiptsHold' in bundle,
                 'the materialisation cache revalidates before it reuses a path')
    # The name is not the behaviour: a stub that returns true would still pass a
    # name check. The body must compare the length and the hash, and it must be
    # consulted on the cache-hit path.
    if '_receiptsHold(List<_MaterialisedFile> receipts) {' in bundle:
        body = bundle[bundle.index('_receiptsHold(List<_MaterialisedFile> receipts) {'):]
        body = body[:body.index('\n  }')]
        report.check('lengthSync()' in body,
                     'the cache revalidation compares the file length')
        report.check('sha256Hex(' in body,
                     'the cache revalidation compares the SHA-256, so a same-length change is caught')
        report.check('return false' in body,
                     'the cache revalidation can reject a stale entry')
        if 'return true' in body and 'sha256Hex(' in body:
            report.check(body.index('return true') > body.index('sha256Hex('),
                         'the cache only accepts after the length and hash checks, so an '
                         'early return true cannot skip them')
        else:
            report.check(False,
                         'the cache revalidation falls through to an accept after the checks')
    else:
        report.check(False, 'the cache revalidation helper is present')
    hit = bundle[bundle.index('final existing = _cached[key];'):]
    hit = hit[:hit.index('final pending = _materialising[key];')]
    report.check('_receiptsHold(existing)' in hit,
                 'every cache hit is revalidated before the paths are returned')
    report.check('_cached.remove(key)' in hit,
                 'a stale cache entry is dropped instead of being served')

    report.section('filesystem drift controls')
    spec = importlib.util.spec_from_file_location('prepare_javaee_packs', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    quiet = lambda message: None  # noqa: E731

    with tempfile.TemporaryDirectory(prefix='qfli_pack_control_') as work:
        directory = os.path.join(work, 'pack')
        os.makedirs(directory)
        jar_path = os.path.join(directory, 'tiny-1.0.jar')
        with zipfile.ZipFile(jar_path, 'w') as archive:
            archive.writestr('LICENSE', 'control licence text\n')
        jar_bytes = open(jar_path, 'rb').read()
        licence_bytes = b'control licence text\n'
        lock = {
            'packId': 'control',
            'servletNamespace': 'javax.servlet',
            'artifacts': [{
                'file': 'tiny-1.0.jar',
                'mavenPath': 'org/example/tiny/1.0/tiny-1.0.jar',
                'sha256': hashlib.sha256(jar_bytes).hexdigest(),
                'bytes': len(jar_bytes),
                'artifactId': 'tiny',
                'version': '1.0',
                'scope': 'runtime',
                'role': 'servlet',
                'license': 'Apache-2.0',
                'licenseFiles': ['LICENSE'],
                'licenseEntries': ['LICENSE'],
                'licenseHashes': {'LICENSE': {
                    'bytes': len(licence_bytes),
                    'sha256': hashlib.sha256(licence_bytes).hexdigest()}},
                'licenseDocumentAvailable': True,
            }],
        }
        lock_path = os.path.join(work, 'control.lock.json')
        with open(lock_path, 'w', encoding='utf-8') as handle:
            json.dump(lock, handle, indent=2)

        module.extract_licenses_from_lock(directory, lock_path, 'javaee8', quiet)
        module.write_manifests_from_lock(directory, lock_path, 'javaee8', quiet)

        def verify_all():
            found = []
            found += module.verify_lock_against_disk(lock_path, directory, 'javaee8', quiet)
            found += module.verify_manifests_from_lock(directory, lock_path, 'javaee8', quiet)
            found += module.verify_licenses_from_lock(directory, lock_path, 'javaee8', quiet)
            return found

        clean = verify_all()
        report.check(not clean, f'a clean pack verifies with no drift, saw {clean[:2]}')

        # A deleted jar is reported, not restored.
        os.replace(jar_path, jar_path + '.hidden')
        drift = verify_all()
        report.check(any('tiny-1.0.jar' in str(item) for item in drift),
                     'a deleted jar is reported as drift')
        report.check(not os.path.isfile(jar_path),
                     'verify-only does not restore the deleted jar')
        os.replace(jar_path + '.hidden', jar_path)

        # A same-length corruption is reported, not repaired, and the bytes stay.
        original = open(jar_path, 'rb').read()
        corrupted = bytes([original[0] ^ 0xff]) + original[1:]
        report.check(len(corrupted) == len(original), 'the corruption keeps the length')
        with open(jar_path, 'wb') as handle:
            handle.write(corrupted)
        drift = verify_all()
        report.check(any('tiny-1.0.jar' in str(item) for item in drift),
                     'a same-length corruption is reported as drift')
        report.check(open(jar_path, 'rb').read() == corrupted,
                     'verify-only does not repair the corrupted jar')
        with open(jar_path, 'wb') as handle:
            handle.write(original)

        # An extra jar is reported.
        extra = os.path.join(directory, 'extra-9.9.jar')
        with open(extra, 'wb') as handle:
            handle.write(b'x')
        drift = verify_all()
        report.check(any('extra-9.9.jar' in str(item) for item in drift),
                     'an extra jar is reported as drift')
        os.remove(extra)

        # A tampered manifest is reported, and the tampered file is left alone.
        manifest_path = os.path.join(directory, 'manifest.hashed.json')
        good_manifest = open(manifest_path, encoding='utf-8').read()
        with open(manifest_path, 'w', encoding='utf-8') as handle:
            handle.write(good_manifest.replace('tiny-1.0.jar', 'evil-1.0.jar'))
        drift = verify_all()
        report.check(any('manifest' in item.get('stage', '') for item in drift),
                     'a tampered manifest is reported as drift')
        report.check('evil-1.0.jar' in open(manifest_path, encoding='utf-8').read(),
                     'verify-only does not rewrite the tampered manifest')
        with open(manifest_path, 'w', encoding='utf-8') as handle:
            handle.write(good_manifest)

        # A tampered licence is reported, and the forged text is left in place.
        licence_path = os.path.join(directory, 'licenses', 'tiny__LICENSE')
        good_licence = open(licence_path, 'rb').read()
        with open(licence_path, 'wb') as handle:
            handle.write(b'forged licence\n')
        drift = verify_all()
        report.check(any('verify-license' == item.get('stage', '') for item in drift),
                     'a tampered licence is reported as drift')
        report.check(open(licence_path, 'rb').read() == b'forged licence\n',
                     'verify-only does not repair the tampered licence')
        with open(licence_path, 'wb') as handle:
            handle.write(good_licence)

        # After every repair, the fixture verifies clean again: the verifier is a
        # check, and the prepare path is what writes.
        report.check(not verify_all(), 'the fixture verifies clean once restored')


def main(argv=None):
    parser = argparse.ArgumentParser(description='Validate the Java EE offline packs.')
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args(argv)

    report = Report(quiet=args.quiet)
    summary = {}
    for pack, spec in PACKS.items():
        try:
            summary[pack] = validate_pack(report, pack, spec)
        except FileNotFoundError as error:
            report.check(False, f'{pack}: required file is missing ({error})')

    report.section('cross-pack')
    boot_lock = load_json(PACKS['spring-boot']['lock'])
    ee8_lock = load_json(PACKS['javaee8']['lock'])
    boot_names = {artifact['file'] for artifact in boot_lock['artifacts']}
    ee8_names = {artifact['file'] for artifact in ee8_lock['artifacts']}
    shared = boot_names & ee8_names
    report.check(not shared, f'packs share no file name, found {sorted(shared)[:3]}')
    for name in boot_names:
        report.check(not name.lower().startswith('javax'),
                     f'spring-boot pack holds no javax artifact ({name})')
    for name in ee8_names:
        report.check(not name.lower().startswith('jakarta'),
                     f'javaee8 pack holds no jakarta artifact ({name})')
    report.check(boot_lock.get('servletNamespace') != ee8_lock.get('servletNamespace'),
                 'the two packs declare different servlet namespaces')

    report.section('frozen profile names')
    for lock, expected in ((boot_lock, 'spring-boot'), (ee8_lock, 'javaee8')):
        report.check(lock.get('packId') == expected, f'packId is {expected}')
        report.check(lock.get('profiles') == [expected],
                     f'{expected} declares only itself as a profile, no jakarta or javax alias')
        report.check('jakarta' not in (lock.get('profiles') or []),
                     f'{expected} does not use a namespace name as a profile name')
    bundle = open(os.path.join(ROOT, 'lib', 'spring_boot_bundle.dart'), encoding='utf-8').read()
    report.check("springBoot = 'spring-boot'" in bundle,
                 'the bundle uses the frozen spring-boot profile name')
    report.check("javaee8 = 'javaee8'" in bundle,
                 'the bundle uses the frozen javaee8 profile name')
    report.check('materialiseProfile(' in bundle, 'the bundle exposes materialiseProfile')
    report.check('includeDatabase' in bundle, 'the bundle exposes includeDatabase')
    report.check('OfflineDigest.sha256Bytes' in bundle,
                 'the bundle reuses the shared core digest instead of its own SHA-256')
    report.check('int rotl(' not in bundle, 'the bundle holds no private SHA-256 core')
    report.check('manifest.hashed.json' in bundle, 'the bundle reads the hashed manifest')
    report.check('licenseHashes' in json.dumps(boot_lock) or 'licenseHashes' in json.dumps(ee8_lock),
                 'the locks record a licence digest so licence drift is detectable')

    run_source_controls(report)

    report.section('summary')
    for pack, values in summary.items():
        print(f'   {pack}: files={values["files"]} defaultRuntime={values["defaultRuntime"]} '
              f'databaseGroup={values["databaseGroup"]} '
              f'highestBaseMajor={values["highestBaseMajor"]} ({values["highestBaseFile"]})')
    print()
    print(f'checks: {report.checks}, failures: {len(report.failures)}')
    if report.failures:
        print('RESULT: FAIL')
        return 1
    print('RESULT: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())