const bleno = require('@abandonware/bleno');
const { buildService } = require('./nusService');
const { SERVICE_UUID } = require('./uuids');
const { log, chalk } = require('./logger');
const { startCli } = require('./cli');

const { service, tx } = buildService();

bleno.on('stateChange', state => {
  log(chalk.blue('Bluetooth state → %s'), state);
  if (state === 'poweredOn') {
    bleno.startAdvertising('HUD Display', [SERVICE_UUID]);
  } else {
    bleno.stopAdvertising();
  }
});

bleno.on('advertisingStart', error => {
  if (error) {
    log(chalk.red('Advertising error:'), error);
    return;
  }
  bleno.setServices([service], serviceErr => {
    if (serviceErr) {
      log(chalk.red('Service error:'), serviceErr);
    } else {
      log(chalk.green('Advertising as HUD Display (Nordic UART).'));
    }
  });
});

bleno.on('accept', address => log(chalk.green('Central connected:'), address));
bleno.on('disconnect', address => log(chalk.yellow('Central disconnected:'), address));

log(chalk.magenta('HUD Bluetooth display is starting…'));
startCli(tx);
