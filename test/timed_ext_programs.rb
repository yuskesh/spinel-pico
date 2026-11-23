# Time layer extension examples, shared by test/timed_ext_cases.rb (sim) and test/pioasm_compare.rb (pioasm)
require_relative "../lib/pico/pio"

# a SET pin and a side-set pin that change together, then apart
class TwoPins < Pico::PIO::TimedProgram
  clock 1_000_000
  output :data
  output :clk, side: true
  def main
    loop do
      data.on
      clk.on                 # rides on data.on's instruction
      sleep 3.us
      clk.off                # gets a nop
      sleep 2.us
      data.off
      sleep 5.us
    end
  end
end

# WS2812 with the data pin on side-set
class WS2812Side < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data, side: true
  def main
    loop do
      inbox.each_bit(24) do |bit|
        data.on
        sleep bit.pick(800.ns, 400.ns)
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end

# a 10 us pulse after each rising edge of a button
class Pulse < Pico::PIO::TimedProgram
  clock 1_000_000
  input :button
  output :led
  def main
    loop do
      button.wait_high
      led.on
      sleep 10.us
      led.off
      button.wait_low
    end
  end
end

# clocked input: sample din at each rising edge of sclk, 8 bits per word, MSB first
class Sampler < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  input :sclk
  def main
    outbox.autopush(8)
    loop do
      sclk.wait_high
      din.sample
      sclk.wait_low
    end
  end
end

# IRQ flag 0 every 100 us, with no pin at all
class IrqTick < Pico::PIO::TimedProgram
  clock 1_000_000
  def main
    loop do
      irq(0).set
      sleep 100.us
    end
  end
end

# raise flag 1 and wait until the CPU clears it, then a 5 us pulse
class Handshake < Pico::PIO::TimedProgram
  clock 1_000_000
  output :ready, side: true
  def main
    loop do
      irq(1).set_and_wait
      ready.on
      sleep 5.us
      ready.off
      sleep 5.us
    end
  end
end


# two SET pins: a and b rise together, a falls after 2 us, b after 5
class Phases < Pico::PIO::TimedProgram
  clock 1_000_000
  output :a
  output :b
  def main
    loop do
      a.on
      b.on                   # joins a.on's set pins
      sleep 2.us
      a.off
      sleep 3.us
      b.off
      sleep 5.us
    end
  end
end

# 4 data pins read at once at each sclk rise, two nibbles per byte
class Nibbles < Pico::PIO::TimedProgram
  clock 1_000_000
  input :d0
  input :d1
  input :d2
  input :d3
  input :sclk
  def main
    outbox.autopush(8, order: :lsb)
    loop do
      sclk.wait_high
      d0.sample(4)
      sclk.wait_low
    end
  end
end

# the High time follows an input: 10 us while it is high, 3 us while low
class Follow < Pico::PIO::TimedProgram
  clock 1_000_000
  input :mode
  output :led
  def main
    loop do
      led.on
      sleep mode.pick(10.us, 3.us)
      led.off
      sleep 5.us
    end
  end
end

# IR-style burst: 21 carrier periods (9 us on, 17 off), then 1000 us off in all
class Burst < Pico::PIO::TimedProgram
  clock 1_000_000
  output :ir
  def main
    loop do
      repeat(21) do
        ir.on
        sleep 9.us
        ir.off
        sleep 17.us
      end
      sleep 983.us           # adds to the body's last 17 us
    end
  end
end

# SPI mode 0 transmit: MOSI on the OUT pin, SCK on side-set, 8 bits per word MSB first
class SpiTx < Pico::PIO::TimedProgram
  clock 1_000_000
  output :sck, side: true
  output :mosi, out: true
  def main
    loop do
      inbox.each_bit(8) do |bit|
        sck.off
        mosi.put(bit)        # sck.off rides on it
        sleep 2.us
        sck.on
        sleep 2.us
      end
    end
  end
end

# a long pick: the pin is read when the wait begins, whatever the wait's length
class LongPick < Pico::PIO::TimedProgram
  clock 1_000_000
  input :mode
  def main
    loop do
      irq(1).set
      sleep mode.pick(1000.us, 3000.us)
    end
  end
end

# bit.branch: Manchester (IEEE 802.3) with the SET pin: 1 = low then high, 0 = high then low, 4 cycles each half.
# The second half's sleep leads to the next bit's first statement, through the jmp to the end and the next out / jmp
class Manchester < Pico::PIO::TimedProgram
  clock 1_000_000
  output :tx
  def main
    loop do
      inbox.each_bit(8) do |bit|
        bit.branch do |one|
          if one
            tx.off
            sleep 4.cycles
            tx.on
          else
            tx.on
            sleep 4.cycles
            tx.off
          end
          sleep 4.cycles
        end
      end
    end
  end
end

# din.branch: while din is high, a 3-cycle pulse on led and flag 0; while low, flag 1 only. 11 cycles per pass while
# high, 7 while low
class Gate < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  output :led
  def main
    loop do
      irq(2).set
      sleep 2.cycles
      din.branch do |high|
        if high
          led.on
          sleep 3.cycles
          led.off
          irq(0).set
        else
          irq(1).set
        end
        sleep 2.cycles
      end
      sleep 3.cycles
    end
  end
end

# side-set paths that end at different levels: the next instruction must set the pin (SideSplit does not: rejected;
# SideJoin does)
class SideSplit < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  output :clk, side: true
  def main
    loop do
      irq(0).set
      din.branch do |high|
        if high
          clk.on
          irq(1).set
        else
          irq(2).set
        end
      end
      irq(3).set
    end
  end
end

class SideJoin < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  output :clk, side: true
  def main
    loop do
      irq(0).set
      din.branch do |high|
        if high
          clk.on
          irq(1).set
          sleep 3.cycles
        else
          irq(2).set
          sleep 2.cycles
        end
      end
      clk.off
      irq(3).set
    end
  end
end

# inbox.preset: the period in the ISR (loaded by the CPU), the duty received while running (as pico-examples' PWM)
class PresetPwm < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    period = inbox.preset
    loop do
      duty = inbox.current
      led.on
      sleep duty
      led.off
      sleep period
    end
  end
end

# out pins, 8: an 8-bit parallel bus with a write strobe on side-set (as an 8080-style LCD write), 4 bytes per word
class Parallel8 < Pico::PIO::TimedProgram
  clock 1_000_000
  output :data, out: true, width: 8
  output :wr, side: true
  def main
    loop do
      wr.off
      data.write(inbox.next(8))
      sleep 2.cycles
      wr.on
      sleep 2.cycles
    end
  end
end

# nested din.branch: read btn, and if it was high read it again 5 cycles later. 10 cycles per pass on every path
# (high: 2 + 5 + 2 + 1, low: 2 + 7 + 1)
class Confirm < Pico::PIO::TimedProgram
  clock 1_000_000
  input :btn
  def main
    loop do
      irq(3).set
      sleep 2.cycles
      btn.branch do |high|
        if high
          sleep 5.cycles
          btn.branch do |still|
            if still
              irq(0).set
            else
              irq(1).set
            end
            sleep 2.cycles
          end
        else
          irq(2).set
          sleep 7.cycles
        end
      end
      sleep 1.cycles
    end
  end
end

# a repeat inside a repeat (the inner one counts in Y): 2 groups of 3 pulses, then a longer gap
class Groups < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop do
      repeat(2) do
        repeat(3) do
          led.on
          sleep 2.cycles
          led.off
          sleep 3.cycles
        end
        sleep 10.cycles
      end
      sleep 20.cycles
    end
  end
end

# a branch inside a repeat: two reads of din 6 cycles apart, then flag 3
class TwoReads < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  def main
    loop do
      repeat(2) do
        irq(2).set
        sleep 2.cycles
        din.branch do |high|
          if high
            irq(0).set
          else
            irq(1).set
          end
          sleep 4.cycles
        end
      end
      irq(3).set
      sleep 5.cycles
    end
  end
end

# each_bit inside a repeat: two 4-bit words per pass, then flag 0
class TwoWords < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop do
      repeat(2) do
        w = inbox.take
        w.each_bit(4) do |bit|
          led.on
          sleep bit.pick(6.cycles, 3.cycles)
          led.off
          sleep 4.cycles
        end
      end
      irq(0).set
      sleep 3.cycles
    end
  end
end

# a repeat inside each_bit: two short pulses per bit, then a gap that depends on the bit
class DoublePulse < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop do
      inbox.each_bit(8) do |bit|
        repeat(2) do
          led.on
          sleep 2.cycles
          led.off
          sleep 2.cycles
        end
        sleep bit.pick(8.cycles, 4.cycles)
      end
    end
  end
end

# branches on two inputs: en is the JMP pin (the first one used); dir (input 1) is read through the OSR into Y
class TwoInputs < Pico::PIO::TimedProgram
  clock 1_000_000
  input :en
  input :dir
  def main
    loop do
      irq(4).set
      sleep 2.cycles
      en.branch do |on|
        if on
          sleep 4.cycles
          dir.branch do |up|
            if up
              irq(0).set
            else
              irq(1).set
            end
            sleep 3.cycles
          end
        else
          irq(2).set
          sleep 7.cycles
        end
      end
    end
  end
end

# a pick on the second input: its level is read 3 cycles before the branch
class PickSecond < Pico::PIO::TimedProgram
  clock 1_000_000
  input :en
  input :rate
  output :led
  def main
    loop do
      led.on
      sleep en.pick(5.cycles, 3.cycles)
      led.off
      sleep rate.pick(12.cycles, 6.cycles)
    end
  end
end
