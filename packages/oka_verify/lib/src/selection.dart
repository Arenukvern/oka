/// Suite selection for the oka verify lane (ADR-0048).
///
/// The selection is a pure function: given the suites of a package, the
/// suites a change reaches, and the operator's filters, it names the set
/// to check. Keeping it pure is what makes "select parity" a testable
/// property instead of a hope.
///
/// The rules, in order:
///
/// 1. `--all` selects every suite.
/// 2. `--only <substring>` selects the suites whose path contains the
///    substring; an empty match is an error, never an empty run.
/// 3. Unknown dependency coverage (see `analyzeCoverage`) widens the run
///    to every suite — broader checks instead of a skipped check.
/// 4. Otherwise the suites a change reaches are selected.
/// 5. No change reaches any suite: everything is selected, because "no
///    suite is affected" is not the same claim as "the work is verified".
library;

/// The suites one verify run checks, and why.
final class VerifySelection {
  const VerifySelection({required this.suites, this.broadenReason});

  /// The suites to check.
  final List<String> suites;

  /// Why the run was widened, or null when it was not.
  final String? broadenReason;

  /// True when the run was widened beyond the affected suites.
  bool get broadened => broadenReason != null;
}

/// A selection that cannot be made: no suite matches, or the package has
/// no runnable suite.
final class SelectionError implements Exception {
  SelectionError(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'SelectionError: $message';
}

/// The inputs of a selection.
final class SelectionRequest {
  const SelectionRequest({
    required this.allSuites,
    required this.affectedSuites,
    this.onlyFilters = const <String>[],
    this.all = false,
    this.broadenReason,
  });

  /// Every suite of the package under test.
  final List<String> allSuites;

  /// The suites whose import closure reaches a changed file.
  final Set<String> affectedSuites;

  /// The operator's `--only` filters (substrings of the suite path).
  final List<String> onlyFilters;

  /// True when the operator asked for every suite.
  final bool all;

  /// Why the coverage is unknown, or null when it is known.
  final String? broadenReason;
}

/// Selects the suites to check. Throws [SelectionError] when the filters
/// match nothing.
VerifySelection selectSuites(SelectionRequest request) {
  final all = request.allSuites;
  final List<String> picked;
  if (request.all) {
    picked = all;
  } else if (request.onlyFilters.isNotEmpty) {
    picked = [
      for (final suite in all)
        if (request.onlyFilters.any(suite.contains)) suite,
    ];
    if (picked.isEmpty) {
      throw SelectionError('no suite matches --only ${request.onlyFilters}');
    }
  } else if (request.broadenReason != null) {
    picked = all;
  } else if (request.affectedSuites.isNotEmpty) {
    picked = request.affectedSuites.toList()..sort();
  } else {
    picked = all;
  }
  return VerifySelection(suites: picked, broadenReason: request.broadenReason);
}
