// Build: compile TypeScript and copy static files into web/dist (deployable as-is).
import { execFileSync } from 'node:child_process';
import { cpSync, rmSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'web', 'dist');
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

const localTsc = join(root, 'node_modules', '.bin', 'tsc');
const tsc = existsSync(localTsc) ? localTsc : 'tsc';
execFileSync(tsc, ['-p', join(root, 'tsconfig.json')], { stdio: 'inherit' });
cpSync(join(root, 'web', 'public'), dist, { recursive: true });
console.log('built web/dist');
