# oka_process

POSIX **owned process sessions** for the oka ecosystem
([ADR-0052](https://github.com/arenukvern/oka/blob/main/docs/decisions/0052-owned-process-sessions.mdx)).

Adopts dfp ADR-0066 rules as oka policy:

- **Identity before signal** (`pid` + start time + p1 marker/sid)
- Observed **group disappearance is final**
- **Unavailable observation is never death** — report *unsettled*

**Platforms:** Linux and macOS only. Windows is future work (see ADR).

## Status

| Piece | State |
| --- | --- |
| Types (identity, settlement, receipts, budgets) | Implemented |
| `posix-perl` backend | **Implemented** (p1 Perl leader) |
| `posix-native` backend | **Stub** — P1 (Rust helper under `native/`) |
| `oka_core` integration | **Follow-up** |

## Backends

- `posix-perl` — reference Perl leader (`tool/owned_session_p1_leader.pl`)
- `posix-native` — hash-pinned prebuilt helper (P1)

## p1 conformance

Normative contract: [`doc/p1_owned_session_contract.md`](doc/p1_owned_session_contract.md).

```bash
export OWNED_SESSION_P1_LEADER="$PWD/tool/owned_session_p1_leader.pl"
dart test
bash tool/run_p1_oka_probes.sh
bash tool/p1_matrix.sh   # per-host OS/arch cell
```

## Example

```bash
cd example && dart run main.dart
```

```dart
import 'package:oka_process/oka_process.dart';

final backend = PosixPerlProcessSessionBackend();
final handle = await backend.launch(
  const OwnedProcessLaunchSpec(executable: 'sleep', arguments: ['2']),
);
final receipt = await backend.stop(handle);
```

## Publishing

**Manual only** from the maintainer's Mac — not CI. See [`PUBLISHING.md`](PUBLISHING.md).
