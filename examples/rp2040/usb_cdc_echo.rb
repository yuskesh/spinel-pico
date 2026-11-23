# USB virtual serial port (CDC ACM) that sends back what it receives, upper-cased, and a line every second while a
# program on the host has the port open (DTR). On Linux it appears as /dev/ttyACM*. The controller's interrupt wakes
# the loop; the UART console shows the state once a second.
# 2e8a:000a is Raspberry Pi's ID for the Pico SDK's CDC UART; use your own for a product.
# Not yet tried with a host: see lib/pico/usb_device.rb
require_relative "../../lib/pico"

pico = Pico.rp2040
t = pico.timer
pico.clocks.set_sys_clock_khz(48_000)
cdc = pico.usb_cdc(0x2e8a, 0x000a, ["Raspberry Pi", "Pico (spinel-pico)", "0001"])
cdc.init(pico.clocks, pico.resets)
irq = pico.chip.irq(:usbctrl_irq)
cdc.set_irq_enabled(true)
Pico::IRQ.set_enabled(irq, true)
last = t.time_us_31
seconds = 0
while seconds < 3600
  Pico::IRQ.wait(irq, t, 1000)                  # until the controller has something, or 1 ms for the queue
  cdc.task
  Pico::IRQ.acknowledge(irq)
  if cdc.available > 0
    out = +""
    cdc.read_all.each { |b| out << (b >= 97 && b <= 122 ? b - 32 : b).chr }
    cdc.print(out)
  end
  if t.us_since(last) >= 1_000_000
    last = t.time_us_31
    seconds += 1
    cdc.print("#{seconds} s, #{cdc.baud} baud\r\n") if cdc.dtr?
    puts "#{seconds} s: suspended #{cdc.suspended?} resets #{cdc.resets_seen} setups #{cdc.setups} address #{cdc.address} " \
         "configured #{cdc.configured?} DTR #{cdc.dtr?} dropped #{cdc.dropped}"
  end
end
