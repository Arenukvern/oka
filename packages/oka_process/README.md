# oka_process

POSIX **owned process sessions** for the oka ecosystem
([ADR-0052](https://github.com/arenukvern/oka/blob/main/docs/decisions/0052-owned-process-sessions.mdx)).

Adopts dfp ADR-0066 rules as oka policy:

- **Identity before signal** (`pid` + start time)
- Observed **group disappearance is final**
- **Unavailable observation is never death** — report *unsettled*

**Platforms:** Linux and macOS only. Windows is future work (see ADR).

## Status

| Piece | State |
| --- | --- |
| Types (identity, settlement, receipts, budgets) | Implemented |
| `posix-perl` backend | **Stub** — P0 (dfp contract migration) |
| `posix-native` backend | **Stub** — P1 (Rust helper under `native/`) |
| `oka_core` integration | **Follow-up** after P0 |

## Backends

- `posix-perl` — reference Perl leader (P0)
- `posix-native` — hash-pinned prebuilt helper (P1)

## Example

```bash
cd example && dart run main.dart
```

```dart
import 'package:oka_process/oka_process.dart';

final backend = PosixPerlProcessSessionBackend();
// launch() / stop() throw UnsupportedError until P0 is implemented.
```

Contract placeholder: [`doc/p1_owned_session_contract.md`](doc/p1_owned_session_contract.md).

## Publishing

**Manual only** from the maintainer's Mac — not CI. See [`PUBLISHING.md`](PUBLISHING.md).
