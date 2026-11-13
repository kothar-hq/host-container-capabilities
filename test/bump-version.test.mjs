import assert from 'node:assert/strict';
import { test } from 'node:test';

import { bumpVersion, updatePackageJson, updateSkillMd, updateChangelog } from '../scripts/bump-version.mjs';

// --- bumpVersion ---

test('bumpVersion: patch increments the patch component', () => {
    assert.equal(bumpVersion('1.2.3', 'patch'), '1.2.4');
    assert.equal(bumpVersion('0.9.1', 'patch'), '0.9.2');
});

test('bumpVersion: minor increments minor and resets patch', () => {
    assert.equal(bumpVersion('1.2.3', 'minor'), '1.3.0');
    assert.equal(bumpVersion('0.9.1', 'minor'), '0.10.0');
});

test('bumpVersion: major increments major and resets minor and patch', () => {
    assert.equal(bumpVersion('1.2.3', 'major'), '2.0.0');
    assert.equal(bumpVersion('0.9.1', 'major'), '1.0.0');
});

test('bumpVersion: explicit X.Y.Z passes through unchanged', () => {
    assert.equal(bumpVersion('1.2.3', '2.5.0'), '2.5.0');
});

test('bumpVersion: unknown type throws', () => {
    assert.throws(() => bumpVersion('1.2.3', 'nope'), /Unknown bump type/);
    assert.throws(() => bumpVersion('1.2.3', ''), /Unknown bump type/);
});

// --- updatePackageJson ---

test('updatePackageJson: replaces version field, preserves other fields', () => {
    const input = JSON.stringify({ name: '@example/pkg', version: '1.0.0', description: 'test' }, null, 2) + '\n';
    const result = updatePackageJson(input, '1.1.0');
    const parsed = JSON.parse(result);
    assert.equal(parsed.version, '1.1.0');
    assert.equal(parsed.name, '@example/pkg');
    assert.equal(parsed.description, 'test');
});

test('updatePackageJson: output ends with a newline', () => {
    const input = JSON.stringify({ version: '1.0.0' }, null, 2) + '\n';
    assert.ok(updatePackageJson(input, '2.0.0').endsWith('\n'));
});

// --- updateSkillMd ---

test('updateSkillMd: replaces the metadata.version line in frontmatter', () => {
    const input = '---\nname: foo\nmetadata:\n  version: "1.0.0"\n  repo: https://example.com\n---\n\n# Content\n';
    const result = updateSkillMd(input, '1.1.0');
    assert.match(result, /  version: "1\.1\.0"/);
    assert.doesNotMatch(result, /  version: "1\.0\.0"/);
});

test('updateSkillMd: does not modify content outside the version line', () => {
    const input = '---\nname: foo\nmetadata:\n  version: "0.9.1"\n---\n\nSome body text.\n';
    const result = updateSkillMd(input, '0.9.2');
    assert.match(result, /name: foo/);
    assert.match(result, /Some body text\./);
});

// --- updateChangelog ---

test('updateChangelog: inserts a new stub section before the first existing version', () => {
    const input = '# Changelog\n\nSome preamble.\n\n## 1.0.0\n\nOld notes.\n';
    const result = updateChangelog(input, '1.1.0');
    assert.match(result, /## 1\.1\.0/);
    assert.match(result, /<!-- TODO: add release notes -->/);
    const idx = result.indexOf('## 1.1.0');
    const idxOld = result.indexOf('## 1.0.0');
    assert.ok(idx < idxOld, 'new version section must appear before the old one');
});

test('updateChangelog: preserves the preamble and existing entries', () => {
    const input = '# Changelog\n\nVersions follow semver.\n\n## 0.9.1\n\nNotes.\n\n## 0.9.0\n\nOlder notes.\n';
    const result = updateChangelog(input, '0.10.0');
    assert.match(result, /Versions follow semver\./);
    assert.match(result, /## 0\.9\.1/);
    assert.match(result, /## 0\.9\.0/);
});
