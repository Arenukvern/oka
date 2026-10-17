#!/usr/bin/env dart
// Prints the "." version from .release-please-manifest.json (stdout).
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final root = args.isEmpty ? Directory.current.path : args.first;
  final file = File('$root/.release-please-manifest.json');
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final version = doc['.'];
  if (version is! String || version.trim().isEmpty) {
    stderr.writeln('read_manifest_version: invalid manifest');
    exit(1);
  }
  stdout.write(version.trim());
}
