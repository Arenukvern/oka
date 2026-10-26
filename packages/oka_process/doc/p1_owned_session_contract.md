# P1 owned-session contract (pointer)

The normative **p1** owned-session protocol (launcher argv, stderr bootstrap,
control channel, signal rules) is defined outside this repo until
[xsoulspace/dart_flutter_packages PR #5](https://github.com/xsoulspace/dart_flutter_packages/pull/5)
merges.

**Authoritative contract (pinned):**

- [owned_session_p1.md @ commit `2f9ce9b1`](https://github.com/xsoulspace/dart_flutter_packages/blob/2f9ce9b1/pkgs/xsoulspace_tooling_runtime/doc/owned_session_p1.md)

**Reference implementation and tests (same commit; not vendored yet):**

- Leader: [`tool/owned_session_p1_leader.pl`](https://github.com/xsoulspace/dart_flutter_packages/blob/2f9ce9b1/pkgs/xsoulspace_tooling_runtime/tool/owned_session_p1_leader.pl)
- Conformance suite: [`test/owned_session_p1_conformance_test.dart`](https://github.com/xsoulspace/dart_flutter_packages/blob/2f9ce9b1/pkgs/xsoulspace_tooling_runtime/test/owned_session_p1_conformance_test.dart)

After merge, this file will be **replaced** by a copy of `owned_session_p1.md`
with no semantic changes. Oka policy context remains in
[ADR-0052](../../../docs/decisions/0052-owned-process-sessions.mdx).

Local harness (pending suite copy):
`test/conformance/conformance_harness_test.dart`.
