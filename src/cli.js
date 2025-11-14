const readline = require('readline');
const { log, chalk } = require('./logger');

function startCli(txCharacteristic) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  const ask = () => {
    rl.question(chalk.magenta('Type text to broadcast (Enter to skip): '), input => {
      const trimmed = input.trim();
      if (trimmed.length) {
        const success = txCharacteristic.send(trimmed);
        if (!success) {
          log(chalk.red('Connect HUDini before sending.'));
        }
      }
      ask();
    });
  };

  ask();
}

module.exports = { startCli };
