#!/bin/sh
# host-capabilities.sh: report, as JSON, which container engines this host can use, and cache the answer
# (the host-container-capabilities skill).
#
#   host-capabilities.sh            print the cached report, probing first if it is missing or stale
#   host-capabilities.sh --refresh  probe again
#
# For Linux, macOS and WSL. On Windows (Git Bash, MSYS, Cygwin) it runs Get-HostCapabilities.ps1 instead.
# The project root is $HOST_CONTAINER_CAPABILITIES_ROOT, else the git work tree around the current directory,
# else the current directory. The report is cached in <root>/.claude/host-container-capabilities.<platform>.local.json.
# Overrides are read from <root>/.claude/host-container-capabilities.overrides.local.json, a flat JSON object with
# linuxEngine (auto, none, docker or podman), sharedHost (true), maxAgeHours (24), createdByLabel, sessionLabelKey and
# runnerContainerPattern. It never starts a daemon and installs nothing.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
refresh=0
case "${1:-}" in
    --refresh) refresh=1 ;;
    '') ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "host-capabilities.sh: unknown argument '$1'" >&2; exit 2 ;;
esac

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        if [ "$refresh" = 1 ]; then
            exec pwsh -NoProfile -File "$here/Get-HostCapabilities.ps1" -AsJson -Refresh
        fi
        exec pwsh -NoProfile -File "$here/Get-HostCapabilities.ps1" -AsJson
        ;;
    Darwin) platform=macos ;;
    *) if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl; else platform=linux; fi ;;
esac

if [ -n "${HOST_CONTAINER_CAPABILITIES_ROOT:-}" ]; then
    root=$(cd "$HOST_CONTAINER_CAPABILITIES_ROOT" && pwd)
elif root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    :
else
    root=$(pwd)
fi

schema=1
cache="$root/.claude/host-container-capabilities.$platform.local.json"
overrides="$root/.claude/host-container-capabilities.overrides.local.json"

# json_value <file> <key>: a top-level string, number or boolean from a flat JSON file (empty if absent)
json_value() {
    [ -f "$1" ] || return 0
    tr -d '\n\r' <"$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}[:space:]]*\).*/\1/p"
}
# js <value>: a JSON string, or null when empty
js() {
    if [ -z "$1" ]; then printf null; return; fi
    printf '"%s"' "$(printf '%s' "$1" | tr -d '\n\r\t' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
# jn <value>: a JSON number, or null when empty
jn() { if [ -z "$1" ]; then printf null; else printf '%s' "$1"; fi; }

ov_engine=$(json_value "$overrides" linuxEngine)
ov_shared=$(json_value "$overrides" sharedHost)
ov_age=$(json_value "$overrides" maxAgeHours)
ov_label=$(json_value "$overrides" createdByLabel)
ov_session=$(json_value "$overrides" sessionLabelKey)
ov_runners=$(json_value "$overrides" runnerContainerPattern)
: "${ov_engine:=auto}" "${ov_shared:=true}" "${ov_age:=24}"
: "${ov_label:=io.github.kothar-hq.created-by=agent}" "${ov_session:=io.github.kothar-hq.session}"
case "$ov_engine" in auto | none | docker | podman) ;; *)
    echo "host-capabilities.sh: override linuxEngine '$ov_engine' must be auto, none, docker or podman here" >&2; exit 2 ;;
esac
case "$ov_shared" in true | false) ;; *) echo "host-capabilities.sh: override sharedHost must be true or false" >&2; exit 2 ;; esac
case "$ov_age" in '' | *[!0-9]*) echo "host-capabilities.sh: override maxAgeHours must be a whole number" >&2; exit 2 ;; esac
case "$ov_label" in ?*=?*) ;; *) echo "host-capabilities.sh: override createdByLabel must be key=value" >&2; exit 2 ;; esac
case "$ov_session" in *=*) echo "host-capabilities.sh: override sessionLabelKey must be a label key, without '='" >&2; exit 2 ;; esac

now=$(date +%s)
if [ "$refresh" = 0 ] && [ -f "$cache" ] && [ -z "$(find "$overrides" -newer "$cache" 2>/dev/null)" ]; then
    cached_schema=$(json_value "$cache" schemaVersion)
    cached_epoch=$(json_value "$cache" probedAtEpoch)
    if [ "$cached_schema" = "$schema" ] && [ -n "$cached_epoch" ] && [ $((now - cached_epoch)) -lt $((ov_age * 3600)) ]; then
        cat "$cache"
        exit 0
    fi
fi

# The probes set p_os, p_version, p_osname, p_isolation, p_endpoint, p_rootless, p_selinux, p_total and p_mine,
# or p_error when the engine doesn't answer.
reset_probe() {
    p_os='' p_version='' p_osname='' p_isolation='' p_endpoint='' p_rootless='' p_selinux='' p_total='' p_mine='' p_error=''
}
# first_error <command...>: the first non-empty line the command prints on stderr
first_error() {
    p_error=$("$@" 2>&1 >/dev/null | sed -n '/./{p;q;}' || true)
    : "${p_error:=no output}"
}
count_containers() {
    p_total=$("$@" ps -aq 2>/dev/null | wc -l | tr -d ' ')
    p_mine=$("$@" ps -aq --filter "label=$ov_label" 2>/dev/null | wc -l | tr -d ' ')
}
# is_podman <cli>: true when the CLI is Podman, which includes the podman-docker shim named docker
is_podman() { "$1" --version 2>/dev/null | grep -qi podman; }

# probe_docker <docker command...>: asks a docker CLI about its engine
probe_docker() {
    reset_probe
    if ! out=$("$@" version --format '{{.Server.Os}}|{{.Server.Version}}' 2>/dev/null) || [ "${out#*|}" = "$out" ]; then
        first_error "$@" version --format '{{.Server.Os}}|{{.Server.Version}}'
        return 1
    fi
    p_os=${out%%|*} p_version=${out#*|}
    info=$("$@" info --format '{{.OperatingSystem}}|{{.Isolation}}' 2>/dev/null || true)
    p_osname=${info%%|*} p_isolation=${info#*|}
    security=$("$@" info --format '{{.SecurityOptions}}' 2>/dev/null || true)
    case "$security" in *rootless*) p_rootless=true ;; *) p_rootless=false ;; esac
    case "$security" in *selinux*) p_selinux=true ;; *) p_selinux=false ;; esac
    p_endpoint=$("$@" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    count_containers "$@"
}

# probe_podman <podman command...>: asks a Podman CLI about its engine, with Podman's own field names
probe_podman() {
    reset_probe
    format='{{.Host.OS}}|{{.Version.Version}}|{{.Host.Distribution.Distribution}} {{.Host.Distribution.Version}}|{{.Host.Security.Rootless}}|{{.Host.Security.SELinuxEnabled}}|{{.Host.RemoteSocket.Path}}'
    if ! out=$("$@" info --format "$format" 2>/dev/null) || [ "${out#*|}" = "$out" ]; then
        first_error "$@" info --format "$format"
        return 1
    fi
    IFS='|' read -r p_os p_version p_osname p_rootless p_selinux p_endpoint <<EOF
$out
EOF
    case "$p_rootless" in true | false) ;; *) p_rootless='' ;; esac
    case "$p_selinux" in true | false) ;; *) p_selinux='' ;; esac
    case "$p_endpoint" in /*) p_endpoint="unix://$p_endpoint" ;; esac
    count_containers "$@"
}

# Linux engine: Docker first (the docker CLI's current context: DOCKER_HOST, Docker Desktop, colima, a distro's own
# Docker), then Podman.
l_available=false l_kind='' l_invoke=null l_version='' l_osname='' l_endpoint='' l_rootless='' l_selinux=''
l_total='' l_mine='' l_reason='' l_tried='' l_denied=0
# A Windows engine behind the docker CLI's current context (DOCKER_HOST or a remote context)
remote_windows=0 rw_version='' rw_endpoint='' rw_isolation=''

add_tried() {
    entry="{\"kind\": \"$1\", \"distro\": null, \"error\": $(js "$2")}"
    if [ -n "$l_tried" ]; then l_tried="$l_tried, $entry"; else l_tried=$entry; fi
    case "$2" in *[Pp]ermission\ denied*) l_denied=1 ;; esac
}
found_linux() {
    l_available=true l_kind=$1 l_invoke="[\"$2\"]" l_version=$p_version l_osname=$p_osname l_endpoint=$p_endpoint
    l_rootless=$p_rootless l_selinux=$p_selinux l_total=$p_total l_mine=$p_mine
}
try_docker() {
    if ! command -v docker >/dev/null 2>&1; then add_tried docker 'docker CLI not installed'; return 1; fi
    if is_podman docker; then add_tried docker 'docker is the podman-docker shim'; return 1; fi
    if ! probe_docker docker; then add_tried docker "$p_error"; return 1; fi
    if [ "$p_os" = linux ]; then found_linux docker docker; return 0; fi
    if [ "$p_os" = windows ]; then
        remote_windows=1 rw_version=$p_version rw_endpoint=$p_endpoint rw_isolation=$p_isolation
    fi
    add_tried docker "it is a $p_os engine"
    return 1
}
try_podman() {
    cli=podman
    if ! command -v podman >/dev/null 2>&1; then
        if command -v docker >/dev/null 2>&1 && is_podman docker; then
            cli=docker
        else
            add_tried podman 'podman CLI not installed'
            return 1
        fi
    fi
    if ! probe_podman "$cli"; then add_tried podman "$p_error"; return 1; fi
    if [ "$p_os" = linux ]; then found_linux podman "$cli"; return 0; fi
    add_tried podman "it is a $p_os engine"
    return 1
}
case "$ov_engine" in
    none) l_reason='disabled by the linuxEngine override' ;;
    docker) try_docker || true ;;
    podman) try_podman || true ;;
    auto) try_docker || try_podman || true ;;
esac
if [ "$l_available" = false ] && [ -z "$l_reason" ]; then
    if [ "$l_denied" = 1 ]; then
        l_reason='socket permission denied'
    elif ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
        l_reason='no docker or podman CLI is installed'
    else
        l_reason='no candidate answered; see tried'
    fi
fi

# Windows engine: from WSL, through Windows' docker.exe. From anywhere, a remote one behind the docker CLI's
# current context. Podman can't run Windows containers.
w_available=false w_invoke=null w_endpoint='' w_version='' w_isolation='' w_runners='' w_reason=''
if [ "$platform" = wsl ] && command -v docker.exe >/dev/null 2>&1 && probe_docker docker.exe && [ "$p_os" = windows ]; then
    w_available=true w_invoke='["docker.exe"]' w_endpoint=$p_endpoint w_version=$p_version w_isolation=$p_isolation
    if [ -n "$ov_runners" ]; then
        w_runners=0
        for name in $(docker.exe ps -a --format '{{.Names}}' 2>/dev/null | tr -d '\r'); do
            # shellcheck disable=SC2254 # the override is a wildcard pattern
            case "$name" in $ov_runners) w_runners=$((w_runners + 1)) ;; esac
        done
    fi
    w_reason='per-LTSC isolation is only worked out on Windows: run Get-HostCapabilities.ps1 with pwsh.exe'
elif [ "$remote_windows" = 1 ]; then
    w_available=true w_invoke='["docker"]' w_endpoint=$rw_endpoint w_version=$rw_version w_isolation=$rw_isolation
    w_reason='a remote engine behind the docker context: per-LTSC isolation is not worked out, and bind mounts of this host do not work'
elif [ "$platform" != wsl ]; then
    w_reason="a $platform host has no Windows engine, and the docker context does not reach one"
elif ! command -v docker.exe >/dev/null 2>&1; then
    w_reason='docker.exe is not on the PATH (WSL interop off, or no Windows Docker)'
else
    if [ -n "$p_os" ]; then p_error="docker.exe reaches a $p_os engine"; fi
    w_reason="docker.exe: $p_error"
fi

gh=false gh_auth=false
if command -v gh >/dev/null 2>&1; then
    gh=true
    if gh auth status >/dev/null 2>&1; then gh_auth=true; fi
fi
if [ "$platform" = macos ]; then os=macos; else os=linux; fi

mkdir -p "$(dirname "$cache")"
cat >"$cache" <<EOF
{
  "schemaVersion": $schema,
  "probedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "probedAtEpoch": $now,
  "platform": "$platform",
  "overrides": {
    "linuxEngine": $(js "$ov_engine"),
    "sharedHost": $ov_shared,
    "maxAgeHours": $ov_age,
    "createdByLabel": $(js "$ov_label"),
    "sessionLabelKey": $(js "$ov_session"),
    "runnerContainerPattern": "$(printf '%s' "$ov_runners" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  },
  "policy": {
    "sharedHost": $ov_shared,
    "dockerDesktopSwitch": "never",
    "createdByLabel": $(js "$ov_label"),
    "sessionLabelKey": $(js "$ov_session")
  },
  "host": {
    "os": "$os",
    "caption": $(js "$(uname -sr)"),
    "build": null,
    "productType": null,
    "hypervisorPresent": null,
    "dockerDesktop": null
  },
  "windowsEngine": {
    "available": $w_available,
    "invoke": $w_invoke,
    "endpoint": $(js "$w_endpoint"),
    "serverVersion": $(js "$w_version"),
    "defaultIsolation": $(js "$w_isolation"),
    "ltsc": null,
    "runnerContainers": $(jn "$w_runners"),
    "reason": $(js "$w_reason")
  },
  "linuxEngine": {
    "available": $l_available,
    "kind": $(js "$l_kind"),
    "distro": $(js "$(if [ "$platform" = wsl ]; then printf '%s' "${WSL_DISTRO_NAME:-}"; fi)"),
    "invoke": $l_invoke,
    "endpoint": $(js "$l_endpoint"),
    "serverVersion": $(js "$l_version"),
    "operatingSystem": $(js "$l_osname"),
    "rootless": $(jn "$l_rootless"),
    "selinux": $(jn "$l_selinux"),
    "containers": $(jn "$l_total"),
    "claudeContainers": $(jn "$l_mine"),
    "repoPath": $(js "$root"),
    "reason": $(js "$l_reason"),
    "tried": [$l_tried]
  },
  "wsl": null,
  "github": {
    "gh": $gh,
    "authenticated": $gh_auth
  }
}
EOF
cat "$cache"
