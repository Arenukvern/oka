import 'dart:convert';

import 'package:oka_core/oka_core.dart';

enum MavenHost { google, central, vendor, unknown }

class MavenRepositoryRouter {
  MavenRepositoryRouter({List<({String prefix, MavenHost host})>? routes})
    : _routes = routes ?? defaultRoutes();

  static const googleHosted = <String>[
    'androidx.',
    'com.android.',
    'com.google.android.',
    'com.google.mlkit',
    'com.google.firebase',
    'com.google.gms',
    'com.google.dagger',
    'com.google.testing.platform',
  ];
  static const centralHosted = <String>[
    'org.jetbrains',
    'com.squareup',
    'org.slf4j',
    'javax.',
    'org.apache.',
    'commons-',
    'io.grpc',
    'com.google.guava',
    'com.google.code',
    'com.fasterxml',
    'org.checkerframework',
    'org.osgi',
    'net.sf',
    'org.ow2.asm',
  ];
  static const vendorOnly = <String>['ru.rustore', 'ru.vk'];

  final List<({String prefix, MavenHost host})> _routes;

  static List<({String prefix, MavenHost host})> defaultRoutes() => [
    for (final prefix in googleHosted) (prefix: prefix, host: MavenHost.google),
    for (final prefix in vendorOnly) (prefix: prefix, host: MavenHost.vendor),
    for (final prefix in centralHosted)
      (prefix: prefix, host: MavenHost.central),
  ];

  MavenHost hostFor(String groupId) {
    for (final route in _routes) {
      if (groupId.startsWith(route.prefix)) return route.host;
    }
    return MavenHost.unknown;
  }

  List<String> candidatesFor(
    MavenCoordinate coordinate, {
    List<String> userRepos = const [],
  }) {
    final output = <String>[];
    void add(String value) {
      if (value.isNotEmpty && !output.contains(value)) output.add(value);
    }

    String builtIn(MavenHost host) => switch (host) {
      MavenHost.google =>
        'https://dl.google.com/dl/android/maven2/${coordinate.pathSegment}/${coordinate.fileName}',
      MavenHost.central =>
        'https://repo1.maven.org/maven2/${coordinate.pathSegment}/${coordinate.fileName}',
      _ => '',
    };
    final userUrls = <String>[];
    for (final base in userRepos) {
      final normalized = base.endsWith('/')
          ? base.substring(0, base.length - 1)
          : base;
      userUrls.add(
        '$normalized/${coordinate.pathSegment}/${coordinate.fileName}',
      );
    }
    if (hostFor(coordinate.groupId) == MavenHost.vendor) {
      userUrls.forEach(add);
    }
    add(builtIn(MavenHost.google));
    add(builtIn(MavenHost.central));
    if (hostFor(coordinate.groupId) != MavenHost.vendor) {
      userUrls.forEach(add);
    }
    return output;
  }
}

class MavenMetadataParser {
  const MavenMetadataParser();

  MavenCoordinate? parent(String xml) {
    final match = RegExp(
      r'<parent>\s*<groupId>([^<]+)</groupId>\s*<artifactId>([^<]+)</artifactId>\s*<version>([^<]+)</version>',
    ).firstMatch(xml);
    return match == null
        ? null
        : MavenCoordinate(
            groupId: match.group(1)!,
            artifactId: match.group(2)!,
            version: match.group(3)!,
          );
  }

  Map<String, String> managedVersions(String xml) {
    final output = <String, String>{};
    final section = RegExp(
      r'<dependencyManagement>([\s\S]*?)</dependencyManagement>',
    ).firstMatch(xml)?.group(1);
    if (section == null) return output;
    for (final match in RegExp(
      r'<dependency>([\s\S]*?)</dependency>',
    ).allMatches(section)) {
      final body = match.group(1)!;
      final group = _tag(body, 'groupId');
      final artifact = _tag(body, 'artifactId');
      final version = _tag(body, 'version');
      if (group != null && artifact != null && version != null) {
        output['$group:$artifact'] = version;
      }
    }
    return output;
  }

  List<MavenCoordinate> imports(String xml) {
    final section = RegExp(
      r'<dependencyManagement>([\s\S]*?)</dependencyManagement>',
    ).firstMatch(xml)?.group(1);
    if (section == null) return const [];
    final output = <MavenCoordinate>[];
    for (final match in RegExp(
      r'<dependency>([\s\S]*?)</dependency>',
    ).allMatches(section)) {
      final body = match.group(1)!;
      if (!RegExp(r'<scope>\s*import\s*</scope>').hasMatch(body) ||
          !RegExp(r'<type>\s*pom\s*</type>').hasMatch(body)) {
        continue;
      }
      final group = _tag(body, 'groupId');
      final artifact = _tag(body, 'artifactId');
      final version = _tag(body, 'version');
      if (group != null && artifact != null && version != null) {
        output.add(
          MavenCoordinate(
            groupId: group,
            artifactId: artifact,
            version: version,
            packaging: 'pom',
          ),
        );
      }
    }
    return output;
  }

  Map<String, String> properties(String xml) {
    final section = RegExp(
      r'<properties>([\s\S]*?)</properties>',
    ).firstMatch(xml)?.group(1);
    if (section == null) return const {};
    final output = <String, String>{};
    for (final match in RegExp(
      r'<([a-zA-Z0-9._\-]+)>([^<]*)</([a-zA-Z0-9._\-]+)>',
    ).allMatches(section)) {
      output[match.group(1)!] = match.group(2)!.trim();
    }
    return output;
  }

  List<MavenCoordinate> moduleRuntimeDependencies(String text) {
    Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      return const [];
    }
    if (root is! Map<String, dynamic> || root['variants'] is! List) {
      return const [];
    }
    const excluded = [
      'ios',
      'macos',
      'tvos',
      'watchos',
      'linux',
      'mingw',
      'js',
      'wasm',
      'androidnative',
    ];
    final output = <MavenCoordinate>[];
    for (final value in root['variants'] as List) {
      if (value is! Map<String, dynamic>) continue;
      final name = (value['name'] as String? ?? '').toLowerCase();
      if (!name.contains('runtime') || excluded.any(name.contains)) continue;
      final dependencies = value['dependencies'];
      if (dependencies is! List) continue;
      for (final dependency in dependencies) {
        if (dependency is! Map<String, dynamic>) continue;
        final group = dependency['group'] as String? ?? '';
        final artifact = dependency['module'] as String? ?? '';
        final versionValue = dependency['version'];
        final version = versionValue is Map
            ? (versionValue['requires'] ??
                      versionValue['prefers'] ??
                      versionValue['strictly'] ??
                      '')
                  .toString()
            : versionValue is String
            ? versionValue
            : '';
        if (group.isNotEmpty &&
            artifact.isNotEmpty &&
            version.isNotEmpty &&
            !version.startsWith(r'${')) {
          output.add(
            MavenCoordinate(
              groupId: group,
              artifactId: artifact,
              version: version,
            ),
          );
        }
      }
    }
    return output;
  }

  List<MavenCoordinate> dependencies(String xml) {
    var scope = xml
        .replaceAll(
          RegExp(r'<dependencyManagement>[\s\S]*?</dependencyManagement>'),
          '',
        )
        .replaceAll(RegExp(r'<profiles>[\s\S]*?</profiles>'), '')
        .replaceAll(RegExp(r'<build>[\s\S]*?</build>'), '');
    final own = RegExp(
      r'<dependencies>([\s\S]*?)</dependencies>',
    ).allMatches(scope).map((match) => match.group(1)!).join('\n');
    if (own.isNotEmpty) scope = own;
    final output = <MavenCoordinate>[];
    for (final match in RegExp(
      r'<dependency>([\s\S]*?)</dependency>',
    ).allMatches(scope)) {
      final body = match.group(1)!;
      final dependencyScope = _tag(body, 'scope');
      if (const ['test', 'provided', 'system'].contains(dependencyScope) ||
          RegExp('<optional>true</optional>').hasMatch(body)) {
        continue;
      }
      final group = _tag(body, 'groupId');
      final artifact = _tag(body, 'artifactId');
      if (group == null ||
          artifact == null ||
          artifact.endsWith('-bom') ||
          artifact == 'bom') {
        continue;
      }
      var version = (_tag(body, 'version') ?? '').trim();
      if (version.startsWith('[') || version.startsWith('(')) {
        final match = RegExp(r'[\d][\d.]*').firstMatch(version);
        if (match == null) continue;
        version = match.group(0)!;
      }
      final type = _tag(body, 'type') ?? 'jar';
      final android =
          group.startsWith('androidx.') ||
          group.startsWith('com.android.') ||
          group.startsWith('com.google.android.') ||
          group.startsWith('ru.rustore.');
      output.add(
        MavenCoordinate(
          groupId: group.trim(),
          artifactId: artifact.trim(),
          version: version,
          packaging: android || type == 'aar' ? 'aar' : 'jar',
        ),
      );
    }
    return output;
  }

  String? _tag(String body, String tag) =>
      RegExp('<$tag>([^<]+)</$tag>').firstMatch(body)?.group(1);
}
