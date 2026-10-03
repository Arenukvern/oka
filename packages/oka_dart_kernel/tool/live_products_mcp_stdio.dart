/// Product-families leg 2 (ADR-0035 §2e): live-patch an MCP server
/// (mcp_flutter's fmtk, `flutter_mcp_toolkit_server`) — a long-running
/// stdio product.
///
/// The server is spawned, the MCP handshake runs, one tool is called
/// (baseline response), then a unit delta is applied over the VM service:
///
/// 1. probe flip: a private helper in the server's own bin library;
/// 2. hold: the process pid — same stdio session, no restart;
/// 3. visible flip: the NEXT `tools/call` over the SAME stdio connection
///    returns the patched discovery diagnostics. No re-handshake.
///
/// Env: MCP_FLUTTER_ROOT, OKA_SDK_CHECKOUT, LIVE_PRODUCTS_PORT_MCP.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print, cancel_subscriptions, unused_local_variable, strict_raw_type

final home = Platform.environment['HOME']!;
final mcpRoot =
    Platform.environment['MCP_FLUTTER_ROOT'] ?? '$home/mcp/cline/mcp_flutter';
final port =
    int.parse(Platform.environment['LIVE_PRODUCTS_PORT_MCP'] ?? '8328');

const discoveryFile =
    'mcp_server_dart/lib/src/shared_core/vm_connections/connection_context.dart';
const binFile = 'mcp_server_dart/bin/flutter_mcp_toolkit_server.dart';

/// Minimal JSONL MCP client over a process' stdio.
class McpStdio {
  McpStdio(this._process) {
    _process.stdout
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen((line) {
      // The VM-service banner also lands on stdout — keep JSONL only.
      if (!line.startsWith('{')) return;
      final waiter = _waiter;
      if (waiter != null && !waiter.isCompleted) {
        _waiter = null;
        waiter.complete(line);
      } else {
        _pending.add(line);
      }
    });
  }

  final Process _process;
  final _pending = <String>[];
  Completer<String>? _waiter;

  Future<String> _nextLine() {
    if (_pending.isNotEmpty) {
      return Future.value(_pending.removeAt(0));
    }
    _waiter ??= Completer<String>();
    return _waiter!.future.timeout(const Duration(seconds: 30));
  }

  Future<void> send(Map<String, dynamic> msg) async {
    _process.stdin.writeln(jsonEncode(msg));
    await _process.stdin.flush();
  }

  /// Sends a request and resolves with the first response carrying [id].
  Future<Map<String, dynamic>> call(
      int id, Map<String, dynamic> request) async {
    await send({...request, 'jsonrpc': '2.0', 'id': id});
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final msg =
          jsonDecode(await _nextLine()) as Map<String, dynamic>;
      if (msg['id'] == id) {
        if (msg['error'] != null) {
          throw StateError('mcp error on id $id: ${msg['error']}');
        }
        return (msg['result'] ?? <String, dynamic>{}) as Map<String, dynamic>;
      }
    }
    throw TimeoutException('no MCP response for id $id');
  }

  Future<void> dispose() async {
    _process.kill();
  }
}

Future<String> _dartVersion(String dartBin) async {
  final r = await Process.run(dartBin, const ['--version']);
  final out = '${r.stdout}${r.stderr}';
  return RegExp(r'\d+\.\d+\.\d+').firstMatch(out)!.group(0)!;
}

String _toolText(Map<String, dynamic> result) {
  final content = (result['content'] as List? ?? const []).whereType<Map>();
  for (final c in content) {
    if (c['type'] == 'text') return c['text'] as String? ?? '';
  }
  return '';
}

Future<void> main() async {
  final dartBin = Platform.resolvedExecutable;
  final ver = await _dartVersion(dartBin);
  final checkout = Platform.environment['OKA_SDK_CHECKOUT'] ??
      '$home/xs/dart-sdks/sdk-$ver';
  final toolchain = await resolvePipelineToolchain(
    checkout: checkout,
    okaDartKernelRoot: File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory.systemTemp,
    appPackagesConfig: '$mcpRoot/.dart_tool/package_config.json',
  );

  final files = [File('$mcpRoot/$discoveryFile'), File('$mcpRoot/$binFile')];
  final originals = [for (final f in files) await f.readAsString()];
  final serverLog = StringBuffer();

  final server = await Process.start(
    dartBin,
    [
      '--enable-vm-service=$port/127.0.0.1',
      '--disable-service-auth-codes',
      'mcp_server_dart/bin/flutter_mcp_toolkit_server.dart',
      '--log-level',
      'error',
    ],
    workingDirectory: mcpRoot,
  );
  var failed = false;
  final mcp = McpStdio(server);
  try {
    final errSub = server.stderr
        .transform(const Utf8Decoder())
        .listen(serverLog.write);

    // MCP handshake — one session, never re-established.
    final init = await mcp.call(1, {
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-03-26',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'oka-live-products', 'version': '0.0.1'},
      },
    });
    final serverName =
        ((init['serverInfo'] ?? const <String, dynamic>{})
                as Map<dynamic, dynamic>)['name'] ?? '?';
    print('mcp-stdio: session open with $serverName (pid ${server.pid})');
    await mcp.send({'method': 'notifications/initialized'});

    // Baseline call: the discovery diagnostics are fmtk's own output.
    // Which strategy ran depends on the environment (a running flutter
    // app => machine_only; none => port_scan_flutter_filtered) — assert
    // only that nothing is patched yet.
    final before = _toolText(await mcp.call(2, <String, dynamic>{
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'fmt_discover_debug_apps',
        'arguments': <String, dynamic>{},
      },
    }));
    if (before.contains('_live_patched')) {
      throw StateError('baseline response already patched:\n$before');
    }
    print('mcp-stdio: baseline tools/call answered (unpatched)');

    // Two revisions, one stdio session (the endless-loop shape): rev 1
    // flips the per-call discovery diagnostics (visible to the MCP client),
    // rev 2 flips a helper in the server's bin library (the evaluate probe).
    final rev1 = await runLivePatch(
      LivePatchSpec(
        revision: 'fmtk-live-1',
        unit: 'fmtk_server',
        patches: [
          const PatchEdit(
            file: discoveryFile,
            find: """        'strategyUsed': 'machine_only',""",
            replace:
                """        'strategyUsed': 'machine_only_live_patched',""",
          ),
          // Which discovery branch runs depends on the environment; mark
          // both so the flip is visible either way.
          const PatchEdit(
            file: discoveryFile,
            find: """      'strategyUsed': 'port_scan_flutter_filtered',""",
            replace:
                """      'strategyUsed': 'port_scan_flutter_filtered_live_patched',""",
          ),
        ],
        targets: [TargetSpec.vmPort(port, id: 'fmtk-server')],
        probes: const [
          // Same pid = same process: the stdio session never dropped.
          ProbeSpec(
            library: 'bin/flutter_mcp_toolkit_server.dart',
            expression: 'io.pid',
            hold: true,
          ),
        ],
      ),
      compile: pipelineDeltaCompiler(toolchain),
      root: mcpRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    print(rev1.describe());
    if (!rev1.ok) throw StateError('rev1 refused');

    final after = _toolText(await mcp.call(3, <String, dynamic>{
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'fmt_discover_debug_apps',
        'arguments': <String, dynamic>{},
      },
    }));
    final visible = after.contains('_live_patched');
    print('mcp-stdio: same-session flip=$visible');
    if (!visible) throw StateError('patched response never arrived:\n$after');

    final rev2 = await runLivePatch(
      LivePatchSpec(
        revision: 'fmtk-live-2',
        unit: 'fmtk_server',
        patches: [
          const PatchEdit(
            file: binFile,
            find: '''
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
''',
            replace: r'''
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : '$trimmed+live';
''',
          ),
        ],
        targets: [TargetSpec.vmPort(port, id: 'fmtk-server')],
        probes: const [
          ProbeSpec(
            library: 'bin/flutter_mcp_toolkit_server.dart',
            expression: "_nonEmptyOption('oka') ?? 'null'",
            expect: 'oka+live',
          ),
          ProbeSpec(
            library: 'bin/flutter_mcp_toolkit_server.dart',
            expression: 'io.pid',
            hold: true,
          ),
        ],
      ),
      compile: pipelineDeltaCompiler(toolchain),
      root: mcpRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    print(rev2.describe());
    if (!rev2.ok) throw StateError('rev2 refused');

    print('mcp-stdio: live patch OK (one session, two revisions, 0 restarts)');
  } catch (e) {
    failed = true;
    print('mcp-stdio: FAILED — $e');
    print('-- server stderr tail --');
    final s = serverLog.toString();
    print(s.length > 2000 ? s.substring(s.length - 2000) : s);
  } finally {
    await mcp.dispose();
    for (var i = 0; i < files.length; i++) {
      await files[i].writeAsString(originals[i]);
    }
  }
  exit(failed ? 1 : 0);
}
