#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:oka/src/cli/build_command.dart';
import 'package:oka/src/cli/cache_command.dart';
import 'package:oka/src/cli/clean_command.dart';
import 'package:oka/src/cli/compare_command.dart';
import 'package:oka/src/cli/debug_command.dart';
import 'package:oka/src/cli/dev_command.dart';
import 'package:oka/src/cli/doctor_command.dart';
import 'package:oka/src/cli/explain_command.dart';
import 'package:oka/src/cli/get_command.dart';
import 'package:oka/src/cli/init_command.dart';
import 'package:oka/src/cli/launch_command.dart';
import 'package:oka/src/cli/run_command.dart';
import 'package:oka/src/version.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help')
    ..addFlag('version', abbr: 'v', negatable: false, help: 'Show version')
    ..addFlag('verbose', negatable: false, help: 'Verbose output');

  try {
    if (arguments.isEmpty) {
      _printUsage(parser);
      exit(0);
    }

    final command = arguments[0];
    final commandArgs = arguments.skip(1).toList();

    if (command == '--help' || command == '-h') {
      _printUsage(parser);
      exit(0);
    }

    if (command == '--version' || command == '-v') {
      final okaVersion = getOkaVersion();
      print('Oka version $okaVersion');
      exit(0);
    }

    switch (command) {
      case 'init':
        await InitCommand().run(commandArgs);
      case 'build':
        await BuildCommand().run(commandArgs);
      case 'dev':
        await DevCommand().run(commandArgs);
      case 'doctor':
        await DoctorCommand().run(commandArgs);
      case 'clean':
        await CleanCommand().run(commandArgs);
      case 'get':
        await GetCommand().run(commandArgs);
      case 'explain':
        await ExplainCommand().run(commandArgs);
      case 'compare':
        await CompareCommand().run(commandArgs);
      case 'debug':
        await DebugCommand().run(commandArgs);
      case 'launch':
        await LaunchCommand().run(commandArgs);
      case 'cache':
        await CacheCommand().run(commandArgs);
      case 'run':
        await RunCommand().run(commandArgs);
      default:
        // ADR-0015: unknown verbs load the project entrypoint and either
        // dispatch to a matching target or fail naming the available ones.
        await dispatchUnknownVerb(command, commandArgs);
    }
  } catch (e, stackTrace) {
    print('❌ Error: $e');
    if (arguments.contains('--verbose')) {
      print(stackTrace);
    }
    exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('''
Oka - AI-powered Flutter Android build system

Usage: oka <command> [options]

Commands:
  init      Initialize oka.yaml configuration from existing Gradle project
  explain   Show the validated build plan (no tools invoked)
  build     Build APK or AAB
  compare   Diff two APK/AAB artifacts (badging + zip entries; byte-equivalence gate)
  debug     Probe a single pipeline step (oka debug step <name>) or check
            DEX symbols (oka debug dex <apk> --find <class>)
  launch    Install + launch on device and scan logcat for failure signatures
  run       Run a project-declared target (oka run <target>; targets are
            discovered from tool/oka_pipeline.dart — `oka run` lists them)
  dev       Start development mode with hot reload
  doctor    Check system requirements and configuration
  get       Install missing Android SDK dependencies
  clean     Clean build cache

Options:
${parser.usage}

Examples:
  oka init                    # Initialize oka.yaml
  oka build apk               # No-Gradle Flutter debug APK (full plugins)
  oka build apk --release     # Release (AOT / libapp.so)
  oka compare old.apk new.apk # Diff artifacts (exit 1 on differences)
  oka debug step compile-and-dex  # Re-run one pipeline step on .oka_cache
  oka debug dex app.apk --find kotlinx.atomicfu.AtomicFU  # DEX symbol check
  oka launch                  # Install newest APK, launch, scan logcat
  oka run <target>            # Run a project-declared target (see above)
  oka get android-sdk         # Bootstrap packaging SDK
  oka doctor                  # Check system setup

For more information, visit https://github.com/yourusername/oka
''');
}
