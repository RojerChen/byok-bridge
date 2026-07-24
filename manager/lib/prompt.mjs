import readline from 'node:readline';

/**
 * Reads user input securely without echoing (masked prompt for secrets/API keys).
 */
export async function readMaskedPrompt(promptText = 'API key: ') {
  if (!process.stdin.isTTY) {
    throw new Error('Non-TTY environment detected. Cannot prompt for secret API key interactively.');
  }

  return new Promise((resolve, reject) => {
    process.stdout.write(promptText);

    const isRaw = process.stdin.isRaw;
    const rejectWithCode = (message, exitCode) => {
      const error = new Error(message);
      error.exitCode = exitCode;
      cleanup();
      reject(error);
    };

    const onSigint = () => rejectWithCode('Input cancelled.', 130);
    const onSigterm = () => rejectWithCode('Input terminated.', 143);
    const onSighup = () => rejectWithCode('Input terminated.', 129);
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onEnd = () => rejectWithCode('Input stream ended before a value was entered.', 1);

    const cleanup = () => {
      process.stdin.removeListener('data', onData);
      process.stdin.removeListener('error', onError);
      process.stdin.removeListener('end', onEnd);
      process.removeListener('SIGINT', onSigint);
      process.removeListener('SIGTERM', onSigterm);
      process.removeListener('SIGHUP', onSighup);
      try { process.stdin.setRawMode(isRaw); } catch {}
      process.stdin.pause();
    };

    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');

    let input = '';

    const onData = (char) => {
      // Handle Ctrl+C
      if (char === '\u0003') {
        process.stdout.write('\n');
        onSigint();
        return;
      }

      // Handle Enter (CR/LF)
      if (char === '\r' || char === '\n') {
        cleanup();
        process.stdout.write('\n');
        resolve(input.trim());
        return;
      }

      // Handle Backspace (0x08, 0x7f)
      if (char === '\u0008' || char === '\x7f') {
        if (input.length > 0) {
          input = input.slice(0, -1);
        }
        return;
      }

      // Accumulate readable characters
      input += char;
    };

    process.stdin.on('data', onData);
    process.stdin.once('error', onError);
    process.stdin.once('end', onEnd);
    process.once('SIGINT', onSigint);
    process.once('SIGTERM', onSigterm);
    process.once('SIGHUP', onSighup);
  });
}

/**
 * Reads standard text line input from user.
 */
export async function readInput(promptText = '', defaultValue = '') {
  if (!process.stdin.isTTY) {
    return defaultValue;
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  return new Promise((resolve) => {
    const fullPrompt = defaultValue ? `${promptText} (default: ${defaultValue}): ` : `${promptText}: `;
    rl.question(fullPrompt, (answer) => {
      rl.close();
      const trimmed = (answer || '').trim();
      resolve(trimmed ? trimmed : defaultValue);
    });
  });
}

/**
 * Displays a numbered menu and prompts for selection.
 */
export async function selectMenuItem(title, items, defaultIndex = 0, formatter = (item) => String(item)) {
  if (!items || items.length === 0) throw new Error('Cannot select from an empty menu.');

  if (items.length === 1) {
    return { item: items[0], index: 0 };
  }

  console.log(title);
  for (let i = 0; i < items.length; i++) {
    const isDefault = (i === defaultIndex);
    const itemStr = formatter(items[i], i);
    const num = i + 1;
    if (isDefault && process.stdout.isTTY) {
      // Highlight default option in green (\x1b[32m ... \x1b[0m)
      console.log(`\x1b[32m${num}. ${itemStr}\x1b[0m`);
    } else {
      console.log(`${num}. ${itemStr}`);
    }
  }

  const defaultNum = defaultIndex + 1;
  const promptText = `Select option [1-${items.length}] (default: ${defaultNum})`;
  const answer = await readInput(promptText, String(defaultNum));

  let choiceIdx = parseInt(answer, 10) - 1;
  if (isNaN(choiceIdx) || choiceIdx < 0 || choiceIdx >= items.length) throw new Error('Invalid menu selection.');

  return { item: items[choiceIdx], index: choiceIdx };
}
