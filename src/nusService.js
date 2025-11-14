const bleno = require('@abandonware/bleno');
const { SERVICE_UUID, RX_CHAR_UUID, TX_CHAR_UUID } = require('./uuids');
const { log, chalk } = require('./logger');

class HudRxCharacteristic extends bleno.Characteristic {
  constructor(onMessage) {
    super({
      uuid: RX_CHAR_UUID,
      properties: ['write', 'writeWithoutResponse'],
      descriptors: [
        new bleno.Descriptor({ uuid: '2901', value: 'Incoming UTF-8 destined for a HUD display.' })
      ]
    });
    this.onMessage = onMessage;
  }

  onWriteRequest(data, offset, withoutResponse, callback) {
    if (offset) {
      callback(this.RESULT_ATTR_NOT_LONG);
      return;
    }
    const text = data.toString('utf8');
    this.onMessage(text);
    callback(this.RESULT_SUCCESS);
  }
}

class HudTxCharacteristic extends bleno.Characteristic {
  constructor() {
    super({
      uuid: TX_CHAR_UUID,
      properties: ['notify'],
      descriptors: [
        new bleno.Descriptor({ uuid: '2901', value: 'Notifications mirrored back to the HUD.' })
      ]
    });
    this.updateValueCallback = null;
  }

  onSubscribe(maxValueSize, updateValueCallback) {
    this.updateValueCallback = updateValueCallback;
    log(chalk.green('Central subscribed (max %d bytes).'), maxValueSize);
  }

  onUnsubscribe() {
    this.updateValueCallback = null;
    log(chalk.yellow('Central unsubscribed.'));
  }

  send(text) {
    if (!this.updateValueCallback) {
      log(chalk.dim('Skip notify; no subscriber connected.'));
      return false;
    }
    const payload = Buffer.from(text, 'utf8');
    this.updateValueCallback(payload);
    log(chalk.cyan('Notify → %s'), text);
    return true;
  }
}

function buildService(onMessage) {
  const tx = new HudTxCharacteristic();
  const rx = new HudRxCharacteristic(raw => {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      log(chalk.yellow('Received empty payload.'));
      return;
    }
    log(chalk.bold('HUD text:'), trimmed);
    onMessage?.(trimmed);
  });

  const service = new bleno.PrimaryService({
    uuid: SERVICE_UUID,
    characteristics: [rx, tx]
  });

  return { service, tx };
}

module.exports = { buildService };
