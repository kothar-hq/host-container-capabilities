---
name: bump-version
description: Bump the package version in all three canonical places (package.json, SKILL.md, CHANGELOG.md) and create a release branch. Load before starting any release or version-increment work.
---

# bump-version

Run `node scripts/bump-version.mjs <type>` from the repo root to increment the version and create a release branch.

## Arguments

| Argument | Effect |
| --- | --- |
| `patch` | 1.2.3 → 1.2.4 |
| `minor` | 1.2.3 → 1.3.0 |
| `major` | 1.2.3 → 2.0.0 |
| `X.Y.Z` | Set an explicit version |

## What it changes

| File | What changes |
| --- | --- |
| `package.json` | `version` field |
| `skills/host-container-capabilities/SKILL.md` | `metadata.version` in frontmatter |
| `CHANGELOG.md` | Adds a `## X.Y.Z` stub at the top with a `<!-- TODO: add release notes -->` placeholder |

It also creates and checks out a `release/vX.Y.Z` branch.

The script refuses to run with uncommitted changes in the working tree.

## After running

1. Fill in the `<!-- TODO: add release notes -->` placeholder in `CHANGELOG.md` with bullet points describing what changed.
2. Run `npm test` to verify all three files agree on the version.
3. `git add package.json skills/host-container-capabilities/SKILL.md CHANGELOG.md`
4. Commit with the message `Bump version to X.Y.Z`.
5. Push and open a PR.
