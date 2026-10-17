/// Plain HTTP page attachment over the existing Chrome lifecycle target.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'browser_session_spec.dart';
import 'chrome_session_target.dart';

/// Replaceable execution seam; process ownership stays in the target.
typedef BrowserPageStepExecutor =
    Future<StepResult> Function(
      BuildStep step,
      BuildContext context,
      PipelineState state,
    );

/// Plain HTTP discovery seam, not a runtime CDP client.
typedef BrowserPageRequest = Future<String> Function(Uri uri, String method);

/// An attachment owns its created page, and only an Oka-spawned process.
/// No page activation or runtime automation occurs in this API.
final class BrowserPageSession {
  BrowserPageSession._({
    required this.pageWsUrl,
    required this.browserHttpUrl,
    required this.ownedProcess,
    required this._stop,
  });

  final String pageWsUrl;

  /// Discovery endpoint for composing another borrowed page attachment.
  /// This endpoint grants no process-stop ownership.
  final Uri browserHttpUrl;
  final bool ownedProcess;
  final Future<void> Function() _stop;
  Future<void>? _stopping;

  /// Concurrent and repeated stops share one bounded teardown result.
  Future<void> stop() => _stopping ??= _stop();
}

/// Launches/reuses Chrome through [ChromeSessionTarget], then creates one tab.
/// Default specifications are headless. Borrowed endpoints retain their other
/// tabs and process. [onStage] reports discovery timings, not app readiness.
///
/// The target owns provisioning and its boot deadline. A wrapper timeout cannot
/// cancel target process creation safely, so no competing startup timer is used.
Future<BrowserPageSession> startBrowserPageSession({
  required BuildContext context,
  required Uri appUrl,
  BrowserSessionSpec spec = const BrowserSessionSpec(),
  String? sessionName,
  void Function(String stage, Duration elapsed)? onStage,
  Duration requestTimeout = const Duration(seconds: 5),
  Duration stopTimeout = const Duration(seconds: 15),
  BrowserPageStepExecutor? executeStep,
  BrowserPageRequest? request,
}) async {
  if (!appUrl.hasScheme || appUrl.toString().isEmpty) {
    throw ArgumentError.value(appUrl, 'appUrl', 'Must be an absolute URI');
  }
  if (requestTimeout <= Duration.zero || stopTimeout <= Duration.zero) {
    throw ArgumentError('Request and stop timeouts must be positive');
  }
  final name = sessionName ?? 'page-${DateTime.now().microsecondsSinceEpoch}';
  final target = ChromeSessionTarget(spec: spec, sessionName: name);
  final state = PipelineState();
  final execute = executeStep ?? _execute;
  Future<String> fetch(Uri uri, String method) => (request == null
      ? _httpRequest(uri, method, requestTimeout)
      : request(uri, method).timeout(requestTimeout));
  Uri? base;
  String? tabId;
  Future<void>? stopping;
  Future<void> cleanup() async {
    final errors = <Object>[];
    final id = tabId;
    if (base != null && id != null) {
      try {
        await fetch(
          base.resolve('/json/close/${Uri.encodeComponent(id)}'),
          'GET',
        );
        // Chromium acknowledges initiation before the page necessarily closes.
        // Observe its removal; never replay a close whose effect is unknown.
        await (() async {
          final clock = Stopwatch()..start();
          while (clock.elapsed < stopTimeout) {
            final decoded = jsonDecode(
              await fetch(
                base!.resolve('/json/list'),
                'GET',
              ).timeout(stopTimeout - clock.elapsed),
            );
            if (decoded is! List) {
              throw StateError('Browser target discovery returned a non-list');
            }
            if (!decoded.any((target) => target is Map && target['id'] == id)) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          throw TimeoutException(
            'Browser page removal was not observed',
            stopTimeout,
          );
        })();
      } on Object catch (error) {
        errors.add(error);
      }
    }
    if (state[chromeSessionPidArtifactId(name)] is int) {
      try {
        for (final step in target.compileTeardown(context)) {
          final result = await execute(
            step,
            context,
            state,
          ).timeout(stopTimeout);
          if (!result.ok) {
            throw StateError(result.error ?? 'Browser teardown failed');
          }
        }
      } on Object catch (error) {
        errors.add(error);
      }
    }
    if (errors.isNotEmpty) {
      throw StateError(
        'Browser cleanup: ${errors.join('; ')}; process stop outcome may be unknown, existing ownership records are retained',
      );
    }
  }

  Future<void> stop() => stopping ??= cleanup();
  final watch = Stopwatch()..start();
  try {
    for (final step in target.compile(context)) {
      final result = await execute(step, context, state);
      if (!result.ok) throw StateError(result.error ?? 'Browser launch failed');
    }
    onStage?.call('browser-ready', watch.elapsed);
    final handle = state[chromeSessionHandleArtifactId(name)];
    if (handle is! String) {
      throw StateError('Browser target returned no HTTP handle');
    }
    base = Uri.parse(handle);
    if (!['http', 'https'].contains(base.scheme) || base.host.isEmpty) {
      throw StateError('Browser target returned an invalid HTTP handle');
    }
    final decoded = jsonDecode(
      await fetch(
        base.resolve('/json/new?${Uri.encodeComponent(appUrl.toString())}'),
        'PUT',
      ),
    );
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Browser page discovery returned a non-object');
    }
    final id = decoded['id'];
    if (id is! String || id.isEmpty) throw StateError('Browser page has no id');
    tabId = id; // retain ownership before checking the remaining response
    final socket = decoded['webSocketDebuggerUrl'];
    final ws = socket is String ? Uri.tryParse(socket) : null;
    if (ws == null || !['ws', 'wss'].contains(ws.scheme) || ws.host.isEmpty) {
      throw StateError('Browser page has no valid websocket attachment');
    }
    onStage?.call('page-attached', watch.elapsed);
    return BrowserPageSession._(
      pageWsUrl: socket as String,
      browserHttpUrl: base,
      ownedProcess: state[chromeSessionPidArtifactId(name)] is int,
      stop: stop,
    );
  } on Object catch (error, stack) {
    try {
      await stop();
    } on Object catch (cleanupError) {
      Error.throwWithStackTrace(
        StateError('Browser startup failed: $error; $cleanupError'),
        stack,
      );
    }
    Error.throwWithStackTrace(error, stack);
  }
}

Future<StepResult> _execute(
  BuildStep step,
  BuildContext context,
  PipelineState state,
) => step.run(context, state);

Future<String> _httpRequest(Uri uri, String method, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await (() async {
      final request = await client.openUrl(method, uri);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Browser HTTP ${response.statusCode}: $body',
          uri: uri,
        );
      }
      return body;
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
