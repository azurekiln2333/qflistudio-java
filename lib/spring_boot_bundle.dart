/// Locates the bundled Java EE dependency packs and materialises them as real
/// JAR files on disk.
///
/// Two packs exist and they are never mixed:
///
/// - `spring-boot` — Spring Boot 3 on the `jakarta.servlet` namespace. It is
///   prepared from `tools/spring_boot.lock.json` into
///   `assets/spring_boot/3.5.16`.
/// - `javaee8` — Tomcat 9 on the `javax.servlet` namespace, with JSP, EL, the
///   JSP compiler and the javax JSTL API and implementation. It is prepared
///   from `tools/javaee8.lock.json` into `assets/javaee8`.
///
/// The manifest and the lock always describe the whole pack. A classpath is a
/// selection over that pack, never the whole file list. The Spring Boot pack
/// carries a database group — JDBC, HikariCP, MyBatis and the connector — and
/// that group is off by default: a health-only application with MyBatis
/// auto-configuration and a pooled DataSource on the classpath fails at startup
/// because no datasource URL exists. Nothing excludes the group at run time, so
/// the classpath itself carries the choice.
///
/// A `javax.servlet` jar on a Tomcat 10 classpath fails at the first request
/// with `NoClassDefFoundError`, so each pack materialises into its own
/// directory and the two namespaces can never share one.
///
/// Java toolchains cannot read a Flutter asset directly, so the JARs are copied
/// into a real directory before `javac`/`java` are invoked. Each file is
/// verified against the SHA-256 recorded in its manifest, so a truncated or
/// stale copy is replaced instead of silently used.
///
/// The launcher that starts a container from these packs is a separate concern
/// and does not live in this file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/tools/offline_tools.dart';

/// Which jars a caller wants from a pack.
///
/// `compile` jars are APIs that `javac` needs but the runtime already supplies,
/// such as `jakarta.servlet-api` next to `tomcat-embed-core`. Putting them on
/// the run classpath would add a second copy of a class that must stay single.
enum JavaEeJarScope { runtime, compile, all }

/// Roles that form the database group.
///
/// The group is a dependency-closure choice, not a runtime exclusion. A pack
/// selects it only when a project actually talks to a database.
const List<String> javaEeDatabaseRoles = <String>['jdbc', 'persistence'];

/// The frozen profile wire names.
///
/// The config decoder in `java_web_project.dart` and the schema mirror in
/// `java_web_templates.dart` carry the matching enums. These constants exist so
/// this file has no second source of truth for the strings themselves.
abstract final class JavaEeProfiles {
  static const String springBoot = 'spring-boot';
  static const String javaee8 = 'javaee8';

  static const List<String> all = <String>[springBoot, javaee8];
}

/// One file inside a pack.
@immutable
class JavaEePackFile {
  const JavaEePackFile({
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.scope,
    this.role,
    this.license,
  });

  /// Plain file name. A path separator is refused when the manifest is read.
  final String name;
  final int bytes;
  final String sha256;
  final JavaEeJarScope scope;
  final String? role;
  final String? license;

  @override
  String toString() => '$name ($bytes bytes, ${scope.name})';
}

/// A refused pack request, or a pack whose bytes do not match its manifest.
class JavaEePackException implements Exception {
  const JavaEePackException(this.message);

  final String message;

  @override
  String toString() => 'JavaEePackException: $message';
}

/// Identity and asset location of one pack.
@immutable
class JavaEePack {
  const JavaEePack({
    required this.profile,
    required this.namespace,
    required this.assetRoot,
    required this.version,
  });

  /// Frozen profile wire name.
  final String profile;

  /// The only servlet namespace this pack may contain.
  final String namespace;

  final String assetRoot;

  /// Pack version for display. The `javaee8` pack has no single version.
  final String? version;

  String get displayName => switch (profile) {
    JavaEeProfiles.springBoot => 'Spring Boot 3',
    JavaEeProfiles.javaee8 => 'Java EE 8',
    _ => profile,
  };
}

/// The packs that ship with the app, and the only way to obtain their JARs.
abstract final class JavaEePacks {
  static const JavaEePack springBoot = JavaEePack(
    profile: JavaEeProfiles.springBoot,
    namespace: 'jakarta.servlet',
    assetRoot: 'assets/spring_boot/3.5.16',
    version: '3.5.16',
  );

  static const JavaEePack javaee8 = JavaEePack(
    profile: JavaEeProfiles.javaee8,
    namespace: 'javax.servlet',
    assetRoot: 'assets/javaee8',
    version: null,
  );

  static const List<JavaEePack> all = <JavaEePack>[springBoot, javaee8];

  /// Resolves a profile name. An unknown name is refused, never defaulted.
  static JavaEePack packFor(String profile) {
    for (final pack in all) {
      if (pack.profile == profile) {
        return pack;
      }
    }
    throw JavaEePackException(
      'Unknown Java EE profile $profile. Known profiles: ${JavaEeProfiles.all.join(", ")}',
    );
  }

  /// Per-process materialisation cache, one entry per profile and target.
  ///
  /// Each entry carries the identity of every file it handed out, not only the
  /// path. A path alone is not proof: the file can be deleted, truncated or
  /// replaced between two calls, and returning a stale path list would hand a
  /// caller a classpath with a missing or corrupted jar in it. Every cache hit is
  /// therefore revalidated against the recorded length and SHA-256, and a
  /// mismatch re-materialises instead of trusting the cache.
  /// In-flight materialisations, keyed like [_cached]. The value is the receipt
  /// future, not a path future, so a concurrent caller waits for the same
  /// verified files and the public boundary is the only place paths are produced.
  static final Map<String, Future<List<_MaterialisedFile>>> _materialising =
      <String, Future<List<_MaterialisedFile>>>{};
  static final Map<String, List<_MaterialisedFile>> _cached =
      <String, List<_MaterialisedFile>>{};
  static final Map<String, List<JavaEePackFile>> _manifestCache =
      <String, List<JavaEePackFile>>{};

  /// The asset readers. They default to the bundle so production code is
  /// unchanged, and a test can swap them to drive the cache without a bundle.
  static Future<String> _loadStringFromBundle(String key) =>
      rootBundle.loadString(key);

  static Future<Uint8List> _loadBytesFromBundle(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static Future<String> Function(String key) _stringLoader =
      _loadStringFromBundle;
  static Future<Uint8List> Function(String key) _byteLoader =
      _loadBytesFromBundle;

  /// Swaps the asset readers. Test-only.
  @visibleForTesting
  static void useLoadersForTest({
    Future<String> Function(String key)? stringLoader,
    Future<Uint8List> Function(String key)? byteLoader,
  }) {
    if (stringLoader != null) {
      _stringLoader = stringLoader;
    }
    if (byteLoader != null) {
      _byteLoader = byteLoader;
    }
  }

  /// The pack manifest.
  ///
  /// The hashed manifest is required. There is deliberately no fallback to the
  /// plain name list: a name list carries no hashes, cannot prove a byte, and
  /// would classify every file as runtime, which silently switches the database
  /// group on. A pack that cannot produce its hashed manifest is reported as
  /// unavailable instead of being trusted.
  static Future<List<JavaEePackFile>> files(String profile) async {
    final pack = packFor(profile);
    final cached = _manifestCache[pack.profile];
    if (cached != null) {
      return cached;
    }
    final hashed = '${pack.assetRoot}/manifest.hashed.json';
    final String raw;
    try {
      raw = await _stringLoader(hashed);
    } on FlutterError catch (error) {
      throw JavaEePackException(
        'The ${pack.profile} pack has no usable manifest.hashed.json, so its bytes '
        'cannot be verified. Run tools/prepare_javaee_packs.py and rebuild. ($error)',
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['files'] is! List) {
      throw JavaEePackException(
        'The ${pack.profile} manifest.hashed.json is malformed: it must be an object '
        'with a files list.',
      );
    }
    final declaredPack = decoded['packId'];
    if (declaredPack is String && declaredPack != pack.profile) {
      throw JavaEePackException(
        'The ${pack.profile} manifest.hashed.json declares packId $declaredPack.',
      );
    }
    final entries = (decoded['files'] as List)
        .map((item) => _packFileFromJson(item))
        .toList(growable: false);
    if (entries.isEmpty) {
      throw JavaEePackException(
        'The ${pack.profile} manifest.hashed.json is empty.',
      );
    }
    for (final entry in entries) {
      if (entry.sha256.isEmpty || entry.bytes < 0) {
        throw JavaEePackException(
          'The ${pack.profile} entry ${entry.name} has no usable hash or byte count, so '
          'the pack cannot be verified.',
        );
      }
    }
    return _manifestCache[pack.profile] = entries;
  }

  static JavaEePackFile _packFileFromJson(Object? item) {
    if (item is! Map) {
      throw const FormatException('pack manifest entry must be an object');
    }
    final name = item['file'] ?? item['name'];
    if (name is! String ||
        name.isEmpty ||
        name.contains('/') ||
        name.contains('\\')) {
      throw FormatException('Invalid pack entry name: $name');
    }
    final bytes = item['bytes'];
    final sha = item['sha256'];
    return JavaEePackFile(
      name: name,
      bytes: bytes is int ? bytes : -1,
      sha256: sha is String ? sha : '',
      scope: _scopeFromName(item['scope']),
      role: item['role'] is String ? item['role'] as String : null,
      license: item['license'] is String ? item['license'] as String : null,
    );
  }

  static JavaEeJarScope _scopeFromName(Object? value) => switch (value) {
    'compile' => JavaEeJarScope.compile,
    'all' => JavaEeJarScope.all,
    _ => JavaEeJarScope.runtime,
  };

  static Future<List<String>> _readPlainManifest(JavaEePack pack) async {
    try {
      final raw = await _stringLoader('${pack.assetRoot}/manifest.json');
      final decoded = _decodeNameList(raw);
      if (decoded.isEmpty) {
        throw const FormatException('pack manifest is empty');
      }
      return decoded;
    } on FlutterError catch (error) {
      throw JavaEePackException(
        'The ${pack.profile} pack is unavailable. Run '
        'tools/prepare_javaee_packs.py and rebuild. ($error)',
      );
    }
  }

  /// The plain name list of a pack, for display and for compatibility with the
  /// older Spring Boot pack. It is never used to authorise a classpath.
  static Future<List<String>> plainNames(String profile) =>
      _readPlainManifest(packFor(profile));

  /// What a pack contains, independent of which jars a caller selects.
  ///
  /// Every flag comes from a role recorded in the hashed manifest. No flag is
  /// inferred from a file-name substring, because a name is not a capability:
  /// `mysql-connector-j` proves a driver is present, and a jar whose name merely
  /// contains `jdbc` proves nothing about whether it can connect.
  static Future<JavaEePackCapabilities> capabilities(String profile) async {
    final entries = await files(profile);
    final roles = <String>{
      for (final entry in entries)
        if ((entry.role ?? '').isNotEmpty) entry.role!,
    };
    return JavaEePackCapabilities(
      web: roles.contains('web'),
      json: roles.contains('json'),
      servlet: roles.contains('servlet'),
      jsp: roles.contains('jsp'),
      jstl: roles.contains('jstl'),
      jdbc: roles.contains('jdbc'),
      persistence: roles.contains('persistence'),
      roles: roles.toList()..sort(),
    );
  }

  /// JAR names in a pack, in stable order. Used to report what is available.
  ///
  /// This is the whole pack, which is what a capability display needs. Use
  /// [runtimeJarNames] for a classpath.
  static Future<List<String>> jarNames(
    String profile, {
    JavaEeJarScope scope = JavaEeJarScope.all,
  }) async {
    final entries = await files(profile);
    return entries
        .where((entry) => _inScope(entry.scope, scope))
        .map((entry) => entry.name)
        .toList(growable: false);
  }

  /// JAR names for a run classpath.
  ///
  /// [includeDatabase] false omits the whole database group, so a health-only
  /// Spring Boot application starts without a datasource URL. The `javaee8`
  /// pack has no database group, so the flag has no effect there.
  static Future<List<String>> runtimeJarNames(
    String profile, {
    bool includeDatabase = false,
  }) async {
    final entries = await files(profile);
    return _selectRuntime(
      entries,
      includeDatabase,
    ).map((entry) => entry.name).toList(growable: false);
  }

  /// Compile-only JAR names, such as the Servlet API next to the container.
  static Future<List<String>> compileJarNames(String profile) async {
    final entries = await files(profile);
    return entries
        .where((entry) => entry.scope == JavaEeJarScope.compile)
        .map((entry) => entry.name)
        .toList(growable: false);
  }

  static Iterable<JavaEePackFile> _selectRuntime(
    List<JavaEePackFile> entries,
    bool includeDatabase,
  ) => entries.where((entry) {
    if (entry.scope == JavaEeJarScope.compile) {
      return false;
    }
    if (!includeDatabase && javaEeDatabaseRoles.contains(entry.role)) {
      return false;
    }
    return true;
  });

  /// The runtime selection as names, for a test that has no asset bundle.
  ///
  /// Same rule as [runtimeJarNames]: compile scope out, database roles out
  /// unless asked for. Exposed so the rule can be proved from a manifest file on
  /// disk without a Flutter asset load.
  @visibleForTesting
  static List<String> selectRuntimeNames(
    List<JavaEePackFile> entries, {
    bool includeDatabase = false,
  }) => _selectRuntime(
    entries,
    includeDatabase,
  ).map((entry) => entry.name).toList(growable: false);

  /// Builds a pack entry from a manifest record. Test-only entry point so a test
  /// can reuse the real parser instead of duplicating it.
  @visibleForTesting
  static JavaEePackFile packFileFromJson(Object? item) =>
      _packFileFromJson(item);

  static bool _inScope(JavaEeJarScope entryScope, JavaEeJarScope wanted) {
    if (wanted == JavaEeJarScope.all || entryScope == JavaEeJarScope.all) {
      return true;
    }
    return entryScope == wanted;
  }

  /// Content identity of a pack: nothing to do with where it is written.
  ///
  /// Derived from the sorted name and hash list, so a changed byte changes the
  /// identity even when the file names stay the same.
  static Future<String> identity(String profile) async {
    final entries = await files(profile);
    final parts =
        entries.map((entry) => '${entry.name}:${entry.sha256}').toList()
          ..sort();
    return sha256Hex(utf8.encode(parts.join('\n')));
  }

  /// Real JAR paths for one profile, ready for a classpath.
  ///
  /// The pack writes into `<targetDirectory>/<profile>/`. A per-profile
  /// directory is not cosmetic: it is what stops a `javax.servlet` jar and a
  /// `jakarta.servlet` jar from ever sharing a classpath directory.
  ///
  /// [includeDatabase] false keeps the database group off the classpath. The
  /// files stay in the manifest either way, because the manifest describes the
  /// pack and not the selection.
  ///
  /// Every file is verified against its manifest SHA-256. A file that is
  /// missing, empty, the wrong length, or the wrong hash is rewritten from the
  /// asset before it is returned.
  static Future<List<String>> materialiseProfile(
    String profile, {
    String? targetDirectory,
    bool includeDatabase = false,
  }) async {
    final pack = packFor(profile);
    final key = '${pack.profile}|${targetDirectory ?? ''}|$includeDatabase';
    final existing = _cached[key];
    if (existing != null) {
      if (_receiptsHold(existing)) {
        return _pathsOf(existing);
      }
      // The files moved under us. Drop the stale entry and materialise again,
      // rather than returning paths that no longer describe the pack.
      _cached.remove(key);
    }
    final pending = _materialising[key];
    if (pending != null) {
      return _pathsOf(await pending);
    }
    final future = _materialise(pack, targetDirectory, includeDatabase);
    _materialising[key] = future;
    try {
      final materialised = await future;
      _cached[key] = materialised;
      return _pathsOf(materialised);
    } finally {
      _materialising.remove(key);
    }
  }

  /// The paths a caller needs, taken from verified receipts.
  ///
  /// Converting here, at the public boundary, is what lets the internal cache and
  /// the in-flight map keep the receipt identity without an unsafe cast.
  static List<String> _pathsOf(List<_MaterialisedFile> receipts) =>
      receipts.map((receipt) => receipt.path).toList(growable: false);

  /// True when every cached file still exists with the recorded length and hash.
  ///
  /// This is what makes a cache hit safe: the entry is only reused when the bytes
  /// are still the bytes that were verified, so a deletion or a corruption is
  /// repaired instead of being served.
  static bool _receiptsHold(List<_MaterialisedFile> receipts) {
    for (final receipt in receipts) {
      final file = File(receipt.path);
      if (!file.existsSync()) {
        return false;
      }
      if (file.lengthSync() != receipt.bytes) {
        return false;
      }
      if (sha256Hex(file.readAsBytesSync()) != receipt.sha256) {
        return false;
      }
    }
    return true;
  }

  static Future<List<_MaterialisedFile>> _materialise(
    JavaEePack pack,
    String? targetDirectory,
    bool includeDatabase,
  ) async {
    final entries = await files(pack.profile);
    final selected = _selectRuntime(
      entries,
      includeDatabase,
    ).toList(growable: false);
    final root = targetDirectory == null
        ? (await Directory.systemTemp.createTemp('qfli_javaee_')).path
        : (Directory(targetDirectory)..createSync(recursive: true)).path;
    final directory = Directory(p.join(root, pack.profile));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final materialised = <_MaterialisedFile>[];
    for (final entry in selected) {
      final file = File(p.join(directory.path, entry.name));
      if (!_matches(file, entry)) {
        final bytes = await _readAsset('${pack.assetRoot}/${entry.name}');
        if (bytes.length != entry.bytes) {
          throw JavaEePackException(
            'Asset ${entry.name} is ${bytes.length} bytes, manifest says ${entry.bytes}. '
            'The pack and its manifest disagree.',
          );
        }
        if (sha256Hex(bytes) != entry.sha256.toLowerCase()) {
          throw JavaEePackException(
            'Asset ${entry.name} does not match the manifest SHA-256.',
          );
        }
        await file.writeAsBytes(bytes, flush: true);
        if (!_matches(file, entry)) {
          throw JavaEePackException(
            'Materialised ${entry.name} does not match the manifest after writing.',
          );
        }
      }
      materialised.add(
        _MaterialisedFile(
          path: file.path,
          bytes: entry.bytes,
          sha256: entry.sha256.toLowerCase(),
        ),
      );
    }
    return materialised;
  }

  /// True when the file is already the verified artefact, so no copy is needed.
  ///
  /// A file only counts as present when its length and its SHA-256 both match the
  /// manifest. Length alone would accept a different build of the same jar.
  static bool _matches(File file, JavaEePackFile entry) {
    if (!file.existsSync()) {
      return false;
    }
    final length = file.lengthSync();
    if (length == 0 || length != entry.bytes) {
      return false;
    }
    if (entry.sha256.isEmpty) {
      return false;
    }
    return sha256Hex(file.readAsBytesSync()) == entry.sha256.toLowerCase();
  }

  static Future<Uint8List> _readAsset(String key) => _byteLoader(key);

  /// The plain manifest, a JSON array of file names.
  ///
  /// Kept separate so a test can exercise it without a bundle.
  static List<String> _decodeNameList(String raw) => jsonDecodeList(raw);

  /// Refuses anything that is not a plain file name.
  static List<String> jsonDecodeList(String raw) {
    final value = jsonDecode(raw);
    if (value is! List) {
      throw const FormatException('pack manifest must be a list');
    }
    return value.map((entry) {
      if (entry is! String ||
          entry.isEmpty ||
          entry.contains('/') ||
          entry.contains('\\')) {
        throw FormatException('Invalid pack asset entry: $entry');
      }
      return entry;
    }).toList();
  }

  /// Clears the per-process caches and restores the bundle readers. Test-only.
  @visibleForTesting
  static void resetForTest() {
    _materialising.clear();
    _cached.clear();
    _manifestCache.clear();
    _stringLoader = _loadStringFromBundle;
    _byteLoader = _loadBytesFromBundle;
  }
}

/// One materialised file, with the identity that was verified when it was made.
///
/// The path alone is not a proof of anything, so the length and SHA-256 are kept
/// beside it and rechecked on every cache hit.
@immutable
class _MaterialisedFile {
  const _MaterialisedFile({
    required this.path,
    required this.bytes,
    required this.sha256,
  });

  final String path;
  final int bytes;
  final String sha256;
}

/// What a pack can do, drawn from its own files.
@immutable
class JavaEePackCapabilities {
  const JavaEePackCapabilities({
    required this.web,
    required this.json,
    required this.servlet,
    required this.jsp,
    required this.jstl,
    required this.jdbc,
    required this.persistence,
    required this.roles,
  });

  final bool web;
  final bool json;
  final bool servlet;
  final bool jsp;

  /// A JSTL tag library or its API is present.
  final bool jstl;

  /// A JDBC driver or Spring JDBC is present. Discovery is not a connection.
  final bool jdbc;

  /// A MyBatis mapper runtime is present.
  final bool persistence;
  final List<String> roles;

  /// True when a classpath for this profile would need `includeDatabase`.
  bool get hasDatabaseGroup => jdbc || persistence;

  @override
  String toString() =>
      'web=$web json=$json servlet=$servlet jsp=$jsp jstl=$jstl '
      'jdbc=$jdbc persistence=$persistence roles=$roles';
}

/// Lower-case hex SHA-256 of [bytes].
///
/// The digest itself comes from `OfflineDigest` in the shared core, which is
/// already exercised by the core test suite. This wrapper only chooses the
/// encoding, so the pack verifier and the rest of the studio cannot disagree
/// about what a SHA-256 is.
String sha256Hex(List<int> bytes) => OfflineDigest.sha256Bytes(
  bytes,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// The original Spring Boot entry point.
///
/// Kept because existing callers and tests use it. It now delegates to the
/// `spring-boot` pack, so there is one materialisation path rather than two.
abstract final class SpringBootBundle {
  /// Bundled version directory, matching the lock file's `version`.
  ///
  /// Kept in sync with `tools/spring_boot.lock.json` by
  /// `test/spring_boot_bundle_test.dart`.
  static const String version = '3.5.16';

  static const String _assetRoot = 'assets/spring_boot/$version';

  /// JAR paths ready to be placed on a classpath, in a stable order.
  ///
  /// Returns the runtime classpath without the database group, which is what a
  /// health-only application needs.
  static Future<List<String>> materialise({
    String? targetDirectory,
    bool includeDatabase = false,
  }) => JavaEePacks.materialiseProfile(
    JavaEeProfiles.springBoot,
    targetDirectory: targetDirectory,
    includeDatabase: includeDatabase,
  );

  /// Compatibility delegate for callers written against this class.
  ///
  /// `JavaEePacks.materialiseProfile` is the real entry point and handles both
  /// profiles. This forwarder exists so a caller that reached for
  /// `SpringBootBundle.materialiseProfile(profile, ...)` still compiles, and so
  /// there is one implementation rather than two. Prefer [JavaEePacks] in new
  /// code, because a Spring Boot named class should not be the way to obtain a
  /// `javaee8` classpath.
  static Future<List<String>> materialiseProfile(
    String profile, {
    String? targetDirectory,
    bool includeDatabase = false,
  }) => JavaEePacks.materialiseProfile(
    profile,
    targetDirectory: targetDirectory,
    includeDatabase: includeDatabase,
  );

  /// Capabilities of a pack, forwarded for callers that start here.
  static Future<JavaEePackCapabilities> capabilities(String profile) =>
      JavaEePacks.capabilities(profile);

  /// Every JAR name in the Spring Boot pack, including compile-only APIs.
  static Future<List<String>> jarNames({
    JavaEeJarScope scope = JavaEeJarScope.all,
  }) => JavaEePacks.jarNames(JavaEeProfiles.springBoot, scope: scope);

  /// Parses the manifest, which is a plain JSON array of file names.
  ///
  /// Kept separate so the test can exercise it without a bundle.
  @visibleForTesting
  static List<String> jsonDecodeList(String raw) =>
      JavaEePacks.jsonDecodeList(raw);

  /// The asset directory of the Spring Boot pack.
  static String get assetRoot => _assetRoot;
}
