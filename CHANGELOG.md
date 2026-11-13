# Changelog

Versions follow [semantic versioning](https://semver.org). The probe report has its own `schemaVersion`.

## 0.9.1

The first automated release by CI

## 0.9.0

The first public release. The skill comes from [zippy1981/windows-nano-baseimages](https://github.com/zippy1981/windows-nano-baseimages), where it was called `host-capabilities`.

- The skill, with `Get-HostCapabilities.ps1` for Windows and `host-capabilities.sh` for Linux, macOS and WSL. Report schema version 1.
- The probe scripts live inside the skill. The project root is the git work tree around the current directory, or `HOST_CONTAINER_CAPABILITIES_ROOT`.
- The cache and overrides files are named `.claude/host-container-capabilities.*.local.json`.
- New overrides: `createdByLabel`, `sessionLabelKey` and `runnerContainerPattern`. The report repeats the labels in `policy`.
- The npm package is `@kothar-hq/host-container-capabilities`. Its installer: `npx @kothar-hq/host-container-capabilities install`.
