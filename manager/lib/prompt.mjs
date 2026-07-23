import readline from 'node:readline';

/**
 * Reads user input securely without echoing (masked prompt for secrets/API keys).
 */
export async function readMaskedPrompt(promptText = 'API key: ') {
  if (!process.stdin.isTTY) {
    throw new Error('Non-TTY environment detected. Cannot prompt for secret API key interactively.');
  }

  return new Promise((resolve) => {
    process.stdout.write(promptText);

    const isRaw = process.stdin.isRaw;
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');

    let input = '';

    const onData = (char) => {
      // Handle Ctrl+C
      if (char === '\u0003') {
        cleanup();
        process.stdout.write('\n');
        process.exit(130);
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

    const cleanup = () => {
      process.stdin.removeListener('data', onData);
      process.stdin.setRawMode(isRaw);
      process.stdin.pause();
    };

    process.stdin.on('data', onData);
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
  if (!items || items.length === 0) {
    return null;
  }

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
  if (isNaN(choiceIdx) || choiceIdx < 0 || choiceIdx >= items.length) {
    choiceIdx = defaultIndex;
  }

  return { item: items[choiceIdx], index: choiceIdx };
}
