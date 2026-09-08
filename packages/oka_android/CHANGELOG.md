## 0.1.6

- Dependency-plan dry-run (`oka explain --deps`), artifact comparison gate
  (`oka compare`), single-step probe support (ADR-0007/0008).
- Conditional gradle dependency dedup (if/else variants collapse to the
  gradle default branch).
- Deterministic packaging: sorted d8 inputs and sorted zip entry order.
- archive ^4 support.

## 0.1.5

- Package split from the oka CLI (ADR-0006).
