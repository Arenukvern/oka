# Capability architecture

Use these roles within existing Oka packages, not mandatory app-style folders:
presentation -> typed transaction -> capability/repository -> host I/O. Pure
models and policy remain independent of presentation. Compose through constructors
or functions; no service locator or reactive framework is needed for a CLI.

## Decide where work belongs

- Commands parse, request transactions, render and confirm. Saved-plan files,
  discovery, selection and execution belong to application/repository capabilities.
- A transaction owns one operation's ordering and lifetime. Do not extract a giant
  command into an equally broad service. Keep state-machine transitions together;
  move transport/persistence/rendering behind narrow seams.
- Repositories own persisted conversion and read/write policy. Preserve atomic
  writes, locking, schemas and partial inspection versus strict mutation. Consider
  universal_storage for demonstrated advanced persistence needs and pure-Dart
  compatibility; simple file records need no framework.
- Platform adapters own metadata, readiness and graceful operations. Core owns
  shared identity/ownership/cleanup policy. Diagnostics never grants deletion rights.
- Type closed choices; retain intentional open extension keys such as diagnostic
  kinds. Prefer stable public exports and compatibility wrappers.

## Refactor by responsibility

Start with duplicate policy, divergent behavior and hidden I/O. LOC is advisory:
an 800-line parser can be cohesive; a 150-line facade can violate boundaries.
Do not split by arbitrary limits, hide one god class in `part` files, or move
unrelated functions into a generic utils folder.

Extract models/policy, repositories/capabilities, transactions, composition and
presentation as applicable. Correct lifecycle bugs separately from mechanical
moves. Preserve non-equivalent defaults and legacy entry points unless an explicit
decision changes them. Shared signatures and file ownership precede delegation.

## Acceptance

- Call operations from Dart without a CLI command, stdout parsing or executing
  project code. Substitute real I/O boundaries in tests.
- Preview uses a consistent measured snapshot; apply rechecks protections and
  reviewed selection. Unknown/live sessions remain protected.
- Execution handles cancellation before work, tears down once, disposes handlers
  and preserves forward failure. Failed/unverified stops retain leases/profiles.
- APK/AAB use one deterministic bytecode transaction; shuffled inputs and real
  no-Gradle builds verify complementary aspects.
- Extend existing recursive boundary checks and Steward actions. Report hotspots;
  fail on concrete forbidden dependencies/behavior, not file length.
