# USB vendor device that sends back on EP2 IN what it receives on EP1 OUT (pico-examples' dev_lowlevel; its
# dev_lowlevel_loopback.py is the host side). Prints the controller's state on the UART console once a second.
# Not yet tried with a host: see lib/pico/usb_device.rb
require_relative "../../lib/pico"

pico = Pico.rp2040
t = pico.timer
pico.clocks.set_sys_clock_khz(48_000)           # faster polling than at the 12 MHz crystal
usb = pico.usb_device(Pico::USBDevice.vendor_device, Pico::USBDevice.vendor_config, ["Raspberry Pi", "Pico Test Device"])
usb.init(pico.clocks, pico.resets)
puts "USB device started: VBUS #{usb.vbus_detected?}"
last = t.time_us_31
echoed = 0
seconds = 0
while seconds < 3600
  usb.task
  if usb.received?(1) && !usb.write_busy?(2)
    data = usb.read(1)
    usb.write(2, data)
    echoed += data.size
  end
  if t.us_since(last) >= 1_000_000
    last = t.time_us_31
    seconds += 1
    puts "#{seconds} s: connected #{usb.connected?} suspended #{usb.suspended?} resets #{usb.resets_seen} " \
         "setups #{usb.setups} address #{usb.address} configured #{usb.configured?} echoed #{echoed} bytes"
  end
end
