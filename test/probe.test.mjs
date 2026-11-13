// Runs the real probe for this platform against a throwaway project directory. With linuxEngine "none" the probe
// doesn't boot WSL distros, so the tests are safe on a developer's machine. CI also runs the default "auto".
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const scripts = join(root, 'skills', 'host-container-capabilities', 'scripts');
const windows = process.platform === 'win32';

function probe(projectRoot, refresh = false) {
    const [command, args] = windows
        ? ['pwsh', ['-NoProfile', '-File', join(scripts, 'Get-HostCapabilities.ps1'), '-AsJson', ...(refresh ? ['-Refresh'] : [])]]
        : ['sh', [join(scripts, 'host-capabilities.sh'), ...(refresh ? ['--refresh'] : [])]];
    const output = execFileSync(command, args, {
        cwd: projectRoot,
        encoding: 'utf8',
        env: { ...process.env, HOST_CONTAINER_CAPABILITIES_ROOT: projectRoot },
    });
    return JSON.parse(output);
}

function project(overrides) {
    const dir = mkdtempSync(join(tmpdir(), 'hcc-probe-'));
    if (overrides) {
        mkdirSync(join(dir, '.claude'));
        writeFileSync(join(dir, '.claude', 'host-container-capabilities.overrides.local.json'), JSON.stringify(overrides));
    }
    return dir;
}

function assertShape(report) {
    assert.equal(report.schemaVersion, 1);
    assert.ok(['windows', 'wsl', 'linux', 'macos'].includes(report.platform), report.platform);
    assert.equal(report.platform === 'windows', windows);
    assert.match(report.probedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.equal(typeof report.probedAtEpoch, 'number');
    assert.equal(report.policy.dockerDesktopSwitch, 'never');
    for (const engine of [report.windowsEngine, report.linuxEngine]) {
        assert.equal(typeof engine.available, 'boolean');
        if (engine.available) {
            assert.ok(Array.isArray(engine.invoke) && engine.invoke.length > 0);
        } else {
            assert.equal(engine.invoke, null);
            assert.equal(typeof engine.reason, 'string');
        }
    }
    assert.ok(Array.isArray(report.linuxEngine.tried));
    assert.equal(typeof report.github.gh, 'boolean');
    assert.equal(typeof report.github.authenticated, 'boolean');
}

test('the probe reports the documented shape, applies overrides and caches the report', () => {
    const dir = project({
        linuxEngine: 'none',
        sharedHost: false,
        maxAgeHours: 1,
        createdByLabel: 'com.example.created-by=test',
        sessionLabelKey: 'com.example.session',
    });
    try {
        const first = probe(dir);
        assertShape(first);
        assert.equal(first.linuxEngine.available, false);
        assert.equal(first.linuxEngine.reason, 'disabled by the linuxEngine override');
        assert.equal(first.policy.sharedHost, false);
        assert.equal(first.policy.createdByLabel, 'com.example.created-by=test');
        assert.equal(first.policy.sessionLabelKey, 'com.example.session');
        assert.equal(first.overrides.maxAgeHours, 1);
        assert.equal(first.windowsEngine.runnerContainers, null);

        const cached = readdirSync(join(dir, '.claude')).filter((file) => !file.includes('.overrides.'));
        assert.deepEqual(cached, [`host-container-capabilities.${first.platform}.local.json`]);

        assert.deepEqual(probe(dir), first, 'the second run returns the cached report');
        assertShape(probe(dir, true));
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test('the probe has safe defaults without an overrides file', { skip: !process.env.CI && 'only in CI: "auto" boots WSL distros' }, () => {
    const dir = project();
    try {
        const report = probe(dir);
        assertShape(report);
        assert.equal(report.overrides.linuxEngine, 'auto');
        assert.equal(report.policy.sharedHost, true);
        assert.equal(report.policy.createdByLabel, 'io.github.kothar-hq.created-by=agent');
        assert.equal(report.policy.sessionLabelKey, 'io.github.kothar-hq.session');
        assert.ok(existsSync(join(dir, '.claude')));
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});
