// Runs the sh probe against fake docker and podman CLIs, to cover engines the test machine doesn't have: rootless
// Docker, a socket the user can't open, the podman-docker shim, Podman under SELinux, a remote Windows engine, and
// no CLI at all. The probe's PATH holds only the fakes and the few tools the probe needs.
// In CI on Linux, it also runs the probe against the runner's real Docker and Podman.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const scripts = join(root, 'skills', 'host-container-capabilities', 'scripts');
const posix = process.platform !== 'win32';
const linuxCi = Boolean(process.env.CI) && process.platform === 'linux';

const fakeDocker = `#!/bin/sh
case "$FAKE_DOCKER:$1" in
    shim:--version) echo "podman version 5.2.3" ;;
    *:--version) echo "Docker version 27.3.1, build ce12230" ;;
    shim:*) echo "Error: template: version:1:15: executing version at <.Server.Os>: nil pointer" >&2; exit 125 ;;
    denied:*) echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2; exit 1 ;;
    windows:version) echo "windows|27.3.1" ;;
    *:version) echo "WARNING: something on stderr" >&2; echo "linux|27.3.1" ;;
    *:info)
        case "$FAKE_DOCKER:$*" in
            rootless:*SecurityOptions*) echo "[name=seccomp,profile=builtin name=rootless name=cgroupns]" ;;
            selinux:*SecurityOptions*) echo "[name=selinux name=seccomp,profile=builtin name=cgroupns]" ;;
            *SecurityOptions*) echo "[name=apparmor name=seccomp,profile=builtin name=cgroupns]" ;;
            windows:*) echo "Microsoft Windows Server 2025|process" ;;
            *) echo "Ubuntu 24.04.1 LTS|" ;;
        esac ;;
    windows:context) echo "ssh://builder@windows-host" ;;
    *:context) echo "unix:///var/run/docker.sock" ;;
    *:ps) case "$*" in *label=*) echo aaa ;; *) printf 'aaa\\nbbb\\nccc\\n' ;; esac ;;
esac
`;
// Podman's info reports the socket as a bare path, as podman does. FAKE_PODMAN picks the engine's state.
const fakePodman = `#!/bin/sh
case "$FAKE_PODMAN:$1" in
    *:--version) echo "podman version 5.2.3" ;;
    denied:info) echo "Error: permission denied while connecting to the Podman socket" >&2; exit 125 ;;
    rootful:info) echo "linux|5.2.3|centos 9|false|false|" ;;
    *:info) echo "linux|5.2.3|fedora 41|true|true|/run/user/1000/podman/podman.sock" ;;
    *:ps) case "$*" in *label=*) ;; *) printf 'aaa\\nbbb\\n' ;; esac ;;
esac
`;

// A project directory and a bin directory with the tools the probe uses, plus the fakes asked for.
function sandbox({ docker = false, podman = false, shimOnly = false } = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'hcc-engines-'));
    const bin = join(dir, 'bin');
    const project = join(dir, 'project');
    mkdirSync(bin);
    mkdirSync(project);
    for (const tool of ['sh', 'dirname', 'uname', 'grep', 'tr', 'sed', 'date', 'find', 'cat', 'mkdir', 'wc']) {
        const path = execFileSync('sh', ['-c', `command -v ${tool}`], { encoding: 'utf8' }).trim();
        symlinkSync(path, join(bin, tool));
    }
    const add = (name, text) => {
        writeFileSync(join(bin, name), text);
        chmodSync(join(bin, name), 0o755);
    };
    if (docker || shimOnly) add('docker', fakeDocker);
    if (podman) add('podman', fakePodman);
    return { dir, bin, project };
}

function probe({ bin, project }, fake, overrides, podman) {
    if (overrides) {
        mkdirSync(join(project, '.claude'), { recursive: true });
        writeFileSync(join(project, '.claude', 'host-container-capabilities.overrides.local.json'), JSON.stringify(overrides));
    }
    const output = execFileSync(join(bin, 'sh'), [join(scripts, 'host-capabilities.sh'), '--refresh'], {
        cwd: project,
        encoding: 'utf8',
        env: { PATH: bin, HOST_CONTAINER_CAPABILITIES_ROOT: project, FAKE_DOCKER: fake ?? '', FAKE_PODMAN: podman ?? '' },
    });
    return JSON.parse(output);
}

function withSandbox(options, body) {
    const box = sandbox(options);
    try {
        body(box);
    } finally {
        rmSync(box.dir, { recursive: true, force: true });
    }
}

const fakes = { skip: !posix && 'the sh probe hands off to PowerShell on Windows' };

test('rootful Docker on a Linux host', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        const { linuxEngine, windowsEngine } = probe(box, 'rootful');
        assert.equal(linuxEngine.available, true);
        assert.equal(linuxEngine.kind, 'docker');
        assert.deepEqual(linuxEngine.invoke, ['docker']);
        assert.equal(linuxEngine.serverVersion, '27.3.1');
        assert.equal(linuxEngine.operatingSystem, 'Ubuntu 24.04.1 LTS');
        assert.equal(linuxEngine.endpoint, 'unix:///var/run/docker.sock');
        assert.equal(linuxEngine.rootless, false);
        assert.equal(linuxEngine.selinux, false);
        assert.equal(linuxEngine.containers, 3);
        assert.equal(linuxEngine.claudeContainers, 1);
        assert.equal(linuxEngine.reason, null);
        assert.deepEqual(linuxEngine.tried, []);
        assert.equal(windowsEngine.available, false);
    });
});

test('rootless Docker is recorded', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        const { linuxEngine } = probe(box, 'rootless');
        assert.equal(linuxEngine.available, true);
        assert.equal(linuxEngine.rootless, true);
    });
});

test('a socket the user cannot open is "socket permission denied", not just "no engine"', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        const { linuxEngine } = probe(box, 'denied');
        assert.equal(linuxEngine.available, false);
        assert.equal(linuxEngine.reason, 'socket permission denied');
        assert.equal(linuxEngine.tried[0].kind, 'docker');
        assert.match(linuxEngine.tried[0].error, /^permission denied/);
        assert.equal(linuxEngine.tried[1].error, 'podman CLI not installed');
    });
});

test('no CLI at all', fakes, () => {
    withSandbox({}, (box) => {
        const { linuxEngine, windowsEngine } = probe(box);
        assert.equal(linuxEngine.available, false);
        assert.equal(linuxEngine.reason, 'no docker or podman CLI is installed');
        assert.deepEqual(linuxEngine.tried.map((entry) => entry.error), ['docker CLI not installed', 'podman CLI not installed']);
        assert.equal(windowsEngine.available, false);
    });
});

test('Podman is tried after Docker, and read with its own fields', fakes, () => {
    withSandbox({ podman: true }, (box) => {
        const { linuxEngine, windowsEngine } = probe(box);
        assert.equal(linuxEngine.available, true);
        assert.equal(linuxEngine.kind, 'podman');
        assert.deepEqual(linuxEngine.invoke, ['podman']);
        assert.equal(linuxEngine.serverVersion, '5.2.3');
        assert.equal(linuxEngine.operatingSystem, 'fedora 41');
        assert.equal(linuxEngine.endpoint, 'unix:///run/user/1000/podman/podman.sock', 'the socket path is written as a URL, like Docker\'s');
        assert.equal(linuxEngine.rootless, true);
        assert.equal(linuxEngine.selinux, true);
        assert.equal(linuxEngine.containers, 2);
        assert.equal(linuxEngine.claudeContainers, 0);
        assert.equal(windowsEngine.available, false, 'Podman never fills in windowsEngine');
    });
});

test('Docker wins over Podman in auto, and the podman override picks Podman', fakes, () => {
    withSandbox({ docker: true, podman: true }, (box) => {
        assert.equal(probe(box, 'rootful').linuxEngine.kind, 'docker');
        assert.equal(probe(box, 'rootful', { linuxEngine: 'podman' }).linuxEngine.kind, 'podman');
        const dockerOnly = probe(box, 'denied', { linuxEngine: 'docker' }).linuxEngine;
        assert.equal(dockerOnly.available, false);
        assert.equal(dockerOnly.tried.length, 1);
    });
});

test('the podman-docker shim is reported as podman, not docker', fakes, () => {
    withSandbox({ docker: true, podman: true }, (box) => {
        const { linuxEngine } = probe(box, 'shim');
        assert.equal(linuxEngine.kind, 'podman');
        assert.deepEqual(linuxEngine.invoke, ['podman']);
        assert.equal(linuxEngine.tried[0].error, 'docker is the podman-docker shim');
    });
    withSandbox({ shimOnly: true }, (box) => {
        const report = spawnSync(join(box.bin, 'sh'), [join(scripts, 'host-capabilities.sh'), '--refresh'], {
            cwd: box.project,
            encoding: 'utf8',
            env: { PATH: box.bin, HOST_CONTAINER_CAPABILITIES_ROOT: box.project, FAKE_DOCKER: 'shim' },
        });
        const { linuxEngine } = JSON.parse(report.stdout);
        assert.equal(linuxEngine.available, false, 'the fake shim answers no podman info');
        assert.equal(linuxEngine.tried[1].kind, 'podman');
    });
});

test('a remote Windows engine behind the docker context fills in windowsEngine', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        const { linuxEngine, windowsEngine } = probe(box, 'windows');
        assert.equal(linuxEngine.available, false);
        assert.equal(linuxEngine.tried[0].error, 'it is a windows engine');
        assert.equal(windowsEngine.available, true);
        assert.deepEqual(windowsEngine.invoke, ['docker']);
        assert.equal(windowsEngine.serverVersion, '27.3.1');
        assert.equal(windowsEngine.defaultIsolation, 'process');
        assert.equal(windowsEngine.endpoint, 'ssh://builder@windows-host');
        assert.equal(windowsEngine.ltsc, null);
    });
});

test('a remote Windows engine is still filled in when Podman is the Linux engine', fakes, () => {
    withSandbox({ docker: true, podman: true }, (box) => {
        const { linuxEngine, windowsEngine } = probe(box, 'windows');
        assert.equal(linuxEngine.kind, 'podman');
        assert.equal(windowsEngine.available, true);
        assert.deepEqual(windowsEngine.invoke, ['docker']);
    });
});

test('SELinux and rootless are recorded as false, not left unknown, on a plain engine', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        assert.equal(probe(box, 'selinux').linuxEngine.selinux, true);
        const { linuxEngine } = probe(box, 'rootful');
        assert.equal(linuxEngine.selinux, false);
        assert.equal(linuxEngine.rootless, false);
    });
    withSandbox({ podman: true }, (box) => {
        const { linuxEngine } = probe(box, undefined, undefined, 'rootful');
        assert.equal(linuxEngine.kind, 'podman');
        assert.equal(linuxEngine.rootless, false);
        assert.equal(linuxEngine.selinux, false);
    });
});

test('a socket Podman cannot open is "socket permission denied", as Docker\'s is', fakes, () => {
    withSandbox({ podman: true }, (box) => {
        const { linuxEngine } = probe(box, undefined, undefined, 'denied');
        assert.equal(linuxEngine.available, false);
        assert.equal(linuxEngine.reason, 'socket permission denied');
        assert.equal(linuxEngine.tried.at(-1).kind, 'podman');
    });
});

test('the podman override does not fall back to Docker, and the reason names the real problem', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        const { linuxEngine } = probe(box, 'rootful', { linuxEngine: 'podman' });
        assert.equal(linuxEngine.available, false);
        assert.deepEqual(linuxEngine.tried.map((entry) => entry.kind), ['podman']);
        assert.equal(linuxEngine.reason, 'no candidate answered; see tried', 'docker is installed, so "no CLI" would be wrong');
    });
});

test('the docker override does not fall back to Podman', fakes, () => {
    withSandbox({ podman: true }, (box) => {
        const { linuxEngine } = probe(box, undefined, { linuxEngine: 'docker' });
        assert.equal(linuxEngine.available, false);
        assert.deepEqual(linuxEngine.tried.map((entry) => entry.kind), ['docker']);
        assert.equal(linuxEngine.reason, 'no candidate answered; see tried', 'podman is installed, so "no CLI" would be wrong');
    });
});

test('an unknown linuxEngine override is refused, and the message names podman', fakes, () => {
    withSandbox({ docker: true }, (box) => {
        mkdirSync(join(box.project, '.claude'), { recursive: true });
        writeFileSync(join(box.project, '.claude', 'host-container-capabilities.overrides.local.json'), '{"linuxEngine": "kubernetes"}');
        const result = spawnSync(join(box.bin, 'sh'), [join(scripts, 'host-capabilities.sh'), '--refresh'], {
            cwd: box.project,
            encoding: 'utf8',
            env: { PATH: box.bin, HOST_CONTAINER_CAPABILITIES_ROOT: box.project },
        });
        assert.equal(result.status, 2);
        assert.match(result.stderr, /must be auto, none, docker or podman/);
    });
});

function realProbe(overrides, command = ['sh', join(scripts, 'host-capabilities.sh')]) {
    const project = mkdtempSync(join(tmpdir(), 'hcc-real-'));
    try {
        mkdirSync(join(project, '.claude'));
        writeFileSync(join(project, '.claude', 'host-container-capabilities.overrides.local.json'), JSON.stringify(overrides));
        const output = execFileSync(command[0], command.slice(1), {
            cwd: project,
            encoding: 'utf8',
            env: { ...process.env, HOST_CONTAINER_CAPABILITIES_ROOT: project },
        });
        return { report: JSON.parse(output), project };
    } finally {
        rmSync(project, { recursive: true, force: true });
    }
}

// On a machine where "docker" is the podman-docker shim, there is no real Docker to test.
const dockerVersion = spawnSync('docker', ['--version'], { encoding: 'utf8' }).stdout ?? '';
const realDockerSkip = (!linuxCi && 'only in CI on Linux') || (/podman/i.test(dockerVersion) && 'docker is the podman-docker shim') || false;

test('the real Docker on a Linux CI runner', { skip: realDockerSkip }, () => {
    const { report, project } = realProbe({ linuxEngine: 'docker' });
    console.log(JSON.stringify(report, null, 2));
    assert.equal(report.platform, 'linux');
    assert.equal(report.linuxEngine.available, true);
    assert.equal(report.linuxEngine.kind, 'docker');
    assert.equal(report.linuxEngine.rootless, false);
    assert.equal(report.linuxEngine.repoPath, project);
    assert.match(report.linuxEngine.endpoint, /^unix:\/\//);
    assert.ok(report.linuxEngine.operatingSystem.length > 0);
    assert.ok(report.host.caption.startsWith('Linux '));
});

test('the real, rootless Podman on a Linux CI runner', { skip: !linuxCi && 'only in CI on Linux' }, () => {
    const { report } = realProbe({ linuxEngine: 'podman' });
    console.log(JSON.stringify(report, null, 2));
    assert.equal(report.linuxEngine.available, true);
    assert.equal(report.linuxEngine.kind, 'podman');
    assert.deepEqual(report.linuxEngine.invoke, ['podman']);
    assert.equal(report.linuxEngine.rootless, true);
    assert.equal(typeof report.linuxEngine.selinux, 'boolean');
    assert.match(report.linuxEngine.serverVersion, /^\d+\.\d+/);
    assert.ok(report.linuxEngine.operatingSystem.length > 0);
    assert.ok(report.linuxEngine.endpoint.includes('podman.sock'));
    assert.equal(report.windowsEngine.available, false);
});

test('PowerShell on Linux and macOS hands off to the sh probe', { skip: (!posix || !process.env.CI) && 'only in CI on Linux and macOS' }, () => {
    const { report } = realProbe({ linuxEngine: 'none' }, ['pwsh', '-NoProfile', '-File', join(scripts, 'Get-HostCapabilities.ps1'), '-AsJson']);
    assert.ok(['linux', 'macos'].includes(report.platform));
    assert.equal(report.linuxEngine.reason, 'disabled by the linuxEngine override');
});
