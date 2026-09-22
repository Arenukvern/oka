import 'dart:convert';

import 'package:oka_core/oka_core.dart';

String
cacheInterfaceSchemaJson() => const JsonEncoder.withIndent('  ').convert({
  'schema_version': 'oka.cache.interface.v1',
  'description':
      'Global known-project cache inventory and explicit cleanup. JSON output is on stdout, failures on stderr.',
  'default_coverage':
      'Registered projects plus current cached project and shared storage. Use --scan to discover older projects.',
  'operations': [
    {
      'argv': ['oka', 'cache', '--json'],
      'description': 'Inspect storage and recommended next actions',
      'destructive': false,
      'options': [
        '--project PATH',
        '--global',
        '--scan ROOT (repeatable)',
        '--details',
        '--kind KIND (repeatable; diagnostics filter)',
        '--json',
      ],
    },
    {
      'argv': ['oka', 'cache', 'clean', '--json'],
      'description': 'Preview cleanup; no deletion by default',
      'destructive': false,
      'options': [
        '--project PATH',
        '--global',
        '--scan ROOT (repeatable)',
        '--scope build,shared,tools',
        '--older-than 30d',
        '--max-size 2GB',
        '--json',
        '--dry-run',
        '--save-plan FILE',
      ],
    },
    {
      'argv': ['oka', 'cache', 'clean', '--apply', '--json'],
      'description': 'Recalculate selection and delete eligible caches',
      'destructive': true,
    },
    {
      'argv': ['oka', 'cache', 'clean', '--apply-plan', 'FILE', '--json'],
      'description': 'Revalidate and delete only the saved selection',
      'destructive': true,
    },
    {
      'argv': ['oka', 'cache', 'clean', '--interactive'],
      'description': 'Terminal-only review and confirmation',
      'destructive': true,
    },
  ],
  'aliases': {'stats': 'overview', 'prune': 'clean'},
  'default_scopes': ['build', 'shared'],
  'preserved': [
    'SDKs',
    'emulator/simulator data',
    'browser profiles',
    'live or uncertain project sessions',
  ],
  'output_schemas': [
    'oka.cache.stats.v1',
    'oka.cache.prune.v1',
    'oka.cache.cleanup-plan.v1',
    CacheDiagnosticReport.schema,
  ],
  'diagnostics': {
    'kinds': [
      'project',
      'registry',
      'session',
      'emulator',
      'simulator',
      'runtime',
      'browser-profile',
    ],
    'observation_sources': ['recorded', 'filesystem', 'process'],
    'metadata':
        'Namespaced by provider ID; custom provider kinds are supported.',
    'runtime_probes': false,
    'actions':
        'Inert argv arrays with explicit cwd; not automatically executed.',
  },
});
