# USB CDC ACM (a virtual serial port) on Pico::USBDevice: one communications interface (an interrupt IN endpoint for
# notifications, not used) and one data interface (bulk OUT and IN). Hosts bind their standard serial driver to it
# (/dev/ttyACM* on Linux).
#
#   cdc = Pico::USBCDC.new(pico.bus, pico.chip, 0x2e8a, 0x000a, ["Raspberry Pi", "Pico", "0001"])
#   cdc.init(pico.clocks, pico.resets)
#   loop do
#     cdc.task
#     cdc.print("got #{cdc.read_all.size} bytes\r\n") if cdc.available > 0
#   end
#
# print queues bytes and task sends them a packet at a time; read_all returns the bytes received so far.
# NOT YET RUN AGAINST A HOST (see usb_device.rb): checked against the model in test/usb_model.rb only
require_relative "usb_device"

module Pico
  class USBCDC < USBDevice
    REQ_SET_LINE_CODING = 0x20
    REQ_GET_LINE_CODING = 0x21
    REQ_SET_CONTROL_LINE_STATE = 0x22
    EP_NOTIFY = 1                              # interrupt IN
    EP_DATA = 2                                # bulk OUT and bulk IN
    TX_LIMIT = 1024                            # bytes print keeps while the host is not reading

    attr_reader :dropped

    # Device descriptor: class 0xEF / 2 / 1 (interfaces are grouped by an interface association descriptor)
    def self.cdc_device(vid, pid)
      [18, DT_DEVICE, 0x00, 0x02, 0xef, 0x02, 0x01, EP0_MAX, vid & 0xff, vid >> 8, pid & 0xff, pid >> 8, 0x00, 0x01, 1, 2, 3, 1]
    end

    # Configuration: IAD, communications interface with the CDC functional descriptors (header 1.20, call management,
    # ACM with line coding support, union of interfaces 0 and 1) and its notification endpoint, then the data interface
    def self.cdc_config
      [9, DT_CONFIG, 75, 0, 2, 1, 0, 0x80, 50,
       8, 0x0b, 0, 2, 0x02, 0x02, 0x00, 0,
       9, 4, 0, 0, 1, 0x02, 0x02, 0x00, 0,
       5, 0x24, 0x00, 0x20, 0x01,
       5, 0x24, 0x01, 0x00, 1,
       4, 0x24, 0x02, 0x02,
       5, 0x24, 0x06, 0, 1,
       7, DT_ENDPOINT, 0x80 | EP_NOTIFY, 3, 8, 0, 16,
       9, 4, 1, 0, 2, 0x0a, 0x00, 0x00, 0,
       7, DT_ENDPOINT, EP_DATA, 2, 64, 0, 0,
       7, DT_ENDPOINT, 0x80 | EP_DATA, 2, 64, 0, 0]
    end

    # strings: manufacturer, product, serial number
    def initialize(bus, chip, vid, pid, strings)
      super(bus, chip, USBCDC.cdc_device(vid, pid), USBCDC.cdc_config, strings)
      @line_coding = [0x00, 0xc2, 0x01, 0x00, 0, 0, 8]     # 115200 baud, 1 stop bit, no parity, 8 data bits
      @line_state = 0
      @rx = []
      @tx = []
      @tx_zlp = false
      @dropped = 0                             # bytes print threw away because the queue was full
    end

    # what the host set with SET_LINE_CODING (a virtual port has no real baud rate; programs may read it as a signal)
    def baud = @line_coding[0] | (@line_coding[1] << 8) | (@line_coding[2] << 16) | ((@line_coding[3] & 0x7f) << 24)

    # DTR: a program on the host has the port open
    def dtr? = (@line_state & 1) != 0
    def rts? = (@line_state & 2) != 0

    # ---- class requests (to interface 0)
    def class_request_in(type, request, value, index, length)
      return @line_coding if type == 0xa1 && request == REQ_GET_LINE_CODING
      refuse_request
      []
    end

    def class_request_out(type, request, value, index, data)
      if type == 0x21 && request == REQ_SET_LINE_CODING && data.size == 7
        @line_coding = data
      elsif type == 0x21 && request == REQ_SET_CONTROL_LINE_STATE
        @line_state = value & 3
      else
        refuse_request
      end
    end

    # ---- data
    # bytes received and not read yet
    def available = @rx.size

    # the bytes received so far (an Array), emptying the buffer
    def read_all
      data = @rx
      @rx = []
      data
    end

    # queue a String for the host. Bytes beyond TX_LIMIT are dropped (counted in dropped) rather than waited for: with
    # no program reading on the host, nothing would ever leave
    def print(str)
      str.each_byte do |b|
        if @tx.size < TX_LIMIT
          @tx << b
        else
          @dropped += 1
        end
      end
    end

    # bytes queued and not handed to the controller yet
    def pending = @tx.size

    # after every task: take a received packet, send the next one. A transfer whose last packet is full is ended with
    # a zero-length packet, so the host does not wait for more
    def after_task
      return unless configured?
      @rx.concat(read(EP_DATA)) if received?(EP_DATA)
      return if write_busy?(EP_DATA)
      if !@tx.empty?
        n = @tx.size > 64 ? 64 : @tx.size
        if write(EP_DATA, @tx.first(n))
          @tx = @tx.drop(n)
          @tx_zlp = n == 64 && @tx.empty?
        end
      elsif @tx_zlp
        @tx_zlp = false if write(EP_DATA, [])
      end
    end
  end
end
