#!/usr/bin/env node
/**
 * Windows installer CLI entry point.
 *
 * Usage: node windows-installer-cli.mjs [--with-extension] [--adopt-legacy] [--skip-path-update]
 */

import process from 'node:process';
import { installWindows, InstallerError } from './lib/windows-installer.mjs';

const args = process.argv.slice(2);
const options = {
  withExtension: args.includes('--with-extension'),
  adoptLegacy: args.includes('--adopt-legacy'),
  skipPathUpdate: args.includes('--skip-path-update')
};

installWindows(options).then(() => {
  process.exitCode = 0;
}).catch(err => {
  if (err instanceof InstallerError) {
    console.error(`Installer error: ${err.message}`);
  } else {
    console.error(`Unexpected error: ${err.message}`);
    if (process.env.BYOK_BRIDGE_DEBUG) console.error(err.stack);
  }
  process.exitCode = 1;
});
