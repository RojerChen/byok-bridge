import { spawnSync } from 'node:child_process';

const platformScripts = {
  win32: ['test:node', 'smoke', 'test:powershell-http', 'test:windows-shell', 'test:windows-installer'],
  linux: ['test:node', 'test:linux-shell', 'test:linux-installer']
};
const scripts = platformScripts[process.platform] || ['test:node'];
const npmCli = process.env.npm_execpath;

for (const script of scripts) {
  const result = npmCli
    ? spawnSync(process.execPath, [npmCli, 'run', script], { stdio: 'inherit' })
    : spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['run', script], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
