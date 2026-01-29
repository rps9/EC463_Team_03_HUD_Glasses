# Bluetooth Display Helper

Simple Node.js app that makes this machine advertise the Nordic UART Service so HUDini (or any BLE central) can send text to it. Incoming messages print in the terminal.

## Goal
- Demo: Phone speaks to AirPods, HUDini “translates,” and the translated text is pushed over BLE to this display.

## Run it
```bash
npm install  # first time only
npm start
```
Leave the process running; it will say “Advertising as HUD Display (Nordic UART)” when ready. In HUDini’s Bluetooth tab tap **Scan for devices**, connect to `HUD Display`, and start sending messages.

## UUIDs
The emitted service matches Nordic UART:
- Service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- RX (HUDini writes) `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- TX (notifications back) `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

Any other Nordic-UART-compatible central can connect as well.
