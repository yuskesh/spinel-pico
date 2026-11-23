# One object for the whole chip: holds the bus and the chip table and hands out the drivers.
#   pico = Pico.rp2040          (on the microcontroller; see lib/pico.rb)
#   pico.gpio.put(25, true)
# The drivers keep no state of their own (everything is read back from the registers), so each call may return a
# new object. The exceptions are pio(n), i2c(n) and dma: a PIO::Block remembers which instruction memory it has used, an
# I2C object whether the next transfer starts with a repeated START, and a DMA which channels are claimed, so keep the
# objects they return.
require_relative "chip"
require_relative "resets"
require_relative "gpio"
require_relative "clocks"
require_relative "timer"
require_relative "uart"
require_relative "pwm"
require_relative "adc"
require_relative "spi"
require_relative "i2c"
require_relative "dma"
require_relative "pio/runtime"
require_relative "usb_cdc"

module Pico
  class Board
    attr_reader :bus, :chip

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
    end

    def resets = Resets.new(@bus, @chip)
    def gpio = GPIO.new(@bus, @chip)
    def clocks = Clocks.new(@bus, @chip)
    def timer = Timer.new(@bus, @chip)
    def uart(index) = UART.new(@bus, @chip, index)
    def pwm = PWM.new(@bus, @chip)
    def adc = ADC.new(@bus, @chip)
    def spi(index) = SPI.new(@bus, @chip, index)
    def i2c(index) = I2C.new(@bus, @chip, index)
    def dma = DMA.new(@bus, @chip)
    def pio(index) = PIO::Block.new(@bus, @chip, index)
    def usb_device(device, config, strings) = USBDevice.new(@bus, @chip, device, config, strings)
    def usb_cdc(vid, pid, strings) = USBCDC.new(@bus, @chip, vid, pid, strings)
  end
end
