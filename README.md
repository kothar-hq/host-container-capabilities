# host-container-capabilities

An [agent skill](https://agentskills.io) that finds out which container engines a host has, and routes container work to a local engine or to CI.

Coding agents run on Windows hosts (some with WSL), on Linux and macOS, inside WSL, and in cloud sandboxes. An agent that assumes `docker` reaches a Linux engine gets it wrong on a Windows host in Windows-container mode, and one that "fixes" that by switching Docker Desktop stops every container on the host. This skill gives the agent a probed report instead:

- **Windows engine:** whether one answers, and the isolation (`process` or `hyperv`) that ltsc2019, ltsc2022 and ltsc2025 images need on this host build.
- **Linux engine:** the default WSL distro's own Docker, then other WSL 2 distros, then the default docker context, then an existing Docker Desktop Linux pipe. On Linux and macOS, the docker CLI's current context.
- **Routing:** run locally when the engine exists, otherwise offer the project's CI workflow.
- **Shared-host safety:** everything the agent creates is named and labelled, and only that is cleaned up. Docker Desktop is never switched, and no daemon is started or installed without asking.

The report is cached per project for 24 hours.

## Install

With the [skills CLI](https://skills.sh), from GitHub:

```sh
npx skills add kothar-hq/host-container-capabilities
```

From npm, with the installer in the package:

```sh
npx host-container-capabilities install            # into ./.claude/skills
npx host-container-capabilities install --global   # into ~/.claude/skills
npx host-container-capabilities install --dir .agents/skills
```

Or as a dev dependency, synced by the skills CLI:

```sh
npm install --save-dev host-container-capabilities
npx skills experimental_sync
```

Then add `.claude/*.local.json` to the project's `.gitignore`: the probe caches its report in `.claude/host-container-capabilities.<platform>.local.json`.

## Use

The agent loads the skill before container work. To read the report yourself:

```sh
sh .claude/skills/host-container-capabilities/scripts/host-capabilities.sh
```

```pwsh
.claude/skills/host-container-capabilities/scripts/Get-HostCapabilities.ps1 -AsJson
```

[SKILL.md](skills/host-container-capabilities/SKILL.md) describes the report's fields, the routing rules, the naming and labelling convention, and the per-host overrides file.

## Requirements

- Windows: PowerShell 7. Linux, macOS and WSL: a POSIX `sh`.
- The installer needs Node.js 20 or later. The skill itself doesn't need Node.
- Docker is the only container runtime probed today. Podman and others are tracked in the [issues](https://github.com/kothar-hq/host-container-capabilities/issues).

## Versions

0.9 is the first public release: the skill as it has been used in [zippy1981/windows-nano-baseimages](https://github.com/zippy1981/windows-nano-baseimages), made project-neutral. The report's `schemaVersion` is 1. 1.0 will follow once the report's fields are settled. See the [changelog](CHANGELOG.md).

## Develop

```sh
npm test          # node --test: the package, the installer, and the real probe for this platform
npm run lint:md   # markdownlint
```

CI also runs shellcheck, actionlint, PSScriptAnalyzer and CodeQL, and the tests on Linux, macOS and Windows. A change to `main` goes through a pull request.

A release is a pull request that changes `version` in `package.json`, in `SKILL.md` and in `CHANGELOG.md` (a test checks that they agree). Merging it runs the `release` workflow, which publishes to npm with provenance, and creates the `vX.Y.Z` tag and the GitHub release.

## Licence

[MIT](LICENSE)
