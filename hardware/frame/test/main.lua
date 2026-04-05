frame.display.text("HUDini test app", 20, 80)
frame.display.text("Waiting for BLE", 20, 120)
frame.display.show()

frame.bluetooth.receive_callback(function(data)
  frame.display.text("RX OK", 20, 160)
  frame.display.show()
end)

while true do
  frame.sleep(1)
end
