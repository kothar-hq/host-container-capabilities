# Changelog

Versions follow [semantic versioning](https://semver.org). The probe report has its own `schemaVersion`.

## 0.9.0

The first public release. The skill comes from [zippy1981/windows-nano-baseimages](https://github.com/zippy1981/windows-nano-baseimages), where it was called `host-capabilities`.

- The skill, with `Get-HostCapabilities.ps1` for Windows and `host-capabilities.sh` for Linux, macOS and WSL. Report schema version 1.
- The probe scripts live inside the skill. The project root is the git work tree around the current directory, or `HOST_CONTAINER_CAPABILITIES_ROOT`.
- The cache and overrides files are named `.claude/host-container-capabilities.*.local.json`.
- New overrides: `createdByLabel`, `sessionLabelKey` and `runnerContainerPattern`. The report repeats the labels in `policy`.
- An installer: `npx host-container-capabilities install`.
- Podman as a Linux engine (kind `podman`, and a `"linuxEngine": "podman"` override): tried after Docker, read with Podman's own `info` fields, and reported as `podman` where `docker` is the podman-docker shim.
- `linuxEngine.rootless` and `linuxEngine.selinux`, and the user and mount flags they call for.
- A `linuxEngine.reason` of `socket permission denied` when Docker is there but the user can't use its socket, and `no docker or podman CLI is installed` when there is no CLI.
- A Windows engine behind the docker CLI's current context fills in `windowsEngine` from Linux and macOS.
