// The SDK checkout resolution convention: OKA_SDK_CHECKOUT wins, the
// oka-owned `~/.oka/dart-sdks` home is the default, and a legacy
// `~/xs/dart-sdks` checkout is honored read-only (ADR-0032 toolchain).
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('OKA_SDK_CHECKOUT overrides every convention', () {
    final result = defaultSdkCheckout(
      '3.13.4',
      environment: {'OKA_SDK_CHECKOUT': '/anywhere/sdk'},
      home: '/nonexistent-home',
    );
    expect(result, '/anywhere/sdk');
  });

  test('defaults to ~/.oka/dart-sdks and provisions there when empty',
      () async {
    final home = await Directory.systemTemp.createTemp('oka_sdk_home');
    try {
      final result = defaultSdkCheckout(
        '3.13.4',
        environment: const {},
        home: home.path,
      );
      expect(
        result,
        '${home.path}/.oka/dart-sdks/sdk-3.13.4',
      );
    } finally {
      await home.delete(recursive: true);
    }
  });

  test('honors a legacy ~/xs/dart-sdks checkout read-only', () async {
    final home = await Directory.systemTemp.createTemp('oka_sdk_home');
    try {
      final legacy = Directory(
        '${home.path}/xs/dart-sdks/sdk-3.13.4',
      );
      await legacy.create(recursive: true);
      final result = defaultSdkCheckout(
        '3.13.4',
        environment: const {},
        home: home.path,
      );
      expect(result, legacy.path);
    } finally {
      await home.delete(recursive: true);
    }
  });

  test('prefers ~/.oka when both homes have a checkout', () async {
    final home = await Directory.systemTemp.createTemp('oka_sdk_home');
    try {
      await Directory(
        '${home.path}/.oka/dart-sdks/sdk-3.13.4',
      ).create(recursive: true);
      await Directory(
        '${home.path}/xs/dart-sdks/sdk-3.13.4',
      ).create(recursive: true);
      final result = defaultSdkCheckout(
        '3.13.4',
        environment: const {},
        home: home.path,
      );
      expect(result, '${home.path}/.oka/dart-sdks/sdk-3.13.4');
    } finally {
      await home.delete(recursive: true);
    }
  });
}
