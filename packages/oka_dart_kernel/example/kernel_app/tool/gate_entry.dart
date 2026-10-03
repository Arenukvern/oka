// Entrypoint for kernel gates — deliberately FLAT: plain (non-deferred)
// imports with direct calls, plus the sdk#64162 stress conditions
// (Function.apply, generic tear-off) on the unit side.
//
// Gates' kernel-level deferred-ization transform turns declared units into
// deferred ones at build time: flips LibraryDependency.DeferredFlag and
// inserts `await LoadLibrary(dep)` per unit at the start of main — no
// source changes.
import 'dart:io';
import '../lib/units/tiny.dart' as tiny;
import '../lib/units/greet.dart' as greet;

Future<void> main(List<String> args) async {
  stdout.writeln('core ok');
  stdout.writeln('direct:  ${tiny.tinyLabel()}');
  stdout.writeln('apply:   ${Function.apply(tiny.tinyLabel, [])}');
  stdout.writeln('tearoff: ${tiny.echo<int>(7)}');
  stdout.writeln('greet:   ${greet.greetLabel()}');
  stdout.writeln('GATE APP OK');
}
