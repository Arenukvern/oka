---
name: land
description: >-
  Land an explicitly requested change in the Oka repository using its direct-to-main
  workflow. Invoke this skill only when the user has requested landing or merging
  changes, including by choosing Delta's Land Changes action; do not invoke it for
  review, preparation, passing checks, or skill installation.
metadata:
  delta-action: land
---

# Land Oka changes

Use this skill only after the user has explicitly requested landing. The request
that invoked this skill already supplies merge intent; do not ask for permission
to land again.

This repository's configured Land workflow is direct-to-`main`, rather than a
pull request. Preserve unrelated work and stop on any ambiguity.

## 1. Inspect and prepare

1. Read the repository `AGENTS.md` and applicable nested instructions.
2. Inspect the current branch, upstream, worktree, and recent remote `main`:

   ```bash
   git --no-optional-locks status --short --branch
   git remote -v
   git fetch origin main
   git log -1 --oneline origin/main
   ```

3. Identify the requested change. Do not stage, commit, or discard files that
   are unrelated to it. If unrelated modifications are present and cannot be
   safely separated, stop and report that the change has not landed.
4. Work from a topic branch when possible. Never overwrite another user's work
   or force-push. If the current branch is `main` and it contains the requested
   uncommitted work, create a topic branch before committing.
5. Rebase the topic branch onto the latest `origin/main`. Resolve conflicts
   automatically only when the intended result is clear and unrelated content
   is preserved. Pause and report the conflict when intent is ambiguous or the
   resolution would be unsafe. Do not use an interactive rebase.

## 2. Run local gates

The repository's contributor guide requires lint, tests, and contract checks
before pushing (`CONTRIBUTING.md`; `docs/contributing/contribution_guide.mdx`).
Run them from the repository root:

```bash
just lint
just test
just check-contracts
```

Run `just install` only when dependencies are unavailable or dependency
manifests/lockfiles changed:

```bash
just install
```

If a gate fails, fix the requested change when the fix is unambiguous and
within scope, then rerun the affected gate. Otherwise stop and report the
failure. Do not treat a partial run or an earlier commit's result as current
evidence.

The exact recipes are defined in `justfile`. The repository's no-Gradle and
Android invariants in `AGENTS.md` remain binding; do not substitute
`flutter build apk` or Gradle for repository checks.

## 3. Commit and land

1. Review the staged diff and confirm it contains only the requested change.
2. Commit with a Conventional Commit title, following
   `docs/contributing/contribution_guide.mdx` (for example, `fix: ...`,
   `feat: ...`, `docs: ...`, or `chore: ...`).
3. Recheck that the commit is based on the latest `origin/main`, then push the
   commit directly:

   ```bash
   git push origin HEAD:main
   ```

   Never force-push. If the push is rejected because `main` changed, fetch and
   rebase again, preserving the conflict policy above. If branch protection,
   permissions, or another policy requires a pull request, stop and report that
   direct landing was blocked; do not create a PR as an unrequested fallback.

## 4. Verify the result

After the push:

1. Confirm the remote branch contains the exact commit:

   ```bash
   git fetch origin main
   git rev-parse HEAD
   git rev-parse origin/main
   ```

2. Inspect the push-triggered GitHub Actions runs with `gh`. Use the run for
   the landed commit, not an earlier commit:

   ```bash
   gh run list --branch main --commit <landed-sha> --limit 20
   gh run view <run-id> --json status,conclusion,url,jobs
   ```

   The CI workflow is defined in `.github/workflows/ci.yml`. Treat all
   applicable jobs as required: `test`, `android-real-smoke`, and `contracts`;
   `validate` applies when its pull-request condition is met, but a direct push
   does not run that job. A pending, failing, missing, or unverifiable required
   run is not success.
3. Report success only after the remote `main` commit matches the landed commit
   and the applicable CI runs conclude successfully. A prepared commit, pushed
   branch, or passing local gates alone is not a successful landing.

## Outcome reporting

When running in a subthread and `report_subthread_status` is available, report
the verified outcome to the parent. Use `status: "success"` only after the
commit reached `origin/main` and applicable CI passed. Include the short commit
SHA and verified CI URL. Use `status: "failure"` for rejected pushes, failed or
unverifiable checks, unresolved conflicts, or any other blocker, and state that
the change was not landed unless the remote verification proves otherwise.

If no subthread reporting tool is available, report the same outcome directly in
the current conversation. Never invent commit or CI URLs.
