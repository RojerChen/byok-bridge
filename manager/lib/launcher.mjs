import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';

/**
 * Checks if an executable command exists in system PATH or at an absolute path.
 */
export function isExecutableInPath(command) {
  if (!command) return false;
  if (path.isAbsolute(command)) {
    try {
      fs.accessSync(command, process.platform === 'win32' ? fs.constants.F_OK : fs.constants.X_OK);
      return fs.statSync(command).isFile();
    } catch { return false; }
  }

  const PATH = process.env.PATH || '';
  const pathDirs = PATH.split(path.delimiter);
  const extensions = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];

  for (const dir of pathDirs) {
    for (const ext of extensions) {
      const fullPath = path.join(dir, command + ext);
      try {
        if (fs.existsSync(fullPath) && fs.statSync(fullPath).isFile()) {
          if (process.platform !== 'win32') fs.accessSync(fullPath, fs.constants.X_OK);
          return true;
        }
      } catch {}
    }
  }
  return false;
}

/**
 * Launches the selected CLI executable with resolved arguments and environment map.
 */
export async function launchCli(command, args = [], envMap = {}, options = {}) {
  const { dryRun = false, sensitiveKeys = new Set() } = options;

  if (dryRun) {
    console.log('[DRY-RUN] Resolved CLI Command:', command);
    console.log('[DRY-RUN] Resolved Arguments:', args);
    console.log('[DRY-RUN] Environment Map (Redacted):');
    for (const [k, v] of Object.entries(envMap)) {
      if (sensitiveKeys.has(k)) {
        console.log(`  ${k}: ${v ? '[set]' : '[not set]'}`);
      } else {
        console.log(`  ${k}: ${v}`);
      }
    }
    console.log('Dry run complete.');
    return 0;
  }

  if (!isExecutableInPath(command)) {
    console.error(`Error: The command '${command}' was not found in PATH.`);
    console.error(`Please ensure '${command}' is installed and accessible in your environment.`);
    return 5;
  }

  const childEnv = { ...process.env, ...envMap };

  return new Promise((resolve) => {
    const child = spawn(command, args, {
      shell: false,
      stdio: 'inherit',
      env: childEnv
    });

    let settled = false;
    const sigHandler = (sig) => {
      if (child && !child.killed) {
        child.kill(sig);
      }
    };

    const handlers = new Map([
      ['SIGINT', () => sigHandler('SIGINT')],
      ['SIGTERM', () => sigHandler('SIGTERM')],
      ['SIGHUP', () => sigHandler('SIGHUP')]
    ]);
    for (const [signal, handler] of handlers) process.on(signal, handler);

    const cleanup = () => {
      for (const [signal, handler] of handlers) process.removeListener(signal, handler);
    };

    const finish = (code) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(code);
    };

    child.on('error', (err) => {
      console.error(`Failed to launch child process '${command}':`, err.message);
      finish(1);
    });

    child.on('close', (code, signal) => {
      if (signal) {
        const signalOffsets = { SIGINT: 2, SIGTERM: 15, SIGHUP: 1 };
        finish(128 + (signalOffsets[signal] || 1));
      } else {
        finish(code ?? 0);
      }
    });
  });
}
