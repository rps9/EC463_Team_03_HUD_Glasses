const chalk = require('chalk');

const stamp = () => new Date().toLocaleTimeString();
const baseLog = (...msg) => console.log(chalk.gray(stamp()), ...msg);

module.exports = {
  log: baseLog,
  chalk
};
