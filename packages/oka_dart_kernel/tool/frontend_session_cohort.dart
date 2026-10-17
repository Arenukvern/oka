import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'frontend_protocol.dart';

Future<void> main(List<String> input) async {
  if (input.length != 2) {
    throw ArgumentError(
      'frontend_session_cohort.dart FLUTTER_SDK NEW_EVIDENCE',
    );
  }
  final sdk = Directory(input[0]).resolveSymbolicLinksSync();
  final destination = Directory(input[1]).absolute;
  if (destination.existsSync()) {
    throw StateError('Refusing to overwrite evidence');
  }
  destination.createSync(recursive: true);
  final root = destination.path;
  final package = File('$root/package_config.json')
    ..writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': <Object>[]}),
    );
  final unit = File('$root/unit.dart')
    ..writeAsStringSync('int value() => 1;\n');
  final entry = File('$root/main.dart')
    ..writeAsStringSync(
      "import 'unit.dart';\nvoid main() { print(value()); }\n",
    );
  final args = [
    '$sdk/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
    '--incremental',
    '--sdk-root=$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk',
    '--target=flutter',
    '--no-link-platform',
    '--packages=${package.path}',
    '--output-dill=$root/app.dill',
    '--output-incremental-dill=$root/delta.dill',
  ];
  final p = await Process.start(
    '$sdk/bin/cache/dart-sdk/bin/dartaotruntime',
    args,
    workingDirectory: root,
  );
  final lines = <String>[];
  final stderrLines = <String>[];
  final protocol = <String>[];
  final rows = <Map<String, Object?>>[];
  final outDone = Completer<void>();
  final errDone = Completer<void>();
  p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    lines.add(line);
    protocol.add('OUT $line');
  }, onDone: outDone.complete);
  p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    stderrLines.add(line);
    protocol.add('ERR $line');
  }, onDone: errDone.complete);
  var serial = 0;
  void send(String line) {
    protocol.add('IN $line');
    p.stdin.writeln(line);
  }

  Future<Map<String, Object?>> operation(
    String name,
    List<String> command, {
    bool artifact = true,
    int expectedErrors = 0,
  }) async {
    final start = lines.length;
    final sw = Stopwatch()..start();
    command.forEach(send);
    await p.stdin.flush();
    String? boundary;
    String? finalLine;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      for (final line in lines.skip(start)) {
        if (line.startsWith('result ')) boundary = line.substring(7).trim();
        if (boundary != null &&
            (line == boundary || line.startsWith('$boundary '))) {
          if (!artifact || line.startsWith('$boundary ')) finalLine = line;
        }
      }
      if (finalLine != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    sw.stop();
    if (finalLine == null) {
      throw TimeoutException('$name: ${lines.skip(start).toList()}');
    }
    final row = <String, Object?>{
      'name': name,
      'pid': p.pid,
      'elapsedMicros': sw.elapsedMicroseconds,
      'command': command,
      'stdout': lines.skip(start).toList(),
      'terminal': finalLine,
    };
    if (artifact) {
      final terminal = parseFrontendResult(lines.skip(start).join('\n'));
      if (terminal == null) throw StateError('Incomplete frontend terminal');
      final path = terminal.path;
      final error = terminal.errors;
      row['errors'] = error;
      if (error != expectedErrors) {
        throw StateError(
          '$name reported $error errors, expected $expectedErrors',
        );
      }
      row['emittedPath'] = path;
      if (File(path).existsSync()) {
        final copy = await File(path).copy('$root/${++serial}-$name.dill');
        final bytes = await copy.readAsBytes();
        row['retainedPath'] = copy.path;
        row['bytes'] = bytes.length;
        row['headerHex'] = bytes
            .take(16)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
      }
    }
    rows.add(row);
    print(jsonEncode(row));
    return row;
  }

  Future<void> edit(
    String name,
    String source, {
    bool accept = true,
    int expectedErrors = 0,
  }) async {
    unit.writeAsStringSync(source);
    final key = 'probe-${++serial}';
    await operation(name, [
      'recompile ${entry.uri} $key',
      unit.uri.toString(),
      key,
    ], expectedErrors: expectedErrors);
    if (accept) {
      send('accept');
      await p.stdin.flush();
    } else {
      await operation('$name-reject', ['reject'], artifact: false);
    }
  }

  var success = false;
  try {
    await operation('initial', ['compile ${entry.path}']);
    send('accept');
    await p.stdin.flush();
    await edit('method', 'int value() => 2;\n');
    entry.writeAsStringSync(
      "import 'unit.dart';\nvoid main() { print(value(3)); }\n",
    );
    unit.writeAsStringSync('int value(int x) => x + 2;\n');
    final key = 'probe-${++serial}';
    await operation('signature', [
      'recompile ${entry.uri} $key',
      entry.uri.toString(),
      unit.uri.toString(),
      key,
    ]);
    send('accept');
    await p.stdin.flush();
    await edit(
      'import',
      "import 'dart:math' as math;\nint value(int x) => math.max(x, 4);\n",
    );
    await edit(
      'syntax-error',
      'int value(int x) => ;\n',
      accept: false,
      expectedErrors: 1,
    );
    await edit('recovery', 'int value(int x) => x + 5;\n');
    await edit(
      'valid-rejected',
      'int value(int x) => x + 99;\n',
      accept: false,
    );
    await edit('after-reject', 'int value(int x) => x + 6;\n');
    send('reset');
    await p.stdin.flush();
    await edit('after-reset', 'int value(int x) => x + 7;\n');
    success = true;
  } finally {
    await p.stdin.close();
    int? exit;
    try {
      exit = await p.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      p.kill();
      try {
        exit = await p.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
        exit = await p.exitCode.timeout(const Duration(seconds: 5));
      }
    }
    await Future.wait([
      outDone.future,
      errDone.future,
    ]).timeout(const Duration(seconds: 5));
    File('$root/protocol.log').writeAsStringSync(protocol.join('\n'));
    File('$root/receipt.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'success': success,
        'pid': p.pid,
        'processExit': exit,
        'sdk': sdk,
        'args': args,
        'operations': rows,
        'stderr': stderrLines,
        'claim':
            'Compiler protocol only; no runtime reload or native UI launched.',
      }),
    );
  }
}
