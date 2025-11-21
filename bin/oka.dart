#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:oka/src/cli/build_command.dart';
import 'package:oka/src/cli/clean_command.dart';
import 'package:oka/src/cli/dev_command.dart';
import 'package:oka/src/cli/doctor_command.dart';
import 'package:oka/src/cli/get_command.dart';
import 'package:oka/src/cli/init_command.dart';
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
        break;
      case 'build':
        await BuildCommand().run(commandArgs);
        break;
      case 'dev':
        await DevCommand().run(commandArgs);
        break;
      case 'doctor':
        await DoctorCommand().run(commandArgs);
        break;
      case 'clean':
        await CleanCommand().run(commandArgs);
        break;
      case 'get':
        await GetCommand().run(commandArgs);
        break;
      default:
        print('Unknown command: $command');
        _printUsage(parser);
        exit(1);
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
  build     Build APK or AAB
  dev       Start development mode with hot reload
  doctor    Check system requirements and configuration
  get       Install missing Android SDK dependencies
  clean     Clean build cache

Options:
${parser.usage}

Examples:
  oka init                    # Initialize oka.yaml from Gradle
  oka build apk --release     # Build release APK
  oka build apk --flutter     # Build Flutter APK (hybrid pipeline)
  oka dev                     # Start dev mode with hot reload
  oka doctor                  # Check system setup
  oka get r8                  # Install R8 optimizer

For more information, visit https://github.com/yourusername/oka
''');
}
