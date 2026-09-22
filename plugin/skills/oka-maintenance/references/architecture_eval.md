# Architecture behavior fixtures

Baseline: `steward validate skills/`. Structural validation is not behavior proof.

| Prompt | Required decision | Reject |
| --- | --- | --- |
| Refactor a 900-line cache command | Separate presentation, typed transactions, persistence; preserve contracts and apply checks | One equally broad service or LOC-only split |
| Reduce a cohesive 850-line generated parser | Establish a responsibility problem before editing | Mandatory size-only split |
| Add custom-platform cache inspection | Constructor-composed descriptive provider, no new deletion rights | Platform branches in generic CLI |
| Stop a borrowed PID-zero session | Explicit ownership contract; unknown is not dead | Delete because PID is zero |
| Add persisted cleanup plans | Simple repository first; advanced storage only for demonstrated need | Unnecessary Flutter/storage dependency |
| Plan architecture changes only | Review and plan without production edits | Begin refactoring |
| Implement an approved architecture plan | Bounded delegation, compatibility checks and independent review | Stop at a plan; claim runtime proof from mocks |

Forward-test an applicable fixture after substantial skill changes and record
observed choices/limits in dated repository evidence.
