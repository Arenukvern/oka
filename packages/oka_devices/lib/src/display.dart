/// How an emulator (or host display backing it) is presented.
library;

import 'package:meta/meta.dart';

/// Pixel geometry for a virtual X11 display.
@immutable
final class X11Geometry {
  const X11Geometry({
    required this.width,
    required this.height,
    this.depth = 24,
  });

  final int width;
  final int height;
  final int depth;

  List<String> validate({String prefix = 'display.geometry'}) {
    final problems = <String>[];
    if (width < 1) {
      problems.add('$prefix: width must be >= 1 (got $width)');
    }
    if (height < 1) {
      problems.add('$prefix: height must be >= 1 (got $height)');
    }
    if (depth < 8) {
      problems.add('$prefix: depth must be >= 8 (got $depth)');
    }
    return problems;
  }
}

/// Display mode for [EmulatorSpec].
sealed class Display {
  const Display();
}

/// Normal windowed emulator UI.
final class Windowed extends Display {
  const Windowed();
}

/// Headless boot (`-no-window` plus the EmulatorTarget headless bundle).
final class Headless extends Display {
  const Headless();
}

/// Virtual X11 display (e.g. Xvfb) identified by display number.
///
/// R4 must declare `DISPLAY=:<displayNumber>` in the provision plan env, not
/// only emulator argv.
final class VirtualX11 extends Display {
  const VirtualX11({required this.displayNumber, required this.geometry});

  final int displayNumber;
  final X11Geometry geometry;

  List<String> validate({String prefix = 'display'}) {
    final problems = <String>[];
    if (displayNumber < 0) {
      problems.add('$prefix: displayNumber must be >= 0 (got $displayNumber)');
    }
    problems.addAll(geometry.validate(prefix: '$prefix.geometry'));
    return problems;
  }
}
