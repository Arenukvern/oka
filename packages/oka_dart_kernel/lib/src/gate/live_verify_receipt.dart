import 'dart:convert';

import 'package:oka_update/oka_update.dart';

/// Parses JSON stdout from `oka live verify --json` and checks each declared
/// probe observation against its expected value (not merely exit 0 / banner OK).
bool assertLiveVerifyReceiptJson(
  String stdout, {
  required List<({String expression, String expect})> probes,
}) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(stdout.trim());
  } on Object {
    return false;
  }
  if (decoded is! Map) return false;
  final receipt = decoded.cast<String, dynamic>();
  if (receipt['ok'] != true) return false;
  final targets = receipt['targets'];
  if (targets is! List || targets.isEmpty) return false;

  final probeRows = <String, String>{};
  for (final t in targets) {
    if (t is! Map) continue;
    final rows = t['probes'];
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! Map) continue;
      final name = row['probe'];
      final after = row['after'];
      final ok = row['ok'];
      if (name is! String || after is! String) continue;
      if (ok != true) return false;
      probeRows[name] = after;
    }
  }

  for (final want in probes) {
    final observed = probeRows[want.expression];
    if (observed == null) return false;
    if (!probeObservationMatchesExpect(observed, want.expect)) return false;
  }
  return true;
}
