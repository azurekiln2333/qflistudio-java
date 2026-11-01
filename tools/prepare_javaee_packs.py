#!/usr/bin/env python3
"""Materialise the Java EE offline packs from frozen lock files.

The lock file is the only source of truth. Normal preparation reconstructs
exactly the artifacts the lock names and nothing else:

- No version is ever resolved in the normal path. Every version, every
  ``mavenPath`` and every SHA-256 comes from the lock, so two runs a year apart
  produce the same bytes.
- No ``maven-metadata.xml`` is read in the normal path, and no parent POM is
  walked. Mutable resolution lives only behind the explicit ``--refresh``
  operation, which writes a *candidate* lock for review and never touches the
  live lock.
- ``--verify-only`` is strictly read-only. It fetches nothing, rewrites no
  manifest, licence or lock, and reports drift instead of repairing it.

Design rules, all enforced here:

- No resolver, no build, no JVM, no Maven, no Gradle. Only HTTP GET.
- Every request has a socket timeout. The whole run has a foreground budget.
- Each artifact is checked against its published ``.sha1`` and then hashed with
  SHA-256. A mismatch aborts that artifact and leaves no partial file.
- Two packs, two directories. This script does not enforce the namespace split:
  it takes every ``mavenPath`` from the lock, and it stamps the lock's single
  ``namespace`` value on every manifest entry. Namespace purity is checked after
  the fact by ``tools/validate_javaee_packs.py``, which refuses a pack holding the
  other namespace, a cross-namespace provider, or a file name shared by the two
  packs. ``FOREIGN_NAMESPACE_MARKERS`` and ``looks_foreign`` remain here as an
  unused guard, so the check is not a refusal before the fetch.

Usage:
    python tools/prepare_javaee_packs.py --packs all
    python tools/prepare_javaee_packs.py --packs javaee8 --verify-only
    python tools/prepare_javaee_packs.py --packs all --refresh
    python tools/prepare_javaee_packs.py --packs all --report build/packs.json
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY_HOST = 'repo1.maven.org'
REPOSITORY_ROOT = '/maven2'
REQUEST_TIMEOUT = 15.0
DEFAULT_BUDGET = 85.0

PACK_DIRECTORIES = {
    'spring-boot': 'assets/spring_boot/3.5.16',
    'javaee8': 'assets/javaee8',
}

LOCK_FILES = {
    'spring-boot': 'tools/spring_boot.lock.json',
    'javaee8': 'tools/javaee8.lock.json',
}

# Namespace token each pack may contain. A file from the other namespace is
# refused, because a mixed classpath fails at run time, not at compile time.
PACK_NAMESPACE = {
    'spring-boot': 'jakarta.servlet',
    'javaee8': 'javax.servlet',
}
FOREIGN_NAMESPACE_MARKERS = {
    'spring-boot': ('javax.servlet', 'javax/servlet', 'tomcat-embed-core-9.', 'ecj-'),
    'javaee8': ('jakarta.servlet', 'jakarta/servlet', 'tomcat-embed-core-10.'),
}

# The seed plan for the explicit ``--refresh`` operation only. The normal path
# never reads it. A row is (pack, groupId, artifactId, version or None,
# versionHint, scope, role, license). A None version means "resolve the newest
# stable release matching the hint", which is exactly the mutable behaviour that
# the normal path must avoid, so it is confined to refresh.
SEED_PLAN = [
    # ---- spring-boot: JSON ------------------------------------------------
    ('spring-boot', 'com.fasterxml.jackson.core', 'jackson-databind', '2.21.4', None, 'runtime', 'json', 'Apache-2.0'),
    ('spring-boot', 'com.fasterxml.jackson.core', 'jackson-core', '2.21.4', None, 'runtime', 'json', 'Apache-2.0'),
    ('spring-boot', 'com.fasterxml.jackson.core', 'jackson-annotations', '2.21', None, 'runtime', 'json', 'Apache-2.0'),
    ('spring-boot', 'com.fasterxml.jackson.datatype', 'jackson-datatype-jdk8', '2.21.4', None, 'runtime', 'json', 'Apache-2.0'),
    ('spring-boot', 'com.fasterxml.jackson.datatype', 'jackson-datatype-jsr310', '2.21.4', None, 'runtime', 'json', 'Apache-2.0'),
    ('spring-boot', 'com.fasterxml.jackson.module', 'jackson-module-parameter-names', '2.21.4', None, 'runtime', 'json', 'Apache-2.0'),
    # ---- spring-boot: JDBC -----------------------------------------------
    ('spring-boot', 'org.springframework', 'spring-jdbc', '6.2.19', None, 'runtime', 'jdbc', 'Apache-2.0'),
    ('spring-boot', 'org.springframework', 'spring-tx', '6.2.19', None, 'runtime', 'jdbc', 'Apache-2.0'),
    ('spring-boot', 'com.zaxxer', 'HikariCP', '6.3.3', None, 'runtime', 'jdbc', 'Apache-2.0'),
    # ---- spring-boot: MyBatis, annotation mapper support -----------------
    ('spring-boot', 'org.mybatis.spring.boot', 'mybatis-spring-boot-starter', None, '3.0.x', 'runtime', 'persistence', 'Apache-2.0'),
    ('spring-boot', 'org.mybatis.spring.boot', 'mybatis-spring-boot-autoconfigure', None, '3.0.x', 'runtime', 'persistence', 'Apache-2.0'),
    ('spring-boot', 'org.mybatis', 'mybatis', None, '3.5.x', 'runtime', 'persistence', 'Apache-2.0'),
    ('spring-boot', 'org.mybatis', 'mybatis-spring', None, '3.0.x', 'runtime', 'persistence', 'Apache-2.0'),
    # ---- spring-boot: database driver for qflisql ------------------------
    ('spring-boot', 'com.mysql', 'mysql-connector-j', '9.7.0', None, 'runtime', 'jdbc', 'GPL-2.0-with-classpath-exception'),
    # ---- spring-boot: Servlet 6 API for javac ----------------------------
    ('spring-boot', 'jakarta.servlet', 'jakarta.servlet-api', '6.0.0', None, 'compile', 'servlet', 'EPL-2.0 OR GPL-2.0-with-classpath-exception'),
    # ---- javaee8: Tomcat 9 container, javax namespace --------------------
    ('javaee8', 'org.apache.tomcat.embed', 'tomcat-embed-core', None, '9.0.x', 'runtime', 'servlet', 'Apache-2.0'),
    ('javaee8', 'org.apache.tomcat.embed', 'tomcat-embed-el', None, '9.0.x', 'runtime', 'servlet', 'Apache-2.0'),
    ('javaee8', 'org.apache.tomcat.embed', 'tomcat-embed-jasper', None, '9.0.x', 'runtime', 'jsp', 'Apache-2.0'),
    ('javaee8', 'org.apache.tomcat', 'tomcat-annotations-api', None, '9.0.x', 'runtime', 'servlet', 'Apache-2.0'),
    # ---- javaee8: JSP compiler -------------------------------------------
    ('javaee8', 'org.eclipse.jdt', 'ecj', None, '3.', 'runtime', 'jsp', 'EPL-2.0'),
    # ---- javaee8: javax APIs for javac -----------------------------------
    ('javaee8', 'javax.servlet', 'javax.servlet-api', '4.0.1', None, 'compile', 'servlet', 'CDDL-1.0 OR GPL-2.0-with-classpath-exception'),
    ('javaee8', 'javax.servlet.jsp', 'javax.servlet.jsp-api', '2.3.3', None, 'compile', 'jsp', 'CDDL-1.0 OR GPL-2.0-with-classpath-exception'),
    # ---- javaee8: javax JSTL API and implementation ----------------------
    ('javaee8', 'javax.servlet.jsp.jstl', 'javax.servlet.jsp.jstl-api', '1.2.2', None, 'runtime', 'jstl', 'CDDL-1.0 OR GPL-2.0-with-classpath-exception'),
    ('javaee8', 'org.glassfish.web', 'javax.servlet.jsp.jstl', '1.2.5', None, 'runtime', 'jstl', 'CDDL-1.0 OR GPL-2.0-with-classpath-exception'),
]


class Budget:
    """Foreground time budget shared by every request."""

    def __init__(self, seconds):
        self.deadline = time.monotonic() + seconds

    def left(self):
        return self.deadline - time.monotonic()

    def expired(self):
        return self.left() <= 0


class Client:
    """One reused TLS connection. Reconnect is cheap but not free."""

    def __init__(self, budget):
        self.budget = budget
        self.connection = None
        self.requests = 0
        self.bytes = 0

    def _connect(self):
        context = ssl.create_default_context()
        self.connection = http.client.HTTPSConnection(
            REPOSITORY_HOST, timeout=REQUEST_TIMEOUT, context=context)

    def get(self, path, allow_missing=False):
        """Returns bytes, or None when the server says the path is absent."""
        if self.budget.expired():
            raise RuntimeError('time budget exhausted before ' + path)
        for attempt in (1, 2):
            try:
                if self.connection is None:
                    self._connect()
                self.connection.request('GET', REPOSITORY_ROOT + path, headers={
                    'User-Agent': 'qfli-java-pack-preparer/1',
                    'Accept': '*/*',
                    'Connection': 'keep-alive',
                })
                response = self.connection.getresponse()
                body = response.read()
                if response.status == 200:
                    self.requests += 1
                    self.bytes += len(body)
                    return body
                self.connection.close()
                self.connection = None
                if response.status in (404, 410) and allow_missing:
                    return None
                if attempt == 2:
                    raise RuntimeError(f'HTTP {response.status} for {path}')
            except (http.client.HTTPException, OSError, socket.timeout) as error:
                self.connection = None
                if attempt == 2:
                    raise RuntimeError(f'{type(error).__name__} for {path}: {error}')
                time.sleep(0.3)
        raise RuntimeError('unreachable')

    def close(self):
        if self.connection is not None:
            try:
                self.connection.close()
            finally:
                self.connection = None


# ---------------------------------------------------------------------------
# Lock handling. The lock is the single source of truth for the normal path.
# ---------------------------------------------------------------------------


def load_lock(lock_path):
    """Reads a lock file. A missing or malformed lock is a hard failure."""
    if not os.path.isfile(lock_path):
        raise RuntimeError(f'lock file missing: {lock_path}')
    with open(lock_path, encoding='utf-8') as handle:
        lock = json.load(handle)
    artifacts = lock.get('artifacts')
    if not isinstance(artifacts, list) or not artifacts:
        raise RuntimeError(f'lock file has no artifacts: {lock_path}')
    for artifact in artifacts:
        for field in ('file', 'sha256', 'bytes', 'mavenPath'):
            if not artifact.get(field) and artifact.get(field) != 0:
                raise RuntimeError(f'lock entry {artifact.get("file")} has no {field}')
    return lock


def lock_manifest_entries(lock, pack, directory):
    """Builds the hashed manifest entries from the lock, checking disk as it goes.

    Returns ``(entries, failures)``. The same function feeds the manifest writer
    and the read-only verifier, so the two can never disagree about what the
    manifest should contain.
    """
    namespace = lock.get('servletNamespace', PACK_NAMESPACE[pack])
    failures = []
    entries = []
    for artifact in lock.get('artifacts', []):
        name = artifact['file']
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            failures.append({'artifact': name, 'stage': 'manifest',
                             'error': 'listed in the lock but absent on disk'})
            continue
        body = open(path, 'rb').read()
        digest = hashlib.sha256(body).hexdigest()
        if digest != artifact['sha256']:
            failures.append({'artifact': name, 'stage': 'manifest',
                             'error': f'disk sha256 {digest[:16]} != lock {artifact["sha256"][:16]}'})
            continue
        if len(body) != artifact['bytes']:
            failures.append({'artifact': name, 'stage': 'manifest',
                             'error': f'disk bytes {len(body)} != lock {artifact["bytes"]}'})
            continue
        entries.append({
            'file': name,
            'bytes': len(body),
            'sha256': digest,
            'scope': artifact.get('scope', 'runtime'),
            'role': artifact.get('role', ''),
            'license': artifact.get('license', ''),
            'version': artifact.get('version'),
            'mavenPath': artifact.get('mavenPath'),
            'namespace': namespace,
        })
    listed = {entry['file'] for entry in entries}
    for name in sorted(os.listdir(directory)):
        if name.endswith('.jar') and name not in listed:
            failures.append({'artifact': name, 'stage': 'manifest',
                             'error': 'present on disk but absent from the lock'})
    entries.sort(key=lambda entry: entry['file'])
    return entries, failures


def _manifest_texts(lock, entries):
    """The exact bytes both manifests are written as."""
    hashed = {'packId': lock.get('packId'), 'namespace': lock.get('servletNamespace'),
              'files': entries}
    hashed_text = json.dumps(hashed, ensure_ascii=False, indent=2) + '\n'
    plain_text = json.dumps(sorted(entry['file'] for entry in entries), indent=2) + '\n'
    return hashed_text, plain_text


def write_manifests_from_lock(directory, lock_path, pack, log):
    """Writes both manifests from the lock. MUTATING step, never used in verify."""
    lock = load_lock(lock_path)
    entries, failures = lock_manifest_entries(lock, pack, directory)
    hashed_text, plain_text = _manifest_texts(lock, entries)
    with open(os.path.join(directory, 'manifest.hashed.json'), 'w',
              encoding='utf-8', newline='\n') as handle:
        handle.write(hashed_text)
    with open(os.path.join(directory, 'manifest.json'), 'w',
              encoding='utf-8', newline='\n') as handle:
        handle.write(plain_text)
    log(f'    manifests: {len(entries)} hashed entries, {len(failures)} problems')
    return failures, len(entries)


def verify_manifests_from_lock(directory, lock_path, pack, log):
    """Compares the manifests on disk with the lock. Reports drift; repairs none."""
    lock = load_lock(lock_path)
    entries, failures = lock_manifest_entries(lock, pack, directory)
    hashed_text, plain_text = _manifest_texts(lock, entries)
    for name, expected in (('manifest.hashed.json', hashed_text), ('manifest.json', plain_text)):
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            failures.append({'artifact': name, 'stage': 'verify-manifest',
                             'error': 'manifest is absent'})
            continue
        actual = open(path, encoding='utf-8').read()
        if actual != expected:
            failures.append({'artifact': name, 'stage': 'verify-manifest',
                             'error': 'manifest content differs from the lock'})
    log(f'    manifests checked: {len(entries)} entries, {len(failures)} drift')
    return failures


def verify_lock_against_disk(lock_path, directory, pack, log):
    """Read-only: every locked file is present, correct, and no extra jar exists."""
    lock = load_lock(lock_path)
    failures = []
    for artifact in lock.get('artifacts', []):
        path = os.path.join(directory, artifact['file'])
        if not os.path.isfile(path):
            failures.append({'artifact': artifact['file'], 'stage': 'verify',
                             'error': 'missing from disk and --verify-only was given'})
            continue
        body = open(path, 'rb').read()
        digest = hashlib.sha256(body).hexdigest()
        if len(body) != artifact['bytes']:
            failures.append({'artifact': artifact['file'], 'stage': 'verify',
                             'error': f'bytes {len(body)} != lock {artifact["bytes"]}'})
        elif digest != artifact['sha256']:
            failures.append({'artifact': artifact['file'], 'stage': 'verify',
                             'error': f'sha256 {digest[:16]} != lock {artifact["sha256"][:16]}'})
    listed = {artifact['file'] for artifact in lock.get('artifacts', [])}
    for name in sorted(os.listdir(directory)) if os.path.isdir(directory) else []:
        if name.endswith('.jar') and name not in listed:
            failures.append({'artifact': name, 'stage': 'verify',
                             'error': 'present on disk but absent from the lock'})
    log(f'    lock vs disk: {len(lock.get("artifacts", []))} entries, {len(failures)} drift')
    return failures


# ---------------------------------------------------------------------------
# Licence documents. Recorded in the lock, extracted in prepare, checked in
# verify. The lock keeps name, byte count and SHA-256 so drift is detectable.
# ---------------------------------------------------------------------------


def license_entries(archive):
    """License and notice documents inside a jar, by their entry name.

    Only the archive root, META-INF and the packaged POM metadata are inspected,
    so a class named ``Notice`` deeper in the tree can never be mistaken for a
    notice document. A jar that ships no standalone text is still represented by
    its own packaged POM, which carries the license block.
    """
    prefixes = ('LICENSE', 'NOTICE', 'COPYING', 'ABOUT', 'EPL')
    wanted = []
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            if name.startswith('META-INF/maven/') and name.endswith('/pom.xml'):
                wanted.append(name)
                continue
            if not name.lower().endswith(('.txt', '.md', '.html', '.htm', '')):
                continue
            parts = name.split('/')
            if len(parts) > 2:
                continue
            if len(parts) == 2 and parts[0] != 'META-INF':
                continue
            base = parts[-1].upper()
            if not base.startswith(prefixes):
                continue
            if z.getinfo(name).file_size > 400_000:
                continue
            wanted.append(name)
    # A standalone text is stronger evidence than POM metadata, so the POM is only
    # kept when the archive holds nothing else.
    standalone = [name for name in wanted if not name.startswith('META-INF/maven/')]
    return standalone if standalone else wanted


def extract_licenses_from_lock(directory, lock_path, pack, log):
    """Copies every recorded licence document out of its archive. MUTATING.

    Also records ``licenseHashes`` (flat name to byte count and SHA-256) in the
    lock, so the read-only verifier can detect a licence that changed.
    """
    lock = load_lock(lock_path)
    written = []
    changed = False
    for artifact in lock.get('artifacts', []):
        names = artifact.get('licenseFiles') or []
        if not names:
            continue
        jar = os.path.join(directory, artifact['file'])
        if not os.path.isfile(jar):
            continue
        target_dir = os.path.join(directory, 'licenses')
        try:
            with zipfile.ZipFile(jar) as z:
                available = {entry.replace('/', '_'): entry for entry in z.namelist()}
                hashes = dict(artifact.get('licenseHashes') or {})
                for name in names:
                    target = os.path.join(target_dir, f'{artifact["artifactId"]}__{name}')
                    entry = available.get(name)
                    if entry is None:
                        continue
                    body = z.read(entry)
                    record = {'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
                    if os.path.isfile(target) and os.path.getsize(target) > 0:
                        if hashes.get(name) != record:
                            hashes[name] = record
                            changed = True
                        continue
                    os.makedirs(target_dir, exist_ok=True)
                    with open(target, 'wb') as handle:
                        handle.write(body)
                    written.append({'artifact': artifact['artifactId'], 'entry': name,
                                    'bytes': len(body),
                                    'sha256': hashlib.sha256(body).hexdigest()})
                    if hashes.get(name) != record:
                        hashes[name] = record
                        changed = True
                if hashes != (artifact.get('licenseHashes') or {}):
                    artifact['licenseHashes'] = hashes
                    changed = True
        except zipfile.BadZipFile:
            continue
    if changed:
        with open(lock_path, 'w', encoding='utf-8', newline='\n') as handle:
            json.dump(lock, handle, ensure_ascii=False, indent=2)
            handle.write('\n')
    log(f'    licence documents written: {len(written)}')
    return written


def verify_licenses_from_lock(directory, lock_path, pack, log):
    """Read-only: every recorded licence is present and matches its record."""
    lock = load_lock(lock_path)
    failures = []
    checked = 0
    for artifact in lock.get('artifacts', []):
        names = artifact.get('licenseFiles') or []
        if not names:
            if not artifact.get('licenseDocumentAvailable'):
                failures.append({'artifact': artifact['file'], 'stage': 'verify-license',
                                 'error': 'no licence recorded and no absence explained'})
            continue
        hashes = artifact.get('licenseHashes') or {}
        target_dir = os.path.join(directory, 'licenses')
        for name in names:
            target = os.path.join(target_dir, f'{artifact["artifactId"]}__{name}')
            if not os.path.isfile(target) or os.path.getsize(target) == 0:
                failures.append({'artifact': artifact['file'], 'stage': 'verify-license',
                                 'error': f'licence document {name} is absent'})
                continue
            record = hashes.get(name)
            if record is None:
                failures.append({'artifact': artifact['file'], 'stage': 'verify-license',
                                 'error': f'licence document {name} has no recorded digest'})
                continue
            body = open(target, 'rb').read()
            checked += 1
            if len(body) != record['bytes'] or hashlib.sha256(body).hexdigest() != record['sha256']:
                failures.append({'artifact': artifact['file'], 'stage': 'verify-license',
                                 'error': f'licence document {name} differs from its record'})
    log(f'    licence documents checked: {checked}, {len(failures)} drift')
    return failures


# ---------------------------------------------------------------------------
# Reconstruction and completion from the lock. The only network in the normal
# path, and only for a file the lock names and disk does not already hold.
# ---------------------------------------------------------------------------


def fetch_missing_from_lock(directory, lock_path, client, budget, verify_only, pack, log):
    """Ensures every artifact the lock lists is present and correct.

    No resolution happens here: the ``mavenPath`` and the expected SHA-256 both
    come from the lock. A file is fetched only when it is absent or its bytes do
    not match the lock, so a complete pack performs no download.

    Returns a failure list.
    """
    failures = []
    lock = load_lock(lock_path)
    for artifact in lock.get('artifacts', []):
        name = artifact['file']
        destination = os.path.join(directory, name)
        expected = artifact['sha256']
        if os.path.isfile(destination):
            body = open(destination, 'rb').read()
            if hashlib.sha256(body).hexdigest() == expected and len(body) == artifact['bytes']:
                continue
            log(f'    replacing mismatched {name}')
        if verify_only:
            failures.append({'artifact': name, 'stage': 'verify',
                             'error': 'missing from the lock set and --verify-only was given'})
            continue
        try:
            if budget.expired():
                raise RuntimeError('time budget exhausted')
            path = '/' + artifact['mavenPath']
            body = client.get(path)
            published = client.get(path + '.sha1', allow_missing=True)
            if published is not None:
                published_sha1 = published.decode('ascii', 'replace').split()[0].strip().lower()
                if hashlib.sha1(body).hexdigest() != published_sha1:
                    raise RuntimeError('published sha1 does not match the downloaded bytes')
            digest = hashlib.sha256(body).hexdigest()
            if digest != expected:
                raise RuntimeError(f'sha256 {digest[:16]} != lock {expected[:16]}')
            os.makedirs(directory, exist_ok=True)
            partial = destination + '.partial'
            with open(partial, 'wb') as handle:
                handle.write(body)
            os.replace(partial, destination)
            log(f'    restored {name} {len(body)} B from the lock')
        except Exception as error:  # noqa: BLE001 - reported, not hidden
            failures.append({'artifact': name, 'stage': 'restore', 'error': str(error)})
    return failures


def verify_published_digests(directory, lock_path, client, budget, pack, log):
    """Cross-checks every artifact against the repository's published digest.

    A recorded SHA-256 only proves the file has not changed since it was written.
    Comparing against the digest the repository publishes is independent evidence
    that the bytes are the bytes Maven Central serves.

    The SHA-256 sidecar is preferred; the SHA-1 sidecar is accepted when the
    SHA-256 one is absent. Nothing is downloaded except the digest text. This
    performs network GETs, so it is refused under ``--verify-only``.

    Returns (results, failures).
    """
    results = []
    failures = []
    lock = load_lock(lock_path)
    for artifact in lock.get('artifacts', []):
        name = artifact['file']
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            failures.append({'artifact': name, 'stage': 'digest', 'error': 'file absent'})
            continue
        if artifact.get('publishedDigestVerified') is True:
            # Already checked in an earlier bounded run; do not spend time again.
            continue
        body = open(path, 'rb').read()
        if hashlib.sha256(body).hexdigest() != artifact['sha256']:
            failures.append({'artifact': name, 'stage': 'digest',
                             'error': 'local bytes no longer match the lock'})
            continue
        if budget.expired():
            failures.append({'artifact': name, 'stage': 'digest',
                             'error': 'time budget exhausted before the digest was checked'})
            continue
        remote = '/' + artifact['mavenPath']
        record = {'file': name, 'sha256Matches': False, 'sha1Matches': False,
                  'algorithms': []}
        try:
            # The SHA-256 sidecar is the direct check, so it is tried first and
            # the SHA-1 sidecar is only fetched when it is absent.
            published256 = client.get(remote + '.sha256', allow_missing=True)
            published1 = None if published256 is not None else client.get(
                remote + '.sha1', allow_missing=True)
        except Exception as error:  # noqa: BLE001 - reported, not hidden
            failures.append({'artifact': name, 'stage': 'digest', 'error': str(error)})
            continue
        if published256 is not None:
            remote256 = published256.decode('ascii', 'replace').split()[0].strip().lower()
            record['sha256Matches'] = remote256 == artifact['sha256'].lower()
            record['publishedSha256'] = remote256
            record['algorithms'].append('sha256')
            if not record['sha256Matches']:
                failures.append({'artifact': name, 'stage': 'digest',
                                 'error': f'published sha256 {remote256[:16]} != lock {artifact["sha256"][:16]}'})
        if published1 is not None:
            remote1 = published1.decode('ascii', 'replace').split()[0].strip().lower()
            record['sha1Matches'] = remote1 == hashlib.sha1(body).hexdigest()
            record['publishedSha1'] = remote1
            record['algorithms'].append('sha1')
            if not record['sha1Matches']:
                failures.append({'artifact': name, 'stage': 'digest',
                                 'error': 'published sha1 does not match the local bytes'})
        if not record['algorithms']:
            failures.append({'artifact': name, 'stage': 'digest',
                             'error': 'the repository publishes no digest for this artifact'})
        results.append(record)
    verified = [r for r in results if r['sha256Matches'] or r['sha1Matches']]
    skipped = len(lock.get('artifacts', [])) - len(results)
    log(f'    published digests checked: {len(verified)} verified, {skipped} already recorded this run')
    return results, failures


def merge_digest_evidence(lock_path, results, log):
    """Records the digest evidence in the lock, without inventing any of it."""
    if not results:
        return
    lock = load_lock(lock_path)
    by_name = {r['file']: r for r in results}
    for artifact in lock.get('artifacts', []):
        record = by_name.get(artifact['file'])
        if record is None:
            continue
        if record['sha256Matches']:
            artifact['publishedDigest'] = 'sha256'
        elif record['sha1Matches']:
            artifact['publishedDigest'] = 'sha1'
        artifact['publishedDigestVerified'] = bool(record['sha256Matches'] or record['sha1Matches'])
        artifact['publishedDigestAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        artifact.pop('sha1Verified', None)
    with open(lock_path, 'w', encoding='utf-8', newline='\n') as handle:
        json.dump(lock, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    counts = {}
    for artifact in lock.get('artifacts', []):
        key = artifact.get('publishedDigest', 'none')
        counts[key] = counts.get(key, 0) + 1
    log(f'    digest evidence recorded: {counts}')


# ---------------------------------------------------------------------------
# Mutable resolution. Confined to the explicit --refresh operation, which writes
# a candidate lock for review and never touches the live lock.
# ---------------------------------------------------------------------------


def metadata_versions(client, group_id, artifact_id):
    path = f'/{group_id.replace(".", "/")}/{artifact_id}/maven-metadata.xml'
    body = client.get(path, allow_missing=True)
    if body is None:
        return []
    root = ET.fromstring(body)
    nsless = root.tag.split('}')[-1]
    assert nsless == 'metadata', nsless
    versions = []
    for element in root.iter():
        if element.tag.split('}')[-1] == 'version' and element.text:
            versions.append(element.text.strip())
    return versions


STABLE = re.compile(r'^\d+(?:\.\d+)*$')


def resolve_version(client, group_id, artifact_id, hint, log):
    """Highest stable release matching the hint. Never guesses."""
    versions = [v for v in metadata_versions(client, group_id, artifact_id) if STABLE.match(v)]
    if not versions:
        raise RuntimeError(f'no stable version for {group_id}:{artifact_id}')

    def key(text):
        return tuple(int(part) for part in text.split('.'))

    if hint and hint.endswith('.x'):
        prefix = hint[:-2] + '.'
        matching = [v for v in versions if v.startswith(prefix)]
    elif hint and hint.endswith('.'):
        matching = [v for v in versions if v.startswith(hint)]
    else:
        matching = versions
    if not matching:
        raise RuntimeError(f'no {hint} release for {group_id}:{artifact_id}, saw {versions[-4:]}')
    chosen = max(matching, key=key)
    log(f'    resolved {artifact_id}:{chosen} (hint {hint})')
    return chosen


POM_VERSION_PROPERTY = re.compile(r'<properties>(.*?)</properties>', re.S)
POM_ENTRY = re.compile(r'<([A-Za-z0-9.\-]+)>([^<]+)</\1>')


def pom_properties(client, group_id, artifact_id, version, log):
    """Reads <properties> from an artifact POM and its parent chain."""
    properties = {}
    seen = set()
    current = (group_id, artifact_id, version)
    for _ in range(4):
        g, a, v = current
        if (g, a, v) in seen:
            break
        seen.add((g, a, v))
        path = f'/{g.replace(".", "/")}/{a}/{v}/{a}-{v}.pom'
        body = client.get(path, allow_missing=True)
        if body is None:
            break
        text = body.decode('utf-8', 'replace')
        for block in POM_VERSION_PROPERTY.findall(text):
            for name, value in POM_ENTRY.findall(block):
                properties.setdefault(name.strip(), value.strip())
        parent = re.search(r'<parent>(.*?)</parent>', text, re.S)
        if not parent:
            break
        fields = dict(POM_ENTRY.findall(parent.group(1)))
        if not all(k in fields for k in ('groupId', 'artifactId', 'version')):
            break
        current = (fields['groupId'], fields['artifactId'], fields['version'])
        log(f'    parent {current[0]}:{current[1]}:{current[2]}')
    return properties


def interpolate(value, properties):
    for _ in range(4):
        match = re.search(r'\$\{([^}]+)\}', value)
        if not match:
            return value
        replacement = properties.get(match.group(1))
        if replacement is None:
            return value
        value = value[:match.start()] + replacement + value[match.end():]
    return value


def artifact_path(group_id, artifact_id, version):
    group = group_id.replace('.', '/')
    return f'/{group}/{artifact_id}/{version}/{artifact_id}-{version}.jar'


def looks_foreign(pack, file_name):
    """Returns the marker that proves a file belongs to the other pack, or None.

    Unused by the prepare and verify paths. It is kept as a guard for a future
    caller, but it is not a refusal before the fetch: namespace purity is checked
    after the fact by ``tools/validate_javaee_packs.py``.
    """
    for marker in FOREIGN_NAMESPACE_MARKERS[pack]:
        if marker in file_name.lower():
            return marker
    return None


def refresh_candidate(root, pack, client, budget, log):
    """Resolves versions freshly and writes a candidate lock. Explicit only.

    The live lock is never modified. Every artifact already in the live lock
    keeps its recorded metadata; only the version, file name, path and bytes may
    change. The result is written as ``<lock>.refresh.json`` for a human to
    review and promote, so a mutable resolution can never silently enter the
    frozen set.
    """
    lock_path = os.path.join(root, LOCK_FILES[pack].replace('/', os.sep))
    live = load_lock(lock_path)
    existing = {(a.get('groupId'), a.get('artifactId')): a for a in live['artifacts']}
    rows = [row for row in SEED_PLAN if row[0] == pack]

    resolved = {}
    for (_, group_id, artifact_id, version, hint, *_rest) in rows:
        if version is not None:
            resolved[(group_id, artifact_id)] = version
            continue
        key = (group_id, artifact_id)
        if key in resolved:
            continue
        try:
            resolved[key] = resolve_version(client, group_id, artifact_id, hint, log)
        except Exception as error:  # noqa: BLE001 - reported, not hidden
            return None, [{'artifact': f'{group_id}:{artifact_id}', 'stage': 'resolve',
                           'error': str(error)}]
    starter = [row for row in rows if row[2] == 'mybatis-spring-boot-starter']
    if starter:
        version = resolved.get((starter[0][1], starter[0][2]))
        if version:
            properties = pom_properties(client, starter[0][1], starter[0][2], version, log)
            for name, key in (('mybatis.version', ('org.mybatis', 'mybatis')),
                              ('mybatis-spring.version', ('org.mybatis', 'mybatis-spring'))):
                if name in properties:
                    value = interpolate(properties[name], properties)
                    resolved[key] = value
                    log(f'    {name} = {value} (from the starter POM chain)')

    updated = []
    changes = []
    for (_, group_id, artifact_id, version, hint, scope, role, license_name) in rows:
        key = (group_id, artifact_id)
        version = resolved.get(key, version)
        if version is None:
            return None, [{'artifact': f'{group_id}:{artifact_id}', 'stage': 'resolve',
                           'error': 'version not resolved; refresh aborted'}]
        template = existing.get(key, {})
        file_name = f'{artifact_id}-{version}.jar'
        path = artifact_path(group_id, artifact_id, version)
        old_version = template.get('version')
        if old_version and old_version != version:
            changes.append((file_name, old_version, version))
        entry = dict(template)
        entry.update({
            'groupId': group_id, 'artifactId': artifact_id, 'version': version,
            'file': file_name, 'scope': scope, 'role': role, 'license': license_name,
            'mavenPath': path.lstrip('/'),
        })
        try:
            body = client.get(path)
            published = client.get(path + '.sha1', allow_missing=True)
            if published is not None:
                expected_sha1 = published.decode('ascii', 'replace').split()[0].strip().lower()
                if hashlib.sha1(body).hexdigest() != expected_sha1:
                    raise RuntimeError('published sha1 does not match the downloaded bytes')
            entry['bytes'] = len(body)
            entry['sha256'] = hashlib.sha256(body).hexdigest()
            entry['status'] = 'candidate'
            entry.pop('publishedDigest', None)
            entry.pop('publishedDigestVerified', None)
            entry.pop('publishedDigestAt', None)
            entry['publishedDigest'] = 'sha1' if published is not None else 'none'
            entry['publishedDigestVerified'] = published is not None
            entry.pop('licenseHashes', None)
        except Exception as error:  # noqa: BLE001 - reported, not hidden
            return None, [{'artifact': file_name, 'stage': 'refresh', 'error': str(error)}]
        updated.append(entry)
        if budget.expired():
            return None, [{'artifact': pack, 'stage': 'refresh', 'error': 'time budget exhausted'}]

    candidate = dict(live)
    candidate['artifacts'] = updated
    candidate['refreshedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    candidate['note'] = ('Candidate lock from --refresh. Review the version changes, then '
                         'promote it by hand. The live lock was not modified.')
    out_path = os.path.join(root, (LOCK_FILES[pack] + '.refresh.json').replace('/', os.sep))
    with open(out_path, 'w', encoding='utf-8', newline='\n') as handle:
        json.dump(candidate, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    log(f'    candidate lock written: {os.path.relpath(out_path, root)} '
        f'({len(updated)} artifacts, {len(changes)} version change(s))')
    for file_name, old, new in changes:
        log(f'      {file_name}: {old} -> {new}')
    return out_path, []


def main(argv=None):
    parser = argparse.ArgumentParser(description='Prepare the Java EE offline packs.')
    parser.add_argument('--packs', default='all',
                        help='comma separated pack ids, or all')
    parser.add_argument('--verify-only', action='store_true',
                        help='check present files read-only, fetch and write nothing')
    parser.add_argument('--refresh', action='store_true',
                        help='resolve versions freshly and write a candidate lock for review')
    parser.add_argument('--budget', type=float, default=DEFAULT_BUDGET,
                        help='foreground seconds for the whole run')
    parser.add_argument('--report', default=None,
                        help='optional path for the JSON report; nothing is written without it')
    parser.add_argument('--repository', default=None,
                        help='override the Maven Central host')
    parser.add_argument('--verify-digests', action='store_true',
                        help='cross-check every artifact against the repository digest')
    args = parser.parse_args(argv)

    global REPOSITORY_HOST
    if args.repository:
        REPOSITORY_HOST = args.repository

    if args.verify_only and args.refresh:
        raise SystemExit('--verify-only and --refresh are mutually exclusive')
    if args.verify_only and args.verify_digests:
        raise SystemExit('--verify-only fetches nothing, so it cannot check published '
                         'digests. Drop --verify-digests or drop --verify-only.')
    if args.refresh and args.verify_digests:
        raise SystemExit('--refresh writes a candidate lock; do not combine it with '
                         '--verify-digests, which records evidence in the live lock.')

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    requested = ('spring-boot', 'javaee8') if args.packs == 'all' else tuple(
        part.strip() for part in args.packs.split(',') if part.strip())
    unknown = [name for name in requested if name not in PACK_DIRECTORIES]
    if unknown:
        raise SystemExit(f'unknown pack: {unknown}')

    lines = []
    started_at = time.monotonic()

    def log(message):
        print(message, flush=True)
        lines.append(message)

    budget = Budget(600.0 if args.refresh else args.budget)
    client = Client(budget)
    report = {'mode': 'verify' if args.verify_only else ('refresh' if args.refresh else 'prepare'),
              'packs': {}, 'requests': 0, 'bytes': 0,
              'started': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    exit_code = 0

    for pack in requested:
        directory = os.path.join(root, PACK_DIRECTORIES[pack].replace('/', os.sep))
        lock_path = os.path.join(root, LOCK_FILES[pack].replace('/', os.sep))
        namespace = PACK_NAMESPACE[pack]
        failures = []

        if args.refresh:
            log(f'== pack {pack}: refresh (candidate lock)')
            try:
                candidate_path, failures = refresh_candidate(root, pack, client, budget, log)
            except Exception as error:  # noqa: BLE001 - reported, not hidden
                candidate_path, failures = None, [{'artifact': pack, 'stage': 'refresh',
                                                   'error': str(error)}]
            report['packs'][pack] = {'directory': PACK_DIRECTORIES[pack],
                                     'namespace': namespace, 'failures': failures,
                                     'candidate': candidate_path}
            if failures:
                exit_code = 1
            continue

        if args.verify_only:
            log(f'== pack {pack}: verify only (read-only)')
            try:
                failures += verify_lock_against_disk(lock_path, directory, pack, log)
                failures += verify_manifests_from_lock(directory, lock_path, pack, log)
                failures += verify_licenses_from_lock(directory, lock_path, pack, log)
            except Exception as error:  # noqa: BLE001 - reported, not hidden
                failures.append({'artifact': pack, 'stage': 'verify', 'error': str(error)})
            report['packs'][pack] = {'directory': PACK_DIRECTORIES[pack],
                                     'namespace': namespace, 'failures': failures}
            if failures:
                exit_code = 1
            continue

        # ---- normal preparation: reconstruct exactly the lock, nothing else.
        log(f'== pack {pack}: prepare from lock ({LOCK_FILES[pack]})')
        try:
            lock = load_lock(lock_path)
            count = len(lock['artifacts'])
            log(f'    lock holds {count} frozen artifacts')
            failures += fetch_missing_from_lock(directory, lock_path, client, budget,
                                                False, pack, log)
            if args.verify_digests:
                digest_results, digest_failures = verify_published_digests(
                    directory, lock_path, client, budget, pack, log)
                if digest_results:
                    merge_digest_evidence(lock_path, digest_results, log)
                failures.extend(digest_failures)
            extract_licenses_from_lock(directory, lock_path, pack, log)
            manifest_failures, manifest_count = write_manifests_from_lock(
                directory, lock_path, pack, log)
            failures.extend(manifest_failures)
        except Exception as error:  # noqa: BLE001 - reported, not hidden
            failures.append({'artifact': pack, 'stage': 'prepare', 'error': str(error)})
            manifest_count = 0
        report['packs'][pack] = {
            'directory': PACK_DIRECTORIES[pack],
            'namespace': namespace,
            'failures': failures,
            'manifestEntries': manifest_count,
        }
        if failures:
            exit_code = 1

    client.close()
    report['requests'] = client.requests
    report['bytes'] = client.bytes
    report['elapsedSeconds'] = round(time.monotonic() - started_at, 2)
    report['finished'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

    if args.report:
        path = os.path.join(root, args.report.replace('/', os.sep))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8', newline='\n') as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
            handle.write('\n')

    total = 0
    for pack, summary in report['packs'].items():
        failures = summary.get('failures', [])
        log(f'== {pack}: {len(failures)} failure(s)')
        for failure in failures:
            log(f'   FAIL {failure["artifact"]} [{failure["stage"]}] {failure["error"]}')
        total += len(failures)
    log(f'== requests {report["requests"]}, bytes {report["bytes"]}, '
        f'elapsed {report["elapsedSeconds"]}s, failures {total}')
    if args.report:
        log(f'== report {args.report}')
    return exit_code if total == 0 else exit_code or 1


if __name__ == '__main__':
    sys.exit(main())