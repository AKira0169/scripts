#!/usr/bin/env node
// Runs a bash script with the right bash on every OS: `node run-sh.js <script.sh> [args...]`.
// On Windows a bare `bash` can resolve to WSL (System32\bash.exe), which sees a different
// filesystem and git, so use Git for Windows' bash, found next to `git` itself.
const { spawnSync, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function findBash() {
  if (process.platform !== 'win32') return 'bash';
  const candidates = [];
  try {
    // e.g. C:/Program Files/Git/mingw64/libexec/git-core -> C:/Program Files/Git/bin/bash.exe
    const execPath = execFileSync('git', ['--exec-path'], { encoding: 'utf8' }).trim();
    candidates.push(path.resolve(execPath, '..', '..', '..', 'bin', 'bash.exe'));
  } catch {}
  for (const base of [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs')]) {
    if (base) candidates.push(path.join(base, 'Git', 'bin', 'bash.exe'));
  }
  const found = candidates.find((p) => fs.existsSync(p));
  if (found) return found;
  console.error('Git Bash not found. Install Git for Windows: https://git-scm.com/download/win');
  process.exit(1);
}

const [script, ...args] = process.argv.slice(2);
if (!script) {
  console.error('usage: node run-sh.js <script.sh> [args...]');
  process.exit(1);
}
const r = spawnSync(findBash(), [script, ...args], { stdio: 'inherit' });
if (r.error) {
  console.error(r.error.message);
  process.exit(1);
}
process.exit(r.status === null ? 1 : r.status);
