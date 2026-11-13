---
name: host-container-capabilities
description: Find out which container engines this host has (a Windows engine for Windows containers, a Linux engine such as a WSL distro's own Docker, both, or neither) and route container work to a local engine or to CI. Use before any docker command, before building or testing an image, before running Linux tools such as shellcheck or actionlint in a container, or when asked whether this machine can run Linux or Windows containers.
license: MIT
metadata:
  version: "0.9.1"
  repository: https://github.com/kothar-hq/host-container-capabilities
---

# Host container capabilities

Coding agents run on Windows hosts (some with WSL), on Linux and macOS, inside WSL, and in cloud sandboxes. Don't assume which engines exist. Read the probe's report, then route the task.

The probe scripts are in this skill's `scripts/` directory, next to this file. Below, `<skill>` is the directory that holds this `SKILL.md`.

## 1. Read the report

| Shell | Command |
| --- | --- |
| PowerShell (Windows) | `<skill>/scripts/Get-HostCapabilities.ps1 -AsJson` |
| Bash or sh (any OS; Git Bash hands off to the PowerShell script) | `sh <skill>/scripts/host-capabilities.sh` |

Run it from inside the project. The project root is the git work tree around the current directory, or `HOST_CONTAINER_CAPABILITIES_ROOT` if that's set.

A cached report is reused for 24 hours, so it's cheap to read again. Probe again (`-Refresh`, or `--refresh` for the sh script) when a docker command can't reach its engine, when the user says something on the host changed, or before telling the user the host can't do something. On Windows a fresh probe boots WSL distros, one after another, until one has a working Docker.

The fields that decide things:

| Field | Meaning |
| --- | --- |
| `platform` | `windows`, `wsl` (the agent is running inside WSL), `linux` or `macos` |
| `windowsEngine.available`, `.invoke` | Whether a Windows engine answers, and the command that reaches it (`docker`, or `docker.exe` from inside WSL) |
| `windowsEngine.ltsc.<2019\|2022\|2025>.isolation` | `process`, `hyperv`, or `null` when that Windows version's images can't run here. Only filled in on Windows. |
| `linuxEngine.available`, `.invoke` | Whether a Linux engine answers, and the command that reaches it, for example `["wsl.exe","--distribution","Ubuntu","--exec","docker"]` |
| `linuxEngine.repoPath` | The project's path as the Linux engine's host sees it, for bind mounts |
| `linuxEngine.containers` minus `.claudeContainers` | Containers that belong to someone else (the user's devcontainers, CI runners). Leave them alone. |
| `linuxEngine.reason`, `.tried` | Why there's no Linux engine, and what was tried |
| `policy.sharedHost` | `true` unless the user overrode it. Shared means strict cleanup (section 4). |
| `policy.createdByLabel`, `.sessionLabelKey` | The labels to put on everything you create (section 4) |
| `github.authenticated` | Whether `gh` can dispatch workflows |

## 2. Route the task

If the project has its own routing table (in `CLAUDE.md`, `AGENTS.md` or its docs), follow it. Otherwise:

| Task | Run locally when | Otherwise |
| --- | --- | --- |
| Build or test a Windows container image | `windowsEngine.available`, and that Windows version's `isolation` isn't `null`. Pass `--isolation <value>`. Hyper-V isolated builds default to 1 GB of memory, so pass `--memory 4g` or more. | The project's CI workflow for that image |
| Build or test a Linux container image | `linuxEngine.available` | The project's CI workflow for that image |
| Linux tools in a container (shellcheck, actionlint, a build script) | `linuxEngine.available`, with the tool version CI uses | The project's lint or build workflow |
| A release, or anything published | Never locally, unless the project says otherwise | The project's release workflow |
| Tools that need no container (PSScriptAnalyzer, Pester, npm scripts) | Any host that has the tool | CI |

Dispatching a workflow is outward-facing, so ask before `gh workflow run`. If `github.authenticated` is false, ask the user to log in with `gh auth login`. Never handle tokens.

## 3. Run on the engine

Use `invoke` exactly as the report gives it, with the docker arguments after it.

```pwsh
$report = <skill>/scripts/Get-HostCapabilities.ps1
$linux = $report.linuxEngine
& $linux.invoke[0] @($linux.invoke | Select-Object -Skip 1) run --rm --name agent-lint-3f9a `
    --label $report.policy.createdByLabel --label "$($report.policy.sessionLabelKey)=3f9a" `
    --volume "$($linux.repoPath):/src:ro" --workdir /src rhysd/actionlint:1.7.12 -color
```

- **Prefer PowerShell on Windows.** Git Bash rewrites arguments that look like paths (`/src` becomes `C:/Program Files/Git/src`), so in Bash prefix the command with `MSYS_NO_PATHCONV=1`.
- **`--exec` runs docker without a shell** inside the distro. Don't pass `bash -lc '...'` through `wsl.exe`: the quoting breaks and `$variables` are expanded in the wrong place.
- **`/mnt/c` is slow.** That's fine for linters and for reading the project. For a real build, copy the sources into the container or a Linux directory instead of building on the bind mount.
- **Line endings:** a shell script checked out with CRLF fails in a Linux container. Check that `.gitattributes` keeps `*.sh` LF before running the project's scripts from a Windows checkout.
- **Registry pulls:** if a pull is denied, the image is private, and logging in is the user's call.

## 4. Name, label and clean up

On a shared host (`policy.sharedHost`, the default), everything you create carries:

- a name `agent-<task>-<tag>`, where `<tag>` is 4 hex characters you pick once per session
- `--label <policy.createdByLabel> --label <policy.sessionLabelKey>=<tag>`, on `docker run`, `docker create` and `docker build`

Prefer images that are already present (`docker images`). If you pull one, note that it wasn't there before, and remove exactly that reference when you're done.

Clean up only what carries your session's label, on the engine you created it on:

```sh
docker ps -aq --filter label=<policy.sessionLabelKey>=<tag> | xargs -r docker rm -f
docker images -q --filter label=<policy.sessionLabelKey>=<tag> | xargs -r docker rmi
```

Never `docker system prune`, `docker image prune` or `docker builder prune` on a shared host.

## 5. When an engine is missing

- **No Linux engine, but WSL is installed** (`linuxEngine.tried` names the distros): offer to install Docker Engine in the distro, or to start its daemon if `tried` says it isn't reachable. Both are host changes, so ask first. Otherwise, offer the CI workflow.
- **No Linux engine and no WSL** (Windows without WSL, or a Linux or macOS host without Docker): offer the CI workflow, or report what's missing.
- **No Windows engine** (Linux, macOS, or a cloud sandbox): Windows container images can only be built in CI, on a Windows runner. Don't try workarounds.

## 6. Never

- Switch Docker Desktop between Windows and Linux containers, on any host. `policy.dockerDesktopSwitch` is always `never`: switching stops every container on the engine that's switched away from.
- Run `wsl --shutdown` or `wsl --terminate`. They stop the user's devcontainers.
- Start, stop or reconfigure a daemon, or install software, without asking.
- Touch containers or images you didn't create, on either engine.

## Overrides

Per host, in `.claude/host-container-capabilities.overrides.local.json` in the project, which should be gitignored. It's a flat JSON object. Any key can be left out.

```json
{
  "linuxEngine": "wsl:Ubuntu",
  "sharedHost": true,
  "maxAgeHours": 24,
  "createdByLabel": "io.github.kothar-hq.created-by=agent",
  "sessionLabelKey": "io.github.kothar-hq.session",
  "runnerContainerPattern": "my-runner-*"
}
```

- `linuxEngine`: `auto` (the default), `none`, `wsl:<distro>` (Windows only), `docker` (the default docker context, if it's a Linux engine), or `docker-desktop-linux` (Windows only: Docker Desktop's Linux engine pipe, if it already exists; it's never switched to)
- `sharedHost`: set `false` only on a host that nothing else uses
- `maxAgeHours`: how long a report is reused
- `createdByLabel`, `sessionLabelKey`: the labels from section 4, for a project that already has a labelling convention
- `runnerContainerPattern`: a wildcard for CI runner containers on the Windows engine. `windowsEngine.runnerContainers` counts the matches, and is `null` when the pattern is empty.

Editing the overrides file invalidates the cache. Reports are kept in `.claude/host-container-capabilities.<platform>.local.json`, one per platform, so a Windows session and a WSL session on the same checkout don't overwrite each other. Add `.claude/*.local.json` to the project's `.gitignore`.
