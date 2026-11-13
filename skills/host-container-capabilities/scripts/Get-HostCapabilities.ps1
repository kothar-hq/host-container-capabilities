<#
.SYNOPSIS
Reports which container engines this host can use (a Windows engine, a Linux engine, both or neither), and caches
the answer for 24 hours.

.DESCRIPTION
The host-container-capabilities skill runs this before any container work, and routes each task to a local engine
or to CI.

On Windows it checks:
- the Windows engine behind the default docker context: its version, default isolation, and the isolation each of
  ltsc2019, ltsc2022 and ltsc2025 needs on this host build
- a Linux engine, in this order: the default WSL distro's own Docker, any other WSL 2 distro's Docker (the
  docker-desktop distros are skipped), the default docker context if it is a Linux engine, Docker Desktop's
  Linux engine pipe if it already exists, then Podman in each WSL 2 distro (which includes Podman Desktop's
  podman-machine distros) and the native podman CLI. It stops at the first that answers. Probing a stopped WSL
  distro boots it.
- gh, and whether it is logged in (the exit code only; nothing it prints is kept)

It never switches Docker Desktop between Windows and Linux containers, never starts a daemon, and installs nothing.

The project root is $env:HOST_CONTAINER_CAPABILITIES_ROOT if set, otherwise the git work tree that contains the
current directory, otherwise the current directory.

The report is cached in <root>/.claude/host-container-capabilities.windows.local.json, which should be gitignored.
A cached report is reused until it is older than maxAgeHours, the overrides file is newer than it, or -Refresh is
given. Overrides are read from <root>/.claude/host-container-capabilities.overrides.local.json, a flat JSON object:
  linuxEngine             'auto' (default), 'none', 'wsl:<distro>' (Docker, then Podman, in that distro), 'docker'
                          (the default docker context), 'docker-desktop-linux' or 'podman' (the native podman CLI)
  sharedHost              true (default). Set false only on a host that nothing else uses.
  maxAgeHours             24 (default)
  createdByLabel          the key=value label the agent puts on everything it creates
                          (default 'io.github.kothar-hq.created-by=agent')
  sessionLabelKey         the label key that carries the session tag (default 'io.github.kothar-hq.session')
  runnerContainerPattern  a wildcard for the names of CI runner containers on the Windows engine, which are counted
                          in windowsEngine.runnerContainers (default '', not counted)

On Linux and macOS it runs host-capabilities.sh (in the same directory) instead, which writes the same report.

.PARAMETER Refresh
Probe again even if the cached report is still fresh, for example after a docker command failed to reach its engine.

.PARAMETER AsJson
Print the report as JSON text instead of returning an object.

.EXAMPLE
./Get-HostCapabilities.ps1 -AsJson

.EXAMPLE
(./Get-HostCapabilities.ps1 -Refresh).linuxEngine.invoke
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Refresh,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    $shArgs = @("$PSScriptRoot/host-capabilities.sh")
    if ($Refresh) { $shArgs += '--refresh' }
    $json = (& sh @shArgs) -join "`n"
    if ($LASTEXITCODE) { throw "host-capabilities.sh failed with exit code $LASTEXITCODE" }
    if ($AsJson) { $json } else { $json | ConvertFrom-Json }
    return
}

# The project root: the environment variable, else the git work tree around the current directory, else the
# current directory.
function Resolve-ProjectRoot {
    if ($env:HOST_CONTAINER_CAPABILITIES_ROOT) {
        return (Resolve-Path -LiteralPath $env:HOST_CONTAINER_CAPABILITIES_ROOT).Path
    }
    try {
        $top = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path -LiteralPath $top).Path }
    } catch {
        Write-Verbose "git is not available: $_"
    }
    (Get-Location).Path
}

$schemaVersion = 1
$projectRoot = Resolve-ProjectRoot
$cachePath = Join-Path $projectRoot '.claude/host-container-capabilities.windows.local.json'
$overridesPath = Join-Path $projectRoot '.claude/host-container-capabilities.overrides.local.json'

$overrides = [ordered]@{
    linuxEngine            = 'auto'
    sharedHost             = $true
    maxAgeHours            = 24
    createdByLabel         = 'io.github.kothar-hq.created-by=agent'
    sessionLabelKey        = 'io.github.kothar-hq.session'
    runnerContainerPattern = ''
}
if (Test-Path $overridesPath) {
    $userOverrides = Get-Content -Raw $overridesPath | ConvertFrom-Json -AsHashtable
    foreach ($key in @($userOverrides.Keys)) {
        if ($overrides.Contains($key)) { $overrides[$key] = $userOverrides[$key] } else { Write-Warning "Ignoring unknown override '$key'" }
    }
    if ($overrides.linuxEngine -notmatch '^(auto|none|docker|docker-desktop-linux|podman|wsl:.+)$') {
        throw "Override linuxEngine '$($overrides.linuxEngine)' must be auto, none, docker, docker-desktop-linux, podman or wsl:<distro>"
    }
    if ($overrides.createdByLabel -notmatch '^[^=\s]+=\S+$') {
        throw "Override createdByLabel '$($overrides.createdByLabel)' must be key=value, without spaces"
    }
    if ($overrides.sessionLabelKey -notmatch '^[^=\s]+$') {
        throw "Override sessionLabelKey '$($overrides.sessionLabelKey)' must be a label key, without spaces or '='"
    }
}

if (-not $Refresh -and (Test-Path $cachePath)) {
    $cachedJson = Get-Content -Raw $cachePath
    $cached = $cachedJson | ConvertFrom-Json
    $ageHours = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $cached.probedAtEpoch) / 3600
    $overridesChanged = (Test-Path $overridesPath) -and
        (Get-Item $overridesPath).LastWriteTimeUtc -gt (Get-Item $cachePath).LastWriteTimeUtc
    if ($cached.schemaVersion -eq $schemaVersion -and $ageHours -lt $overrides.maxAgeHours -and -not $overridesChanged) {
        if ($AsJson) { $cachedJson.TrimEnd() } else { $cached }
        return
    }
}

# Runs a native command and returns its exit code and output. A missing command is exit code -1.
function Invoke-Native {
    param([Parameter(Mandatory)][string[]]$Command)
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Command[0] @($Command | Select-Object -Skip 1) 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { "$_" }) -join "`n").Trim() }
    } catch {
        [pscustomobject]@{ ExitCode = -1; Output = "$_" }
    }
}

# Asks a docker CLI (an array such as 'wsl.exe','-d','Ubuntu','--exec','docker') about its engine. Returns $null
# and sets $script:probeError when the engine doesn't answer.
function Get-EngineFact {
    param([Parameter(Mandatory)][string[]]$Docker)
    $cli = Invoke-Native ($Docker + @('--version'))
    if ($cli.ExitCode -eq 0 -and $cli.Output -match 'podman') {
        $script:probeError = 'docker is the podman-docker shim'
        return $null
    }
    $version = Invoke-Native ($Docker + @('version', '--format', '{{.Server.Os}}|{{.Server.Version}}'))
    if ($version.ExitCode -ne 0 -or $version.Output -notmatch '^(\w+)\|(\S+)$') {
        $script:probeError = ($version.Output -split "`n" | Where-Object { $_ } | Select-Object -First 1) ?? 'no output'
        return $null
    }
    $os, $serverVersion = $Matches[1], $Matches[2]
    $info = Invoke-Native ($Docker + @('info', '--format', '{{.OperatingSystem}}|{{.Isolation}}'))
    $operatingSystem, $isolation = if ($info.ExitCode -eq 0) { $info.Output -split '\|', 2 } else { $null, $null }
    $security = Invoke-Native ($Docker + @('info', '--format', '{{.SecurityOptions}}'))
    $endpoint = Invoke-Native ($Docker + @('context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'))
    $names = Invoke-Native ($Docker + @('ps', '-a', '--format', '{{.Names}}'))
    $mine = Invoke-Native ($Docker + @('ps', '-aq', '--filter', "label=$($overrides.createdByLabel)"))
    [pscustomobject]@{
        Os              = $os
        ServerVersion   = $serverVersion
        OperatingSystem = $operatingSystem
        Isolation       = if ($isolation) { $isolation } else { $null }
        Rootless        = if ($security.ExitCode -eq 0) { $security.Output -match 'rootless' } else { $null }
        Selinux         = if ($security.ExitCode -eq 0) { $security.Output -match 'selinux' } else { $null }
        Endpoint        = if ($endpoint.ExitCode -eq 0) { $endpoint.Output } else { $null }
        Names           = @($names.Output -split "`n" | Where-Object { $_ })
        ClaudeCount     = @($mine.Output -split "`n" | Where-Object { $_ }).Count
    }
}

# Asks a Podman CLI (an array such as 'wsl.exe','-d','Fedora','--exec','podman') about its engine, with Podman's
# own field names. Returns $null and sets $script:probeError when the engine doesn't answer.
function Get-PodmanFact {
    param([Parameter(Mandatory)][string[]]$Podman)
    $format = '{{.Host.Os}}|{{.Version.Version}}|{{.Host.Distribution.Distribution}} {{.Host.Distribution.Version}}|' +
        '{{.Host.Security.Rootless}}|{{.Host.Security.SELinuxEnabled}}|{{.Host.RemoteSocket.Path}}'
    $info = Invoke-Native ($Podman + @('info', '--format', $format))
    $line = $info.Output -split "`n" | Where-Object { $_ -match '^\w+\|' } | Select-Object -First 1
    if ($info.ExitCode -ne 0 -or -not $line) {
        $script:probeError = ($info.Output -split "`n" | Where-Object { $_ } | Select-Object -First 1) ?? 'no output'
        return $null
    }
    $os, $serverVersion, $operatingSystem, $rootless, $selinux, $endpoint = $line.Trim() -split '\|', 6
    $names = Invoke-Native ($Podman + @('ps', '-a', '--format', '{{.Names}}'))
    $mine = Invoke-Native ($Podman + @('ps', '-aq', '--filter', "label=$($overrides.createdByLabel)"))
    [pscustomobject]@{
        Os              = $os
        ServerVersion   = $serverVersion
        OperatingSystem = $operatingSystem
        Isolation       = $null
        Rootless        = if ($rootless -in 'true', 'false') { $rootless -eq 'true' } else { $null }
        Selinux         = if ($selinux -in 'true', 'false') { $selinux -eq 'true' } else { $null }
        Endpoint        = if ($endpoint) { $endpoint } else { $null }
        Names           = @($names.Output -split "`n" | Where-Object { $_ })
        ClaudeCount     = @($mine.Output -split "`n" | Where-Object { $_ }).Count
    }
}

# Host
$os = Get-CimInstance Win32_OperatingSystem
$hostBuild = [Environment]::OSVersion.Version.Build
$hypervisorPresent = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$dockerDesktopInstalled = Test-Path (Join-Path $env:ProgramFiles 'Docker/Docker/Docker Desktop.exe')
$dockerDesktopLinuxPipe = Test-Path '\\.\pipe\dockerDesktopLinuxEngine'

# The default docker context: usually the Windows engine, or a Linux engine if Docker Desktop is in Linux mode
$defaultEngine = Get-EngineFact @('docker')
$defaultError = $script:probeError

# Windows engine. Process isolation needs the image's build to match the host's; anything else needs Hyper-V.
# Microsoft documents a few more cross-build process-isolation pairs, which this ignores.
$windowsEngine = [ordered]@{
    available = $false; invoke = $null; endpoint = $null; serverVersion = $null; defaultIsolation = $null
    ltsc = $null; runnerContainers = $null; reason = $null
}
if ($defaultEngine -and $defaultEngine.Os -eq 'windows') {
    $ltsc = [ordered]@{}
    foreach ($entry in @(@('2019', 17763), @('2022', 20348), @('2025', 26100))) {
        $isolation = if ($hostBuild -eq $entry[1]) { 'process' } elseif ($hypervisorPresent) { 'hyperv' } else { $null }
        $ltsc[$entry[0]] = [ordered]@{ imageBuild = $entry[1]; isolation = $isolation }
    }
    $windowsEngine.available = $true
    $windowsEngine.invoke = @('docker')
    $windowsEngine.endpoint = $defaultEngine.Endpoint
    $windowsEngine.serverVersion = $defaultEngine.ServerVersion
    $windowsEngine.defaultIsolation = $defaultEngine.Isolation
    $windowsEngine.ltsc = $ltsc
    if ($overrides.runnerContainerPattern) {
        $windowsEngine.runnerContainers = @($defaultEngine.Names | Where-Object { $_ -like $overrides.runnerContainerPattern }).Count
    }
} elseif ($defaultEngine) {
    $windowsEngine.reason = "the default docker context is a $($defaultEngine.Os) engine; Docker Desktop is never switched"
} else {
    $windowsEngine.reason = "docker: $defaultError"
}

# WSL distros. WSL_UTF8 makes wsl.exe print UTF-8 instead of UTF-16.
$previousWslUtf8 = $env:WSL_UTF8
$env:WSL_UTF8 = '1'
try {
    $wslList = Invoke-Native @('wsl.exe', '--list', '--verbose')
    $distros = @()
    if ($wslList.ExitCode -eq 0) {
        foreach ($line in $wslList.Output -split "`n") {
            if ($line -match '^\s*(\*)?\s*(\S+)\s+(\S+)\s+([12])\s*$' -and $Matches[2] -ne 'NAME') {
                $distros += [pscustomobject][ordered]@{
                    name = $Matches[2]; state = $Matches[3]; version = [int]$Matches[4]; default = [bool]$Matches[1]
                }
            }
        }
    }
    $wsl = [ordered]@{
        installed     = $wslList.ExitCode -eq 0
        defaultDistro = ($distros | Where-Object default | Select-Object -First 1).name
        distros       = $distros
    }

    # Linux engine candidates, in the order the skill prefers them
    $candidates = @()
    $wslCandidates = @($distros | Where-Object { $_.version -eq 2 -and $_.name -notlike 'docker-desktop*' } |
        Sort-Object { -not $_.default })
    # Kind 'wsl' is Docker inside a WSL distro. Kind 'podman' is Podman, inside a WSL distro (Distro is set, which
    # covers Podman Desktop's podman-machine distros) or through the native podman CLI (Distro is $null).
    $nativePodman = [pscustomobject]@{ Kind = 'podman'; Distro = $null }
    switch -Regex ($overrides.linuxEngine) {
        '^auto$' {
            $candidates += $wslCandidates | ForEach-Object { [pscustomobject]@{ Kind = 'wsl'; Distro = $_.name } }
            $candidates += [pscustomobject]@{ Kind = 'docker'; Distro = $null }
            if ($dockerDesktopLinuxPipe) { $candidates += [pscustomobject]@{ Kind = 'docker-desktop-linux'; Distro = $null } }
            $candidates += $wslCandidates | ForEach-Object { [pscustomobject]@{ Kind = 'podman'; Distro = $_.name } }
            if (Get-Command podman -ErrorAction SilentlyContinue) { $candidates += $nativePodman }
        }
        '^wsl:(.+)$' {
            $candidates += [pscustomobject]@{ Kind = 'wsl'; Distro = $Matches[1] }
            $candidates += [pscustomobject]@{ Kind = 'podman'; Distro = $Matches[1] }
        }
        '^podman$' { $candidates += $nativePodman }
        '^(docker|docker-desktop-linux)$' { $candidates += [pscustomobject]@{ Kind = $Matches[1]; Distro = $null } }
    }

    $linuxEngine = [ordered]@{
        available = $false; kind = $null; distro = $null; invoke = $null; endpoint = $null; serverVersion = $null
        operatingSystem = $null; rootless = $null; selinux = $null; containers = $null; claudeContainers = $null
        repoPath = $null; reason = $null; tried = @()
    }
    foreach ($candidate in $candidates) {
        $docker = switch ($candidate.Kind) {
            'wsl' { @('wsl.exe', '--distribution', $candidate.Distro, '--exec', 'docker') }
            'docker' { @('docker') }
            'docker-desktop-linux' { @('docker', '--host', 'npipe:////./pipe/dockerDesktopLinuxEngine') }
            'podman' {
                if ($candidate.Distro) { @('wsl.exe', '--distribution', $candidate.Distro, '--exec', 'podman') } else { @('podman') }
            }
        }
        $fact = if ($candidate.Kind -eq 'docker') { $defaultEngine }
            elseif ($candidate.Kind -eq 'podman') { Get-PodmanFact $docker }
            else { Get-EngineFact $docker }
        $failure = if (-not $fact) { if ($candidate.Kind -eq 'docker') { $defaultError } else { $script:probeError } }
            elseif ($fact.Os -ne 'linux') { "it is a $($fact.Os) engine" }
        if ($failure) {
            $linuxEngine.tried += [ordered]@{ kind = $candidate.Kind; distro = $candidate.Distro; error = $failure }
            continue
        }
        $repoPath = if ($candidate.Distro) {
            (Invoke-Native @('wsl.exe', '--distribution', $candidate.Distro, '--exec', 'wslpath', '-a', $projectRoot)).Output
        } else { $null }
        $linuxEngine.available = $true
        $linuxEngine.kind = $candidate.Kind
        $linuxEngine.distro = $candidate.Distro
        $linuxEngine.invoke = $docker
        $linuxEngine.endpoint = $fact.Endpoint
        $linuxEngine.serverVersion = $fact.ServerVersion
        $linuxEngine.operatingSystem = $fact.OperatingSystem
        $linuxEngine.rootless = $fact.Rootless
        $linuxEngine.selinux = $fact.Selinux
        $linuxEngine.containers = $fact.Names.Count
        $linuxEngine.claudeContainers = $fact.ClaudeCount
        $linuxEngine.repoPath = $repoPath
        break
    }
    if (-not $linuxEngine.available) {
        $linuxEngine.reason = if ($overrides.linuxEngine -eq 'none') { 'disabled by the linuxEngine override' }
            elseif ($linuxEngine.tried | Where-Object { $_.error -match 'permission denied' }) { 'socket permission denied' }
            elseif (-not $wsl.installed) { 'WSL is not installed and no other Linux engine answered' }
            else { 'no candidate answered; see tried' }
    }
} finally {
    $env:WSL_UTF8 = $previousWslUtf8
}

$gh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
$report = [ordered]@{
    schemaVersion = $schemaVersion
    probedAt      = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    probedAtEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    platform      = 'windows'
    overrides     = $overrides
    policy        = [ordered]@{
        sharedHost          = [bool]$overrides.sharedHost
        dockerDesktopSwitch = 'never'
        createdByLabel      = $overrides.createdByLabel
        sessionLabelKey     = $overrides.sessionLabelKey
    }
    host          = [ordered]@{
        os                = 'windows'
        caption           = $os.Caption
        build             = $hostBuild
        productType       = if ($os.ProductType -eq 1) { 'workstation' } else { 'server' }
        hypervisorPresent = $hypervisorPresent
        dockerDesktop     = [ordered]@{ installed = $dockerDesktopInstalled; linuxEnginePipe = $dockerDesktopLinuxPipe }
    }
    windowsEngine = $windowsEngine
    linuxEngine   = $linuxEngine
    wsl           = $wsl
    github        = [ordered]@{ gh = $gh; authenticated = $gh -and (Invoke-Native @('gh', 'auth', 'status')).ExitCode -eq 0 }
}
$json = $report | ConvertTo-Json -Depth 8
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cachePath) | Out-Null
Set-Content -Path $cachePath -Value $json -Encoding utf8NoBOM
if ($AsJson) { $json } else { $json | ConvertFrom-Json }
