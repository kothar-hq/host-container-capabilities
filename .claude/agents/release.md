---
name: release
description: Use for release preparation — bumping the version, creating the release branch, and writing the changelog entry. Invoke when asked to bump the version, prepare a release, or start release work.
---

# Release

When asked to prepare a release or bump the version for this package:

1. **Ask for the bump type** if not given: `major`, `minor`, or `patch` (or an explicit `X.Y.Z`).

2. **Run the bump script** from the repo root:

   ```sh
   node scripts/bump-version.mjs <type>
   ```

   This updates `package.json`, `skills/host-container-capabilities/SKILL.md`, and `CHANGELOG.md`, then creates and checks out a `release/vX.Y.Z` branch.

3. **Verify consistency** by running `npm test`. The package test asserts all three files agree on the version.

4. **Write the changelog entry** — open `CHANGELOG.md` and replace the `<!-- TODO: add release notes -->` placeholder with bullet points describing what changed in this release. Use the git log since the previous version tag for reference.

5. **Commit** the three changed files together:

   ```sh
   git add package.json skills/host-container-capabilities/SKILL.md CHANGELOG.md
   git commit -m "Bump version to X.Y.Z"
   ```

6. **Push and open a PR** targeting `main`. The release workflow publishes to npm once the PR merges.

## Rules

- Never bump the version without running the script — editing the files by hand risks a mismatch.
- Never commit `package-lock.json` or any generated file as part of the version bump.
- Never publish manually; the CI release workflow handles that after the PR merges.
- If `npm test` fails after the script runs, something is wrong — do not proceed until it passes.
