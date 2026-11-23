# Pico::USBDevice against a model of the RP2040's USB device controller and a host (no microcontroller, no cable).
# The model keeps the registers and the dual-port RAM and plays the host's side of each transaction the way the
# controller would show it to the driver: a SETUP packet lands in the DPRAM and sets SIE_STATUS.SETUP_REC; an IN
# token gets the buffer the driver made AVAILABLE (else NAK); an OUT token fills a buffer that is AVAILABLE (else NAK);
# a finished buffer sets its BUFF_STATUS bit. The host checks what the USB 2.0 specification asks of a device.
# This checks the driver's logic against the specification, not against real hardware
require_relative "../lib/pico/usb_cdc"
require_relative "fake_bus"

REGS = 0x5011_0000
DPRAM = 0x5010_0000

class USBModel < FakeBus
  attr_reader :stalled

  def initialize
    super
    @stalled = false
  end

  def read32(a)
    return 0x1FF_FFFF if a == 0x4000_c008                                  # RESET_DONE
    return -0x8000_0000 | (@mem[a] || 0) if a == 0x4002_c000               # PLL_USB CS: LOCK
    super(a)
  end

  def byte(off) = ((@mem[DPRAM + (off & ~3)] || 0) >> (8 * (off & 3))) & 0xff

  def poke(off, b)
    a = DPRAM + (off & ~3)
    sh = 8 * (off & 3)
    @mem[a] = ((@mem[a] || 0) & ~(0xff << sh)) | (b << sh)
  end

  def buf_ctrl(k) = @mem[DPRAM + 0x80 + 4 * k] || 0
  def pulled_up? = ((@mem[REGS + 0x4c] || 0) & (1 << 16)) != 0
  def address = (@mem[REGS] || 0) & 0x7f

  # where endpoint buffer k is: EP0's fixed buffer, or the address in the endpoint's control word
  def buf_at(k)
    return 0x100 if k < 2
    ctrl = @mem[DPRAM + 0x08 + 8 * (k / 2 - 1) + (k.odd? ? 4 : 0)] || 0
    raise "EP#{k / 2} #{k.odd? ? 'OUT' : 'IN'} is not enabled" if (ctrl >> 31) == 0
    ctrl & 0xffff
  end

  # ---- the host's side
  def bus_reset = @mem[REGS + 0x50] = (@mem[REGS + 0x50] || 0) | (1 << 19)

  # a SETUP packet (always accepted; it also takes back any EP0 buffers)
  def setup(bytes)
    bytes.each_with_index { |b, i| poke(i, b) }
    @mem[DPRAM + 0x80] = 0
    @mem[DPRAM + 0x84] = 0
    @mem[REGS + 0x50] = (@mem[REGS + 0x50] || 0) | (1 << 17)
  end

  # an IN token: [pid (0 / 1), bytes], :nak or :stall
  def in_token(ep)
    k = 2 * ep
    c = buf_ctrl(k)
    return :stall if (c & 0x800) != 0
    return :nak if (c & 0x400) == 0
    raise "EP#{ep} IN buffer is AVAILABLE but not FULL" if (c & 0x8000) == 0
    n = c & 0x3ff
    data = (0...n).map { |i| byte(buf_at(k) + i) }
    @mem[DPRAM + 0x80 + 4 * k] = c & ~0x400 & ~0x8000
    @mem[REGS + 0x58] = (@mem[REGS + 0x58] || 0) | (1 << k)
    [(c >> 13) & 1, data]
  end

  # an OUT token with data: :ack (taken), :nak or :stall. A packet whose DATA0 / DATA1 is not the expected one is
  # acknowledged and dropped, as a repeated packet would be
  def out_token(ep, pid, data)
    k = 2 * ep + 1
    c = buf_ctrl(k)
    return :stall if (c & 0x800) != 0
    return :nak if (c & 0x400) == 0
    return :dropped if ((c >> 13) & 1) != pid
    raise "EP#{ep} OUT: #{data.size} bytes for a buffer of #{c & 0x3ff}" if data.size > (c & 0x3ff)
    data.each_with_index { |b, i| poke(buf_at(k) + i, b) }
    @mem[DPRAM + 0x80 + 4 * k] = (c & ~0x400 & ~0x3ff) | 0x8000 | data.size
    @mem[REGS + 0x58] = (@mem[REGS + 0x58] || 0) | (1 << k)
    :ack
  end
end

m = USBModel.new
usb = Pico::USBDevice.new(m, Pico::RP2040, Pico::USBDevice.vendor_device, Pico::USBDevice.vendor_config,
                          ["Raspberry Pi", "Pico Test Device"])
usb.init(Pico::Clocks.new(m, Pico::RP2040), Pico::Resets.new(m, Pico::RP2040))
expect("init: USB_MUXING = TO_PHY | SOFTCON", m.mem[REGS + 0x74], 0x9)
expect("init: USB_PWR = VBUS_DETECT forced", m.mem[REGS + 0x78], 0xc)
expect("init: MAIN_CTRL = CONTROLLER_EN (device)", m.mem[REGS + 0x40], 1)
expect("init: SIE_CTRL = EP0_INT_1BUF | PULLUP_EN", m.mem[REGS + 0x4c], (1 << 29) | (1 << 16))
expect("init: EP1 OUT control: enabled, per buffer, bulk, buffer at 0x180", m.mem[DPRAM + 0x0c], 0xA800_0180)
expect("init: EP2 IN control: buffer at 0x1c0", m.mem[DPRAM + 0x10], 0xA800_01c0)
expect("init: CLK_USB_CTRL enabled from pll_usb", m.mem[0x4000_8000 + 0x54], 0x800)

# a control transfer with an IN data stage: SETUP, IN packets until a short one, then the zero-length status OUT
def control_in(m, usb, setup, expect_pids)
  m.setup(setup)
  usb.task
  want = setup[6] + (setup[7] << 8)
  data = []
  pids = []
  loop do
    r = m.in_token(0)
    return r if r == :stall
    raise "EP0 IN not ready after the setup packet" if r == :nak
    pids << r[0]
    data.concat(r[1])
    usb.task
    break if r[1].size < 64 || data.size >= want
  end
  $fail += 1 unless pids == expect_pids
  puts "NG  data stage PIDs #{pids.inspect}, expected #{expect_pids.inspect}" unless pids == expect_pids
  st = m.out_token(0, 1, [])
  raise "status stage: #{st}" unless st == :ack
  usb.task
  data
end

# a control transfer with no data stage: SETUP, then the zero-length status IN (DATA1)
def control_out(m, usb, setup)
  m.setup(setup)
  usb.task
  r = m.in_token(0)
  raise "status stage: #{r.inspect}" unless r == [1, []]
  usb.task
end

def same(what, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts "#{ok ? 'OK  ' : 'NG  '}#{what}#{ok ? '' : ": got #{got.inspect}, expected #{want.inspect}"}"
end

# ---- enumeration as a host does it
expect("before the reset: nothing to send", m.in_token(0) == :nak ? 1 : 0, 1)
m.bus_reset
usb.task
expect("bus reset: seen once, address 0", usb.resets_seen * 256 + m.address, 256)
expect("bus reset: SIE_STATUS.BUS_RESET cleared", m.mem[REGS + 0x50] & (1 << 19), 0)
d = control_in(m, usb, [0x80, 6, 0, 1, 0, 0, 64, 0], [1])
same("GET_DESCRIPTOR(device, 64): the 18-byte descriptor in one DATA1 packet", d, Pico::USBDevice.vendor_device)
d = control_in(m, usb, [0x80, 6, 0, 1, 0, 0, 8, 0], [1])
same("GET_DESCRIPTOR(device, 8): only the first 8 bytes", d, Pico::USBDevice.vendor_device.first(8))
control_out(m, usb, [0x00, 5, 7, 0, 0, 0, 0, 0])
expect("SET_ADDRESS 7: taken after the status stage", m.address * 256 + usb.address, 7 * 256 + 7)
d = control_in(m, usb, [0x80, 6, 0, 2, 0, 0, 9, 0], [1])
same("GET_DESCRIPTOR(configuration, 9): the configuration descriptor alone", d, Pico::USBDevice.vendor_config.first(9))
d = control_in(m, usb, [0x80, 6, 0, 2, 0, 0, 32, 0], [1])
same("GET_DESCRIPTOR(configuration, 32): with the interface and both endpoints", d, Pico::USBDevice.vendor_config)
d = control_in(m, usb, [0x80, 6, 0, 3, 0, 0, 255, 0], [1])
same("GET_DESCRIPTOR(string 0): language 0x0409", d, [4, 3, 0x09, 0x04])
d = control_in(m, usb, [0x80, 6, 2, 3, 0x09, 0x04, 255, 0], [1])
same("GET_DESCRIPTOR(string 2): UTF-16LE \"Pico Test Device\"", d, [34, 3] + "Pico Test Device".bytes.flat_map { |c| [c, 0] })
m.setup([0x80, 6, 9, 3, 0x09, 0x04, 255, 0])
usb.task
same("GET_DESCRIPTOR(string 9): no such string, stalled", m.in_token(0), :stall)
m.setup([0x80, 6, 0, 6, 0, 0, 10, 0])
usb.task
same("GET_DESCRIPTOR(device qualifier): stalled (full speed only)", m.in_token(0), :stall)
expect("not configured yet: EP1 OUT answers NAK", m.out_token(1, 0, [1, 2, 3]) == :nak ? 1 : 0, 1)
expect("write before SET_CONFIGURATION is refused", usb.write(2, [1]) ? 1 : 0, 0)
d = control_in(m, usb, [0x80, 8, 0, 0, 0, 0, 1, 0], [1])
same("GET_CONFIGURATION before: 0", d, [0])
control_out(m, usb, [0x00, 9, 1, 0, 0, 0, 0, 0])
expect("SET_CONFIGURATION 1", usb.configured? ? 1 : 0, 1)
d = control_in(m, usb, [0x80, 8, 0, 0, 0, 0, 1, 0], [1])
same("GET_CONFIGURATION after: 1", d, [1])
d = control_in(m, usb, [0x80, 0, 0, 0, 0, 0, 2, 0], [1])
same("GET_STATUS(device): self-powered", d, [1, 0])

# ---- bulk echo: EP1 OUT to EP2 IN, DATA0 / DATA1 alternating on each endpoint
same("EP2 IN has nothing yet", m.in_token(2), :nak)
hello = "hello".bytes
same("OUT DATA0 \"hello\"", m.out_token(1, 0, hello), :ack)
same("a second OUT before the driver has read the first: NAK", m.out_token(1, 1, [9]), :nak)
usb.task
expect("received?(1)", usb.received?(1) ? 1 : 0, 1)
data = usb.read(1)
same("read(1)", data, hello)
expect("write(2, data)", usb.write(2, data) ? 1 : 0, 1)
expect("a second write while the first waits is refused", usb.write(2, [1]) ? 1 : 0, 0)
same("IN: DATA0 \"hello\"", m.in_token(2), [0, hello])
usb.task
expect("write_busy?(2) after the packet went", usb.write_busy?(2) ? 1 : 0, 0)
big = (0...64).map { |i| (i * 7 + 3) & 0xff }
same("OUT DATA1, 64 bytes", m.out_token(1, 1, big), :ack)
usb.task
usb.write(2, usb.read(1))
same("IN: DATA1, the same 64 bytes", m.in_token(2), [1, big])
usb.task
same("OUT with the wrong DATA PID (a repeat) is dropped", m.out_token(1, 1, [5]), :dropped)
usb.task
expect("nothing received from it", usb.received?(1) ? 1 : 0, 0)

# ---- a descriptor longer than one packet, and one that fills its last packet
long = [9, 2, 9 + 9 + 7 * 10, 0, 1, 1, 0, 0x80, 50, 9, 4, 0, 0, 10, 0xff, 0, 0, 0]
5.times { |i| long += [7, 5, 0x01 + i, 2, 64, 0, 0, 7, 5, 0x81 + i, 2, 64, 0, 0] }
m2 = USBModel.new
u2 = Pico::USBDevice.new(m2, Pico::RP2040, Pico::USBDevice.vendor_device, long, [])
u2.init(Pico::Clocks.new(m2, Pico::RP2040), Pico::Resets.new(m2, Pico::RP2040))
d = control_in(m2, u2, [0x80, 6, 0, 2, 0, 0, 255, 0], [1, 0])
same("an 88-byte configuration descriptor: 64 bytes DATA1, then 24 bytes DATA0", d, long)
d = control_in(m2, u2, [0x80, 6, 0, 2, 0, 0, 64, 0], [1])
same("the same with wLength 64: exactly one full packet, no zero-length packet", d, long.first(64))
expect("EP5 IN buffer follows the others (0x180 + 9 * 64)", m2.mem[DPRAM + 0x08 + 8 * 4] & 0xffff, 0x180 + 9 * 64)
full = [9, 2, 64, 0, 1, 1, 0, 0x80, 50, 9, 4, 0, 0, 2, 0xff, 0, 0, 0, 7, 5, 0x01, 2, 64, 0, 0, 7, 5, 0x82, 2, 64, 0, 0] + [32, 0x21] + [0] * 30
m3 = USBModel.new
u3 = Pico::USBDevice.new(m3, Pico::RP2040, Pico::USBDevice.vendor_device, full, [])
u3.init(Pico::Clocks.new(m3, Pico::RP2040), Pico::Resets.new(m3, Pico::RP2040))
m3.setup([0x80, 6, 0, 2, 0, 0, 255, 0])
u3.task
r1 = m3.in_token(0)
u3.task
r2 = m3.in_token(0)
same("a 64-byte descriptor asked with wLength 255: a full packet, then a zero-length packet to end the data stage",
     [r1[1].size, r2], [64, [0, []]])

# ---- a reset in the middle
m.bus_reset
usb.task
expect("second bus reset: address 0 again, not configured", m.address * 2 + (usb.configured? ? 1 : 0), 0)
same("EP1 OUT answers NAK again", m.out_token(1, 0, [1]), :nak)
raises("an endpoint that is not in the descriptor") { usb.write(3, [1]) }
raises("a packet over wMaxPacketSize") { usb.write(2, [0] * 65) }
raises("a device descriptor of the wrong size") { Pico::USBDevice.new(m, Pico::RP2040, [18, 1], Pico::USBDevice.vendor_config, []) }

# ---- requests added for classes: features, halt, interfaces, suspend and resume, the interrupt enables
m4 = USBModel.new
u4 = Pico::USBDevice.new(m4, Pico::RP2040, Pico::USBDevice.vendor_device, Pico::USBDevice.vendor_config, [])
u4.init(Pico::Clocks.new(m4, Pico::RP2040), Pico::Resets.new(m4, Pico::RP2040))
m4.bus_reset
u4.task
control_out(m4, u4, [0x00, 9, 1, 0, 0, 0, 0, 0])
control_out(m4, u4, [0x02, 3, 0, 0, 0x82, 0, 0, 0])
same("SET_FEATURE(ENDPOINT_HALT) on EP2 IN: the endpoint stalls", m4.in_token(2), :stall)
d = control_in(m4, u4, [0x82, 0, 0, 0, 0x82, 0, 2, 0], [1])
same("GET_STATUS(EP2 IN): halted", d, [1, 0])
expect("write to a halted endpoint is refused", u4.write(2, [1]) ? 1 : 0, 0)
control_out(m4, u4, [0x02, 1, 0, 0, 0x82, 0, 0, 0])
expect("CLEAR_FEATURE(ENDPOINT_HALT): write works again", u4.write(2, [7]) ? 1 : 0, 1)
same("and the endpoint starts again from DATA0", m4.in_token(2), [0, [7]])
u4.task
control_out(m4, u4, [0x02, 3, 0, 0, 0x01, 0, 0, 0])
same("halt on EP1 OUT", m4.out_token(1, 0, [1]), :stall)
control_out(m4, u4, [0x02, 1, 0, 0, 0x01, 0, 0, 0])
same("cleared: EP1 OUT takes DATA0 again", m4.out_token(1, 0, [1]), :ack)
m4.setup([0x02, 3, 0, 0, 0x05, 0, 0, 0])
u4.task
same("halt on an endpoint the device does not have: stalled", m4.in_token(0), :stall)
d = control_in(m4, u4, [0x81, 10, 0, 0, 0, 0, 1, 0], [1])
same("GET_INTERFACE: alternate setting 0", d, [0])
control_out(m4, u4, [0x01, 11, 0, 0, 0, 0, 0, 0])
m4.setup([0x01, 11, 1, 0, 0, 0, 0, 0])
u4.task
same("SET_INTERFACE to alternate setting 1: stalled", m4.in_token(0), :stall)
m4.setup([0x40, 1, 0, 0, 0, 0, 0, 0])
u4.task
same("a vendor request the device does not know: stalled", m4.in_token(0), :stall)
expect("remote wakeup before the host allows it", u4.remote_wakeup ? 1 : 0, 0)
control_out(m4, u4, [0x00, 3, 1, 0, 0, 0, 0, 0])
d = control_in(m4, u4, [0x80, 0, 0, 0, 0, 0, 2, 0], [1])
same("GET_STATUS(device) after SET_FEATURE(REMOTE_WAKEUP): self-powered + remote wakeup", d, [3, 0])
m4.mem[REGS + 0x50] = (m4.mem[REGS + 0x50] || 0) | (1 << 4)          # the bus goes idle: SUSPENDED
u4.task
expect("suspended, counted once", (u4.suspended? ? 1 : 0) * 16 + u4.suspends, 17)
expect("remote wakeup: SIE_CTRL.RESUME set", (u4.remote_wakeup ? 1 : 0) * 2 + ((m4.mem[REGS + 0x4c] >> 12) & 1), 3)
m4.mem[REGS + 0x50] = (m4.mem[REGS + 0x50] || 0) | (1 << 11)         # RESUME seen on the bus
u4.task
expect("resumed", u4.suspended? ? 1 : 0, 0)
u4.set_irq_enabled(true)
expect("INTE: BUFF_STATUS, BUS_RESET, DEV_SUSPEND, DEV_RESUME_FROM_HOST, SETUP_REQ", m4.mem[REGS + 0x90], 0x1d010)

# ---- CDC ACM
mc = USBModel.new
cdc = Pico::USBCDC.new(mc, Pico::RP2040, 0x2e8a, 0x000a, ["Raspberry Pi", "Pico", "0001"])
cdc.init(Pico::Clocks.new(mc, Pico::RP2040), Pico::Resets.new(mc, Pico::RP2040))
mc.bus_reset
cdc.task
d = control_in(mc, cdc, [0x80, 6, 0, 1, 0, 0, 18, 0], [1])
same("CDC device descriptor: USB 2.00, class EF / 02 / 01, 2e8a:000a, strings 1 2 3",
     d, [18, 1, 0x00, 0x02, 0xef, 0x02, 0x01, 64, 0x8a, 0x2e, 0x0a, 0x00, 0x00, 0x01, 1, 2, 3, 1])
d = control_in(mc, cdc, [0x80, 6, 0, 2, 0, 0, 255, 0], [1, 0])
same("CDC configuration descriptor: 75 bytes in two packets", d, Pico::USBCDC.cdc_config)
# walk it as a host does: every descriptor's length adds up, 2 interfaces, 3 endpoints
i = 0
kinds = []
while i < d.size
  kinds << d[i + 1]
  i += d[i]
end
same("its descriptors: config, IAD, interface, 4 CDC functional, endpoint, interface, 2 endpoints (lengths add up to 75)",
     [kinds, i], [[2, 0x0b, 4, 0x24, 0x24, 0x24, 0x24, 5, 4, 5, 5], 75])
expect("EP1 IN control: interrupt type, EP2 buffers after it", mc.mem[DPRAM + 0x08], 0xAC00_0180)
control_out(mc, cdc, [0x00, 9, 1, 0, 0, 0, 0, 0])
d = control_in(mc, cdc, [0xa1, 0x21, 0, 0, 0, 0, 7, 0], [1])
same("GET_LINE_CODING: 115200 8N1 to begin with", d, [0x00, 0xc2, 0x01, 0x00, 0, 0, 8])
# SET_LINE_CODING: a control transfer with an OUT data stage (DATA1), then a zero-length IN status
mc.setup([0x21, 0x20, 0, 0, 0, 0, 7, 0])
cdc.task
same("SET_LINE_CODING: no status before the data stage has arrived", mc.in_token(0), :nak)
same("its data stage (9600 baud, 7 data bits, even parity)", mc.out_token(0, 1, [0x80, 0x25, 0, 0, 0, 2, 7]), :ack)
cdc.task
same("then the status stage", mc.in_token(0), [1, []])
cdc.task
expect("baud", cdc.baud, 9600)
d = control_in(mc, cdc, [0xa1, 0x21, 0, 0, 0, 0, 7, 0], [1])
same("GET_LINE_CODING returns what was set", d, [0x80, 0x25, 0, 0, 0, 2, 7])
expect("DTR before the port is opened", cdc.dtr? ? 1 : 0, 0)
control_out(mc, cdc, [0x21, 0x22, 3, 0, 0, 0, 0, 0])
expect("SET_CONTROL_LINE_STATE 3: DTR and RTS", (cdc.dtr? ? 1 : 0) + (cdc.rts? ? 2 : 0), 3)
mc.setup([0x21, 0x23, 0, 0, 0, 0, 0, 0])
cdc.task
same("SEND_BREAK (not supported): stalled", mc.in_token(0), :stall)
mc.setup([0x21, 0x20, 0, 0, 0, 0, 7, 0])
cdc.task
mc.out_token(0, 1, [1, 2, 3])
cdc.task
same("SET_LINE_CODING with 3 bytes instead of 7: stalled", mc.in_token(0), :stall)
# data
same("to the device: \"ls\\r\"", mc.out_token(2, 0, "ls\r".bytes), :ack)
cdc.task
same("a second packet", mc.out_token(2, 1, "x".bytes), :ack)
cdc.task
expect("available", cdc.available, 4)
same("read_all", cdc.read_all, "ls\rx".bytes)
expect("and the buffer is empty", cdc.available, 0)
cdc.print("hello\r\n")
cdc.task
same("print: one packet", mc.in_token(2), [0, "hello\r\n".bytes])
cdc.task
same("nothing more", mc.in_token(2), :nak)
text = (0...150).map { |k| (65 + k % 26).chr }.join
cdc.print(text)
got = []
sizes = []
6.times do
  cdc.task
  r = mc.in_token(2)
  next if r == :nak
  sizes << r[1].size
  got.concat(r[1])
end
same("150 bytes: packets of 64, 64, 22", [sizes, got], [[64, 64, 22], text.bytes])
cdc.print("A" * 64)
sizes = []
4.times do
  cdc.task
  r = mc.in_token(2)
  sizes << r[1].size unless r == :nak
end
same("exactly 64 bytes: a full packet, then a zero-length packet", sizes, [64, 0])
cdc.print("B" * 2000)
expect("with nobody reading, print keeps 1024 bytes and drops the rest", cdc.pending * 10_000 + cdc.dropped, 1024 * 10_000 + 976)

puts($fail == 0 ? "usb model: all passed" : "usb model: #{$fail} mismatches")
exit($fail == 0 ? 0 : 1)
