import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const name = 'host-container-capabilities';
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const skill = readFileSync(join(root, 'skills', name, 'SKILL.md'), 'utf8');
const bin = join(root, 'bin', `${name}.mjs`);

test('the skill is named after its directory, and the package after the skill, in the kothar-hq scope', () => {
    assert.match(skill, /^---\r?\nname: host-container-capabilities\r?\n/);
    assert.equal(pkg.name, `@kothar-hq/${name}`);
});

test('the skill, the package and the changelog agree on the version', () => {
    const skillVersion = skill.match(/^ {2}version: "([^"]+)"$/m)?.[1];
    assert.equal(skillVersion, pkg.version);
    const changelog = readFileSync(join(root, 'CHANGELOG.md'), 'utf8');
    assert.ok(changelog.includes(`## ${pkg.version}`), `CHANGELOG.md has no "## ${pkg.version}" section`);
});

test('the package ships the skill, both probes and the installer', () => {
    for (const file of ['SKILL.md', 'scripts/Get-HostCapabilities.ps1', 'scripts/host-capabilities.sh']) {
        assert.ok(existsSync(join(root, 'skills', name, file)), file);
    }
    assert.deepEqual(pkg.files, ['bin', 'skills']);
    assert.equal(pkg.bin[name], `bin/${name}.mjs`);
});

test('install copies the skill, and refuses to overwrite without --force', () => {
    const dir = mkdtempSync(join(tmpdir(), 'hcc-install-'));
    try {
        execFileSync(process.execPath, [bin, 'install'], { cwd: dir });
        const installed = join(dir, '.claude', 'skills', name);
        assert.equal(readFileSync(join(installed, 'SKILL.md'), 'utf8'), skill);
        assert.ok(existsSync(join(installed, 'scripts', 'host-capabilities.sh')));

        const again = spawnSync(process.execPath, [bin, 'install'], { cwd: dir, encoding: 'utf8' });
        assert.equal(again.status, 1);
        assert.match(again.stderr, /already exists/);

        execFileSync(process.execPath, [bin, 'install', '--force'], { cwd: dir });
        execFileSync(process.execPath, [bin, 'install', '--dir', join(dir, 'other')], { cwd: dir });
        assert.ok(existsSync(join(dir, 'other', name, 'SKILL.md')));
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test('version prints the package version, and an unknown command fails', () => {
    assert.equal(execFileSync(process.execPath, [bin, 'version'], { encoding: 'utf8' }).trim(), pkg.version);
    assert.equal(spawnSync(process.execPath, [bin, 'nonsense']).status, 1);
});
