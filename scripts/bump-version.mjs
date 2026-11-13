#!/usr/bin/env node
// Increments the version in package.json, skills/host-container-capabilities/SKILL.md,
// and CHANGELOG.md, then creates and checks out a release/vX.Y.Z branch.
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Compute a new semver from an existing one and a bump type or explicit version. */
export function bumpVersion(current, type) {
    if (/^\d+\.\d+\.\d+$/.test(type)) return type;
    const [major, minor, patch] = current.split('.').map(Number);
    switch (type) {
        case 'major': return `${major + 1}.0.0`;
        case 'minor': return `${major}.${minor + 1}.0`;
        case 'patch': return `${major}.${minor}.${patch + 1}`;
        default: throw new Error(`Unknown bump type "${type}". Use major, minor, patch, or X.Y.Z.`);
    }
}

/** Return updated package.json text with the new version. */
export function updatePackageJson(content, newVersion) {
    const pkg = JSON.parse(content);
    pkg.version = newVersion;
    return JSON.stringify(pkg, null, 2) + '\n';
}

/** Return updated SKILL.md text with the new metadata.version. */
export function updateSkillMd(content, newVersion) {
    return content.replace(/^(\s+version: ")([^"]+)(")/m, `$1${newVersion}$3`);
}

/** Return updated CHANGELOG.md text with a stub section for the new version at the top. */
export function updateChangelog(content, newVersion) {
    const stub = `## ${newVersion}\n\n<!-- TODO: add release notes -->\n\n`;
    return content.replace(/^(## \d)/m, `${stub}$1`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const type = process.argv[2];
    if (!type) {
        process.stderr.write('Usage: bump-version.mjs <major|minor|patch|X.Y.Z>\n');
        process.exit(1);
    }

    const pkgPath = join(root, 'package.json');
    const skillPath = join(root, 'skills', 'host-container-capabilities', 'SKILL.md');
    const changelogPath = join(root, 'CHANGELOG.md');

    const pkgContent = readFileSync(pkgPath, 'utf8');
    const currentVersion = JSON.parse(pkgContent).version;

    let newVersion;
    try {
        newVersion = bumpVersion(currentVersion, type);
    } catch (err) {
        process.stderr.write(`${err.message}\n`);
        process.exit(1);
    }

    // Check for uncommitted changes so the branch starts clean.
    const status = spawnSync('git', ['status', '--porcelain'], { encoding: 'utf8' });
    if (status.stdout.trim()) {
        process.stderr.write('Working tree has uncommitted changes. Commit or stash them first.\n');
        process.exit(1);
    }

    process.stdout.write(`Bumping ${currentVersion} → ${newVersion}\n`);

    writeFileSync(pkgPath, updatePackageJson(pkgContent, newVersion));
    writeFileSync(skillPath, updateSkillMd(readFileSync(skillPath, 'utf8'), newVersion));
    writeFileSync(changelogPath, updateChangelog(readFileSync(changelogPath, 'utf8'), newVersion));

    const branch = `release/v${newVersion}`;
    execFileSync('git', ['checkout', '-b', branch], { stdio: 'inherit' });

    process.stdout.write(`Created branch ${branch}\n`);
    process.stdout.write(`\nNext: fill in CHANGELOG.md, then commit and push.\n`);
}
