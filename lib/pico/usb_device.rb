# USB device controller, low level (after pico-examples' usb/device/dev_lowlevel): the control endpoint with the
# standard requests a host needs to enumerate the device, and bulk / interrupt endpoints taken from the configuration
# descriptor. No interrupt is used: call task again and again (the controller answers NAK until a buffer is ready, and
# the host retries, so polling only makes transfers slower).
#
#   usb = Pico::USBDevice.new(pico.bus, pico.chip, Pico::USBDevice.vendor_device, Pico::USBDevice.vendor_config,
#                             ["Raspberry Pi", "Pico Test Device"])
#   usb.init(pico.clocks, pico.resets)
#   loop do
#     usb.task
#     if usb.received?(1)                       # EP1 OUT has data
#       data = usb.read(1)                      # an Array of bytes; the endpoint takes the next packet
#       usb.write(2, data)                      # EP2 IN
#     end
#   end
#
# NOT YET RUN AGAINST A HOST: the Pico used for the tests has no host on its USB port. The register numbers are checked
# against pico-sdk (tools/regs_check.sh) and the enumeration sequence against a model of the controller and a host
# (test/usb_model.rb).
require_relative "chip"
require_relative "resets"
require_relative "clocks"

module Pico
  class USBDevice
    # USBCTRL_REGS offsets (hardware/regs/usb.h)
    ADDR_ENDP = 0x00
    MAIN_CTRL = 0x40
    SIE_CTRL = 0x4c
    SIE_STATUS = 0x50
    BUFF_STATUS = 0x58
    EP_STALL_ARM = 0x68
    USB_MUXING = 0x74
    USB_PWR = 0x78
    INTE = 0x90
    INTF = 0x94                               # force an interrupt source (for tests)
    INTS = 0x98
    INT_BUFF_STATUS = 1 << 4
    INT_BUS_RESET = 1 << 12
    INT_DEV_SUSPEND = 1 << 14
    INT_DEV_RESUME_FROM_HOST = 1 << 15
    INT_SETUP_REQ = 1 << 16
    SIE_CTRL_RESUME = 1 << 12                 # drive resume signalling (remote wakeup)
    SIE_STATUS_RESUME = 1 << 11
    MAIN_CTRL_CONTROLLER_EN = 1 << 0
    MAIN_CTRL_PHY_ISO = 1 << 2                # RP2350 only: the PHY is isolated until this is cleared
    SIE_CTRL_PULLUP_EN_HI = 1 << 0            # bit 16, as the high half for write32_hl
    SIE_CTRL_EP0_INT_1BUF_HI = 1 << 13        # bit 29
    SIE_STATUS_VBUS_DETECTED = 1 << 0
    SIE_STATUS_SUSPENDED = 1 << 4
    SIE_STATUS_CONNECTED = 1 << 16
    SIE_STATUS_SETUP_REC = 1 << 17
    SIE_STATUS_BUS_RESET = 1 << 19
    MUXING_TO_PHY = 1 << 0
    MUXING_SOFTCON = 1 << 3
    PWR_VBUS_DETECT = 1 << 2
    PWR_VBUS_DETECT_OVERRIDE_EN = 1 << 3
    STALL_ARM_EP0_IN = 1 << 0
    STALL_ARM_EP0_OUT = 1 << 1

    # Dual-port RAM layout (hardware/structs/usb_dpram.h): the setup packet, each endpoint's control word (EP1 IN first),
    # each endpoint's buffer control word (EP0 IN first), EP0's buffer, then the other endpoints' buffers
    DPRAM_SIZE = 4096
    DPRAM_SETUP = 0x00
    DPRAM_EP_CTRL = 0x08
    DPRAM_BUF_CTRL = 0x80
    DPRAM_EP0_BUF = 0x100
    DPRAM_EPX_BUF = 0x180
    BUF_FULL = 1 << 15
    BUF_DATA1 = 1 << 13
    BUF_STALL = 1 << 11
    BUF_AVAIL = 1 << 10
    BUF_LEN = 0x3ff
    EP_CTRL_ENABLE_HI = 1 << 15               # bit 31
    EP_CTRL_PER_BUFFER_HI = 1 << 13           # bit 29: a BUFF_STATUS bit for every buffer
    EP_CTRL_TYPE_LSB_HI = 10                  # bits 27:26

    # Standard requests and descriptor types (USB 2.0 chapter 9)
    REQ_GET_STATUS = 0
    REQ_CLEAR_FEATURE = 1
    REQ_SET_FEATURE = 3
    REQ_GET_INTERFACE = 10
    REQ_SET_INTERFACE = 11
    FEATURE_ENDPOINT_HALT = 0
    FEATURE_DEVICE_REMOTE_WAKEUP = 1
    REQ_SET_ADDRESS = 5
    REQ_GET_DESCRIPTOR = 6
    REQ_GET_CONFIGURATION = 8
    REQ_SET_CONFIGURATION = 9
    DT_DEVICE = 1
    DT_CONFIG = 2
    DT_STRING = 3
    DT_ENDPOINT = 5
    EP0_MAX = 64

    attr_reader :address, :setups, :resets_seen, :suspends

    # The device and configuration descriptors of dev_lowlevel: a vendor-specific interface with EP1 OUT and EP2 IN
    # (bulk, 64 bytes). pico-examples' dev_lowlevel_loopback.py talks to it
    def self.vendor_device
      [18, DT_DEVICE, 0x10, 0x01, 0, 0, 0, EP0_MAX, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 1, 2, 0, 1]
    end

    def self.vendor_config
      [9, DT_CONFIG, 32, 0, 1, 1, 0, 0xc0, 0x32,
       9, 4, 0, 0, 2, 0xff, 0, 0, 0,
       7, DT_ENDPOINT, 0x01, 2, 64, 0, 0,
       7, DT_ENDPOINT, 0x82, 2, 64, 0, 0]
    end

    # device: the 18-byte device descriptor; config: the configuration descriptor with its interface and endpoint
    # descriptors (wTotalLength bytes); strings: string 1, 2, ... (ASCII)
    def initialize(bus, chip, device, config, strings)
      raise "USB device descriptor must be 18 bytes (got #{device.size})" unless device.size == 18
      total = config[2] + (config[3] << 8)
      raise "USB configuration descriptor: wTotalLength #{total} but #{config.size} bytes given" unless total == config.size
      @bus = bus
      @chip = chip
      @regs = chip.usbctrl_regs_base
      @dpram = chip.usbctrl_dpram_base
      @device = device
      @config = config
      @strings = strings
      @address = 0
      @pending_address = -1                    # set by SET_ADDRESS, used after its status stage
      @configured = false
      @setups = 0                              # setup packets handled (for tests and debugging)
      @resets_seen = 0
      @next_pid = Array.new(32, 0)             # DATA0 / DATA1 for the next packet, per buffer (2 * ep + (out ? 1 : 0))
      @buf_at = Array.new(32, 0)               # DPRAM offset of each endpoint buffer
      @max = Array.new(32, 0)                  # wMaxPacketSize
      @busy = Array.new(32, false)             # an IN packet is waiting to be sent
      @got = Array.new(32, -1)                 # bytes received by an OUT endpoint and not read yet (-1: none)
      @control = []                            # rest of an EP0 IN data stage longer than one packet
      @control_zlp = false
      @out_request = [0, 0, 0, 0]              # the class / vendor request whose OUT data stage is awaited
      @out_length = -1                         # its wLength (-1: none awaited)
      @request_refused = false
      @halted = Array.new(32, false)           # endpoints stalled by SET_FEATURE(ENDPOINT_HALT)
      @remote_wakeup = false                   # allowed by the host with SET_FEATURE(DEVICE_REMOTE_WAKEUP)
      @suspended = false
      @suspends = 0
      parse_endpoints
    end

    def configured? = @configured

    # ---- start-up (dev_lowlevel's usb_device_init). The USB PLL must give 48 MHz: clocks.init_48mhz(:usb) does that
    def init(clocks, resets)
      clocks.init_48mhz(:usb)
      resets.reset_unreset_block_wait([:usbctrl])
      (DPRAM_SIZE / 4).times { |i| @bus.write32(@dpram + 4 * i, 0) }
      @bus.clear_bits(@regs + MAIN_CTRL, MAIN_CTRL_PHY_ISO) unless @chip.rp2040?
      @bus.write32(@regs + USB_MUXING, MUXING_TO_PHY | MUXING_SOFTCON)
      # the Pico does not connect VBUS to the controller: say it is there
      @bus.write32(@regs + USB_PWR, PWR_VBUS_DETECT | PWR_VBUS_DETECT_OVERRIDE_EN)
      @bus.write32(@regs + MAIN_CTRL, MAIN_CTRL_CONTROLLER_EN)
      @bus.write32_hl(@regs + SIE_CTRL, SIE_CTRL_EP0_INT_1BUF_HI, 0)
      setup_endpoints
      @bus.write32_hl(@regs + SIE_CTRL, SIE_CTRL_EP0_INT_1BUF_HI | SIE_CTRL_PULLUP_EN_HI, 0)   # show the device to the host
    end

    # Take the device off the bus
    def disconnect = @bus.write32_hl(@regs + SIE_CTRL, SIE_CTRL_EP0_INT_1BUF_HI, 0)

    def vbus_detected? = (@bus.read32(@regs + SIE_STATUS) & SIE_STATUS_VBUS_DETECTED) != 0
    def connected? = (@bus.read32(@regs + SIE_STATUS) & SIE_STATUS_CONNECTED) != 0

    # The bus has been idle for 3 ms and the host has not resumed it since (kept by task)
    def suspended? = @suspended

    # Wake a suspended host, if it allowed that (SET_FEATURE(DEVICE_REMOTE_WAKEUP)); false if not allowed or not suspended
    def remote_wakeup
      return false unless @suspended && @remote_wakeup
      @bus.set_bits(@regs + SIE_CTRL, SIE_CTRL_RESUME)
      true
    end

    # ---- the controller's interrupt (chip.irq(:usbctrl_irq)): setup packets, finished buffers, bus resets, suspend and
    # resume. Ruby does not run in the interrupt (see Pico::IRQ): wait for it, then call task, which clears the
    # sources, and acknowledge it:
    #   usb.set_irq_enabled(true); Pico::IRQ.set_enabled(n, true)
    #   loop { usb.task if Pico::IRQ.wait(n, timer, 100_000); Pico::IRQ.acknowledge(n); ... }
    def set_irq_enabled(on)
      m = INT_BUFF_STATUS | INT_BUS_RESET | INT_DEV_SUSPEND | INT_DEV_RESUME_FROM_HOST
      on ? @bus.write32_hl(@regs + INTE, INT_SETUP_REQ >> 16, m) : @bus.write32(@regs + INTE, 0)
    end

    # the enabled sources that are asserted (INTS)
    def irq_status = @bus.read32(@regs + INTS)

    # ---- the polling step (dev_lowlevel's interrupt handler): a setup packet, finished buffers, a bus reset
    def task
      s = @bus.read32(@regs + SIE_STATUS)
      if (s & SIE_STATUS_SUSPENDED) != 0
        @bus.clear_bits(@regs + SIE_STATUS, SIE_STATUS_SUSPENDED)
        @suspends += 1 unless @suspended
        @suspended = true
      end
      if (s & SIE_STATUS_RESUME) != 0
        @bus.clear_bits(@regs + SIE_STATUS, SIE_STATUS_RESUME)
        @suspended = false
      end
      if (s & SIE_STATUS_SETUP_REC) != 0
        @bus.clear_bits(@regs + SIE_STATUS, SIE_STATUS_SETUP_REC)
        @suspended = false
        handle_setup
      end
      b = @bus.read32(@regs + BUFF_STATUS)
      handle_buffers(b) if b != 0
      if (s & SIE_STATUS_BUS_RESET) != 0
        @bus.clear_bits(@regs + SIE_STATUS, SIE_STATUS_BUS_RESET)
        bus_reset
      end
      after_task
    end

    # for a class built on this one: runs at the end of every task
    def after_task
    end

    # ---- class and vendor requests (bmRequestType bits 6:5 not 0), for a class built on this one.
    # device to host: return the bytes of the data stage, or call refuse_request
    def class_request_in(type, request, value, index, length)
      refuse_request
      []
    end

    # host to device, with the bytes of its data stage (empty if wLength is 0): call refuse_request to stall it
    def class_request_out(type, request, value, index, data)
      refuse_request
    end

    def refuse_request
      @request_refused = true
    end

    # ---- data endpoints
    # An OUT endpoint has a packet that read has not taken yet
    def received?(ep) = @got[slot(ep, true)] >= 0

    # The packet an OUT endpoint received, as bytes (empty if none), and let the endpoint take the next one
    def read(ep)
      k = slot(ep, true)
      n = @got[k]
      return [] if n < 0
      data = read_bytes(@buf_at[k], n)
      @got[k] = -1
      start_transfer(k, 0, @max[k])
      data
    end

    # Send one packet (at most the endpoint's wMaxPacketSize) from an IN endpoint; false if the previous one has not
    # gone yet
    def write(ep, bytes)
      k = slot(ep, false)
      raise "USB EP#{ep} IN packet of #{bytes.size} bytes is over its wMaxPacketSize #{@max[k]}" if bytes.size > @max[k]
      return false if @busy[k] || !@configured || @halted[k]
      write_bytes(@buf_at[k], bytes)
      @busy[k] = true
      start_transfer(k, bytes.size, 0)
      true
    end

    def write_busy?(ep) = @busy[slot(ep, false)]

    # buffer number of a data endpoint (1-15): 2 * ep for IN, 2 * ep + 1 for OUT (the BUFF_STATUS bit)
    def slot(ep, out)
      raise "USB data endpoint must be 1-15 (got #{ep})" unless ep.between?(1, 15)
      k = 2 * ep + (out ? 1 : 0)
      raise "USB EP#{ep} #{out ? 'OUT' : 'IN'} is not in the configuration descriptor" if @max[k] == 0
      k
    end

    # ---- endpoints from the configuration descriptor
    def parse_endpoints
      @buf_at[0] = DPRAM_EP0_BUF
      @buf_at[1] = DPRAM_EP0_BUF
      @max[0] = EP0_MAX
      @max[1] = EP0_MAX
      @types = Array.new(32, 0)
      at = DPRAM_EPX_BUF
      i = 0
      while i < @config.size
        len = @config[i]
        raise "USB configuration descriptor: a descriptor of length 0 at byte #{i}" if len == 0
        if @config[i + 1] == DT_ENDPOINT
          addr = @config[i + 2]
          ep = addr & 0x0f
          raise "USB endpoint address 0x#{addr.to_s(16)}: endpoint must be 1-15" unless ep.between?(1, 15)
          k = 2 * ep + ((addr & 0x80) != 0 ? 0 : 1)
          size = @config[i + 4] + (@config[i + 5] << 8)
          raise "USB EP#{ep}: wMaxPacketSize must be 1-64 (got #{size})" unless size.between?(1, 64)
          @max[k] = size
          @types[k] = @config[i + 3] & 3
          @buf_at[k] = at
          at += 64
          raise "USB endpoints need more buffer space than the DPRAM has" if at > DPRAM_SIZE
        end
        i += len
      end
    end

    # endpoint control words: enabled, a BUFF_STATUS bit per buffer, the transfer type, where the buffer is
    def setup_endpoints
      (2...32).each do |k|
        next if @max[k] == 0
        ep = k / 2
        a = @dpram + DPRAM_EP_CTRL + 8 * (ep - 1) + (k.odd? ? 4 : 0)
        @bus.write32_hl(a, EP_CTRL_ENABLE_HI | EP_CTRL_PER_BUFFER_HI | (@types[k] << EP_CTRL_TYPE_LSB_HI), @buf_at[k])
      end
    end

    def buf_ctrl(k) = @dpram + DPRAM_BUF_CTRL + 4 * k

    # Hand buffer k to the controller: send send_len bytes (an IN buffer) or take up to recv_len bytes (an OUT buffer).
    # AVAILABLE is set in a second write, after the rest has settled (the controller's clock domain is separate)
    def start_transfer(k, send_len, recv_len)
      v = k.even? ? (send_len | BUF_FULL) : recv_len
      v |= BUF_DATA1 if @next_pid[k] == 1
      @next_pid[k] ^= 1
      @bus.write32(buf_ctrl(k), v)
      @bus.write32(buf_ctrl(k), v | BUF_AVAIL)
    end

    # ---- the control endpoint
    def handle_setup
      @setups += 1
      w0 = @bus.read32(@dpram + DPRAM_SETUP)
      w1 = @bus.read32(@dpram + DPRAM_SETUP + 4)
      type = w0 & 0xff
      request = (w0 >> 8) & 0xff
      value = (w0 >> 16) & 0xffff
      index = w1 & 0xffff
      length = (w1 >> 16) & 0xffff
      @next_pid[0] = 1                         # the data and status stages start with DATA1
      @next_pid[1] = 1
      @control = []
      @control_zlp = false
      @out_length = -1
      @request_refused = false
      if (type & 0x60) != 0                    # class or vendor
        if (type & 0x80) != 0
          d = class_request_in(type, request, value, index, length)
          @request_refused ? control_stall : control_send(d, length)
        elsif length == 0
          class_request_out(type, request, value, index, [])
          @request_refused ? control_stall : control_ack
        elsif length > EP0_MAX
          control_stall                        # a data stage of more than one packet is not supported
        else
          @out_request = [type, request, value, index]
          @out_length = length
          start_transfer(1, 0, length)         # take the data stage; the request is handled when it has arrived
        end
      elsif type == 0x00                       # host to device, standard, device
        if request == REQ_SET_ADDRESS
          @pending_address = value & 0x7f      # used only after the status stage has gone out with address 0
          control_ack
        elsif request == REQ_SET_CONFIGURATION
          set_configured(value != 0)
          control_ack
        elsif (request == REQ_SET_FEATURE || request == REQ_CLEAR_FEATURE) && value == FEATURE_DEVICE_REMOTE_WAKEUP
          @remote_wakeup = request == REQ_SET_FEATURE
          control_ack
        else
          control_stall
        end
      elsif type == 0x80                       # device to host, standard, device
        if request == REQ_GET_DESCRIPTOR
          d = descriptor(value >> 8, value & 0xff)
          d.empty? ? control_stall : control_send(d, length)
        elsif request == REQ_GET_CONFIGURATION
          control_send([@configured ? @config[5] : 0], length)
        elsif request == REQ_GET_STATUS        # bit 0: self-powered, bit 1: remote wakeup allowed
          control_send([((@config[7] & 0x40) != 0 ? 1 : 0) | (@remote_wakeup ? 2 : 0), 0], length)
        else
          control_stall
        end
      elsif type == 0x01 && request == REQ_SET_INTERFACE
        value == 0 ? control_ack : control_stall                           # no alternate settings
      elsif type == 0x81
        if request == REQ_GET_STATUS
          control_send([0, 0], length)
        elsif request == REQ_GET_INTERFACE
          control_send([0], length)
        else
          control_stall
        end
      elsif type == 0x02 && (request == REQ_SET_FEATURE || request == REQ_CLEAR_FEATURE) && value == FEATURE_ENDPOINT_HALT
        k = endpoint_slot(index)
        if k < 2
          control_stall
        else
          set_halt(k, request == REQ_SET_FEATURE)
          control_ack
        end
      elsif type == 0x82 && request == REQ_GET_STATUS
        k = endpoint_slot(index)
        k < 0 ? control_stall : control_send([@halted[k] ? 1 : 0, 0], length)
      else
        control_stall
      end
    end

    # buffer number for an endpoint address as in a request's wIndex (0x82 = EP2 IN); -1 if the device has no such endpoint
    def endpoint_slot(addr)
      ep = addr & 0x0f
      k = 2 * ep + ((addr & 0x80) != 0 ? 0 : 1)
      @max[k] == 0 ? -1 : k
    end

    # ENDPOINT_HALT: the endpoint answers STALL until the host clears it; clearing starts again from DATA0
    def set_halt(k, on)
      @halted[k] = on
      @next_pid[k] = 0
      @busy[k] = false
      @got[k] = -1
      if on
        @bus.write32(buf_ctrl(k), BUF_STALL)
      elsif k.odd? && @configured
        start_transfer(k, 0, @max[k])
      else
        @bus.write32(buf_ctrl(k), 0)
      end
    end

    def halted?(ep, out) = @halted[slot(ep, out)]

    def descriptor(type, index)
      return @device if type == DT_DEVICE
      return @config if type == DT_CONFIG
      return [] unless type == DT_STRING
      return [4, DT_STRING, 0x09, 0x04] if index == 0                     # language: English (US)
      return [] if index > @strings.size
      s = @strings[index - 1]
      d = [2 + 2 * s.size, DT_STRING]
      s.each_byte do |c|                       # ASCII to UTF-16LE
        d << c
        d << 0
      end
      d
    end

    # the status stage of a request without data: a zero-length IN packet
    def control_ack = start_transfer(0, 0, 0)

    # the data stage of an IN request: at most `limit` bytes (wLength), EP0_MAX per packet
    def control_send(bytes, limit)
      data = bytes.size > limit ? bytes.first(limit) : bytes
      first = data.size > EP0_MAX ? data.first(EP0_MAX) : data
      @control = data.size > EP0_MAX ? data.drop(EP0_MAX) : []
      # a zero-length packet ends a data stage that is shorter than asked and fills its last packet
      @control_zlp = @control.empty? && data.size == EP0_MAX && data.size < limit
      write_bytes(DPRAM_EP0_BUF, first)
      start_transfer(0, first.size, 0)
    end

    def control_stall
      @bus.set_bits(@regs + EP_STALL_ARM, STALL_ARM_EP0_IN | STALL_ARM_EP0_OUT)
      @bus.write32(buf_ctrl(0), BUF_STALL)
      @bus.write32(buf_ctrl(1), BUF_STALL)
    end

    def set_configured(on)
      @configured = on
      (2...32).each do |k|
        next if @max[k] == 0
        @next_pid[k] = 0
        @busy[k] = false
        @got[k] = -1
        @halted[k] = false
        if on && k.odd?
          start_transfer(k, 0, @max[k])        # OUT endpoints wait for their first packet
        else
          @bus.write32(buf_ctrl(k), 0)
        end
      end
    end

    # ---- finished buffers: BUFF_STATUS bit 2 * ep is EP IN, 2 * ep + 1 is EP OUT
    def handle_buffers(status)
      32.times do |k|
        next if ((status >> k) & 1) == 0
        k == 31 ? @bus.clear_bits(@regs + BUFF_STATUS, -0x8000_0000) : @bus.clear_bits(@regs + BUFF_STATUS, 1 << k)
        if k == 0
          ep0_in_done
        elsif k == 1
          ep0_out_done
        elsif k.even?
          @busy[k] = false
        else
          @got[k] = @bus.read32(buf_ctrl(k)) & BUF_LEN
        end
      end
    end

    # EP0 OUT: the data stage of a class / vendor request, or the host's zero-length status packet (nothing to do)
    def ep0_out_done
      return if @out_length < 0
      n = @bus.read32(buf_ctrl(1)) & BUF_LEN
      data = read_bytes(DPRAM_EP0_BUF, n)
      @out_length = -1
      r = @out_request
      class_request_out(r[0], r[1], r[2], r[3], data)
      @request_refused ? control_stall : control_ack
    end

    def ep0_in_done
      if @pending_address >= 0
        @address = @pending_address            # the status stage of SET_ADDRESS has gone: answer to the new address
        @pending_address = -1
        @bus.write32(@regs + ADDR_ENDP, @address)
      elsif !@control.empty?
        nxt = @control.size > EP0_MAX ? @control.first(EP0_MAX) : @control
        @control = @control.size > EP0_MAX ? @control.drop(EP0_MAX) : []
        write_bytes(DPRAM_EP0_BUF, nxt)
        start_transfer(0, nxt.size, 0)
      elsif @control_zlp
        @control_zlp = false
        start_transfer(0, 0, 0)
      else
        start_transfer(1, 0, 0)                # take the host's zero-length status packet
      end
    end

    def bus_reset
      @resets_seen += 1
      @suspended = false
      @remote_wakeup = false
      @out_length = -1
      @address = 0
      @pending_address = -1
      @bus.write32(@regs + ADDR_ENDP, 0)
      @control = []
      @control_zlp = false
      set_configured(false)
    end

    # ---- bytes in the DPRAM, through 32-bit words (little-endian)
    def write_bytes(off, bytes)
      i = 0
      while i < bytes.size
        b0 = bytes[i]
        b1 = i + 1 < bytes.size ? bytes[i + 1] : 0
        b2 = i + 2 < bytes.size ? bytes[i + 2] : 0
        b3 = i + 3 < bytes.size ? bytes[i + 3] : 0
        @bus.write32_hl(@dpram + off + i, (b3 << 8) | b2, (b1 << 8) | b0)
        i += 4
      end
    end

    def read_bytes(off, n)
      out = []
      i = 0
      while i < n
        w = @bus.read32(@dpram + off + i)
        out << (w & 0xff)
        out << ((w >> 8) & 0xff) if i + 1 < n
        out << ((w >> 16) & 0xff) if i + 2 < n
        out << ((w >> 24) & 0xff) if i + 3 < n
        i += 4
      end
      out
    end
  end
end
