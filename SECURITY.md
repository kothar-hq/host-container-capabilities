# Security policy

## Supported versions

Only the latest release gets fixes.

## Reporting a vulnerability

Report it privately through [GitHub's private vulnerability reporting](https://github.com/kothar-hq/host-container-capabilities/security/advisories/new). Please don't open a public issue.

## What the skill does on a host

The probe scripts are read-only. They run `docker version`, `docker info`, `docker context inspect`, `docker ps`, `wsl.exe --list` and `gh auth status`, and write one report file under the project's `.claude/` directory. They never start, stop or switch a daemon, install nothing, and keep nothing that `gh` prints. On Windows a probe boots stopped WSL distros.

Releases are published to npm from GitHub Actions with [provenance](https://docs.npmjs.com/generating-provenance-statements), so a package can be traced to the commit and workflow that built it.
