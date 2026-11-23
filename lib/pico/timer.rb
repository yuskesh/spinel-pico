# The microsecond timer (names follow pico-sdk's hardware_timer). RP2040 only for now.
# The timer counts a 64-bit microsecond time from the watchdog's tick. The constructor releases the TIMER block from
# reset and starts the tick at clk_ref / 1 MHz, as pico-sdk's runtime does at boot. The chip family's start-up code
# (port/chip/rp2040/chip.c) does the same for clock_gettime; then the constructor changes nothing. That code resets
# the TIMER, so the time starts from 0 in every program.
#
# bare-full Integers are 32-bit, so there is no time_us_64. time_us_32 is the raw low word (negative once bit 31 is
# set, after about 36 minutes); the waits use the low 31 bits, so a single wait must be under 2^31 us (about 35 min).
require_relative "chip"
require_relative "resets"
require_relative "clocks"

module Pico
  class Timer
    ALARM0 = 0x10                    # ALARMn at ALARM0 + 4n; writing arms it
    ARMED = 0x20                     # writing 1 disarms
    TIMERAWH = 0x24
    TIMERAWL = 0x28
    WATCHDOG_TICK = 0x2c
    TICK_CYCLES = 0x1ff
    TICK_ENABLE = 1 << 9
    TICK_RUNNING = 1 << 10
    MASK31 = 0x7FFF_FFFF
    # INTR (raw alarm flags; writing 1 clears) and INTE differ by chip: Chip#timer_intr, Chip#timer_inte
    NUM_ALARMS = 4

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
      resets = Resets.new(bus, chip)
      resets.unreset_block_wait([chip.timer_reset]) if resets.in_reset?(chip.timer_reset)
      start_tick(Clocks.new(bus, chip).get_hz(:ref) / 1_000_000)
    end

    # Make the timer's tick come once per cycles clk_ref cycles (pico-sdk's watchdog_start_tick on RP2040, tick_start
    # for TICK_TIMER0 on RP2350). RP2040: cycles and enable in WATCHDOG_TICK; RP2350: TICKS' CTRL, then CYCLES after it
    def start_tick(cycles)
      raise "tick cycles must be 1-511 (clk_ref in MHz; got #{cycles})" unless cycles.between?(1, 511)
      a = @chip.tick_base + @chip.tick_ctrl
      if @chip.rp2040?
        t = @bus.read32(a)
        return if (t & TICK_CYCLES) == cycles && (t & @chip.tick_running) != 0
        @bus.write32(a, cycles | @chip.tick_enable)
      else
        return if (@bus.read32(a + 4) & TICK_CYCLES) == cycles && (@bus.read32(a) & @chip.tick_running) != 0
        @bus.write32(a, 0)
        @bus.write32(a + 4, cycles)
        @bus.write32(a, @chip.tick_enable)
      end
    end

    def time_us_32 = @bus.read32(@chip.timer_base + TIMERAWL)
    def time_us_31 = time_us_32 & MASK31

    # Microseconds since a time_us_31 value (correct across the 31-bit wrap)
    def us_since(start) = (time_us_31 - start) & MASK31

    def busy_wait_us_32(us)
      raise "busy_wait_us_32: #{us} us is out of range (0 to 2^31 - 1)" if us < 0
      start = time_us_31
      while us_since(start) < us
      end
    end

    def busy_wait_ms(ms)
      while ms > 1_000_000
        busy_wait_us_32(1_000_000_000)
        ms -= 1_000_000
      end
      busy_wait_us_32(ms * 1000)
    end

    # ---- alarms (pico-sdk's hardware_alarm_*): alarm n fires when the low 32 bits of the time equal its target,
    # setting flag n in INTR (and TIMER_IRQ_n when enabled); the alarm disarms itself
    def alarm_set_target(n, target_us32)
      @bus.write32(@chip.timer_base + ALARM0 + 4 * check_alarm(n), target_us32)
    end

    # Arm alarm n for us microseconds from now. The sum is done in 16-bit halves: it wraps past 2^32 as the
    # hardware does, which a 32-bit Integer cannot
    def alarm_set_in_us(n, us)
      raise "alarm delay must be 1 to 2^31 - 1 us (got #{us})" if us <= 0
      now = time_us_32
      lo = (now & 0xFFFF) + (us & 0xFFFF)
      hi = (((now >> 16) & 0xFFFF) + ((us >> 16) & 0xFFFF) + (lo >> 16)) & 0xFFFF
      @bus.write32_hl(@chip.timer_base + ALARM0 + 4 * check_alarm(n), hi, lo & 0xFFFF)
    end

    def alarm_cancel(n) = @bus.write32(@chip.timer_base + ARMED, 1 << check_alarm(n))
    def alarm_is_armed?(n) = (@bus.read32(@chip.timer_base + ARMED) & (1 << check_alarm(n))) != 0
    def alarm_fired?(n) = (@bus.read32(@chip.timer_base + @chip.timer_intr) & (1 << check_alarm(n))) != 0
    def alarm_acknowledge(n) = @bus.write32(@chip.timer_base + @chip.timer_intr, 1 << check_alarm(n))

    def alarm_set_irq_enabled(n, on)
      a = @chip.timer_base + @chip.timer_inte
      on ? @bus.set_bits(a, 1 << check_alarm(n)) : @bus.clear_bits(a, 1 << check_alarm(n))
    end

    def check_alarm(n)
      raise "timer alarm must be 0-#{NUM_ALARMS - 1} (got #{n})" unless n.between?(0, NUM_ALARMS - 1)
      n
    end
  end
end
