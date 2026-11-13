#!/usr/bin/env node
// Installs the host-container-capabilities skill from this package into a project's (or the user's) skills directory.
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const skillName = 'host-container-capabilities';
const skillSource = join(packageRoot, 'skills', skillName);

const usage = `Usage: ${skillName} <command> [options]

Commands:
  install          Copy the skill into .claude/skills/${skillName} in the current directory
  path             Print the directory of the skill inside this package
  version          Print the package version

Options for install:
  --global         Install into ~/.claude/skills instead of the current directory
  --dir <path>     Install into <path>/${skillName} instead (for other agents' skills directories)
  --force          Replace an existing copy
`;

function fail(message) {
    process.stderr.write(`${skillName}: ${message}\n`);
    process.exit(1);
}

function install(args) {
    let target = join(process.cwd(), '.claude', 'skills');
    let force = false;
    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        if (arg === '--global') {
            target = join(homedir(), '.claude', 'skills');
        } else if (arg === '--dir') {
            const dir = args[++i];
            if (!dir) fail('--dir needs a path');
            target = resolve(dir);
        } else if (arg === '--force') {
            force = true;
        } else {
            fail(`unknown option '${arg}'`);
        }
    }
    const destination = join(target, skillName);
    if (existsSync(destination)) {
        if (!force) fail(`${destination} already exists. Pass --force to replace it.`);
        rmSync(destination, { recursive: true });
    }
    mkdirSync(target, { recursive: true });
    cpSync(skillSource, destination, { recursive: true });
    process.stdout.write(`Installed ${skillName} to ${destination}\n`);
}

const [command, ...rest] = process.argv.slice(2);
switch (command) {
    case 'install':
        install(rest);
        break;
    case 'path':
        process.stdout.write(`${skillSource}\n`);
        break;
    case 'version':
    case '--version':
    case '-v':
        process.stdout.write(`${JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8')).version}\n`);
        break;
    case undefined:
    case 'help':
    case '--help':
    case '-h':
        process.stdout.write(usage);
        break;
    default:
        process.stderr.write(usage);
        fail(`unknown command '${command}'`);
}
