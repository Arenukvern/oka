import 'dart:convert';

final class DevEvent {
  DevEvent(this.name, this.data, {DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now().toUtc();

  final String name;
  final Map<String, Object?> data;
  final DateTime timestamp;
}

// A renderer is an injectable presentation capability, not a utility.
// ignore: one_member_abstracts
abstract interface class DevEventRenderer {
  Iterable<String> render(DevEvent event);
}

final class JsonDevEventRenderer implements DevEventRenderer {
  const JsonDevEventRenderer();

  @override
  Iterable<String> render(DevEvent event) sync* {
    yield jsonEncode({
      'scope': 'dev',
      'event': event.name,
      'params': event.data,
      'timestamp': event.timestamp.toIso8601String(),
    });
  }
}

final class HumanDevEventRenderer implements DevEventRenderer {
  const HumanDevEventRenderer({this.verbose = false});

  final bool verbose;

  @override
  Iterable<String> render(DevEvent event) sync* {
    switch (event.name) {
      case 'session.start':
        yield '🚀 oka dev — attach session on ${event.data['device']} '
            '(target=${event.data['target']}, mode=${event.data['mode']})';
        yield '   r hot reload · R hot restart (state loss) · q quit · d detach';
      case 'session.ready':
        yield '✅ Connected. Session commands ready.';
      case 'operation.start':
        yield '🔁 ${event.data['label']}…';
      case 'operation.success':
        yield '✅ ${event.data['label']} complete.';
      case 'operation.failure':
        yield '❌ ${event.data['label']} failed: ${event.data['error']}\n'
            '   fix: ${event.data['fix']}';
      case 'daemon.app.progress':
        if (event.data['finished'] != true) {
          yield '⏳ ${event.data['message'] ?? 'app.progress'}';
        }
      case 'daemon.app.started':
        yield '✅ App started.';
      case 'daemon.app.reloadRecommended':
        final reason = event.data['reason'] ?? 'files changed outside the session';
        yield '💡 flutter_tools recommends a reload ($reason).\n'
            '   → press `r` (or send `reload` with --json).';
      case 'daemon.app.debugPort' ||
          'daemon.app.devTools' ||
          'daemon.app.dtd' ||
          'daemon.daemon.connected':
        if (verbose) yield '[daemon] ${event.name.substring(7)}: ${event.data}';
      case 'daemon.app.stop' || 'daemon.app.start':
        break;
      default:
        if (event.name.startsWith('daemon.') && verbose) {
          yield '[daemon] ${event.name.substring(7)}: ${event.data}';
        }
    }
  }
}
