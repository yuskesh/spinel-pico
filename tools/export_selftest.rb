# Assemble the programs used by examples/rp2040/selftest.rb on the host and emit them as Pico::PIO::Program Ruby
#   ruby tools/export_selftest.rb > examples/rp2040/selftest_programs.rb
require_relative "../lib/pico/pio"

PIN = 25

class WS2812At12MHz < Pico::PIO::TimedProgram
  clock 12_000_000            # clk_sys of RP2040 under bare-full
  tolerance 150.ns
  output :data
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

# ---- time layer extensions (examples/rp2040/timed_selftest.rb)
# WS2812 with the data pin on side-set (same timing as WS2812At12MHz)
class WS2812SideAt12MHz < Pico::PIO::TimedProgram
  clock 12_000_000
  tolerance 150.ns
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

# raise IRQ flag 0 on each rising edge of the input and flag 1 on each falling edge
class EdgeIrq < Pico::PIO::TimedProgram
  clock 12_000_000
  input :button
  def main
    loop do
      button.wait_high
      irq(0).set
      button.wait_low
      irq(1).set
    end
  end
end

# 4 cycles High, 4 Low
class Gen8 < Pico::PIO::TimedProgram
  clock 12_000_000
  output :data
  def main = loop { data.on; sleep 4.cycles; data.off; sleep 4.cycles }
end

# sample the input every 2 cycles, 8 samples per word, MSB first
class Sample2 < Pico::PIO::TimedProgram
  clock 12_000_000
  input :din
  def main
    outbox.autopush(8)
    loop { din.sample; sleep 2.cycles }
  end
end

# raise flag 1, wait until the CPU clears it, then a 20-cycle pulse on a side-set pin
class Handshake20 < Pico::PIO::TimedProgram
  clock 12_000_000
  output :ready, side: true
  def main
    loop do
      irq(1).set_and_wait
      ready.on
      sleep 20.cycles
      ready.off
      sleep 20.cycles
    end
  end
end

# IRQ flag 2 every 10 ms (long enough that a GC pause in the polling CPU does not merge two)
class IrqTick10ms < Pico::PIO::TimedProgram
  clock 100_000
  def main = loop { irq(2).set; sleep 10_000.us }
end

# repeat: 3 pulses of 5 / 10 cycles, then 30 more cycles Low (40 after the last pulse)
class Burst3 < Pico::PIO::TimedProgram
  clock 12_000_000
  output :ir
  def main
    loop do
      repeat(3) do
        ir.on
        sleep 5.cycles
        ir.off
        sleep 10.cycles
      end
      sleep 30.cycles
    end
  end
end

# input pick: IRQ flag 1 every 10 ms while the input is high, every 30 ms while low (long enough for a polling CPU)
class PickTick < Pico::PIO::TimedProgram
  clock 100_000
  input :mode
  def main
    loop do
      irq(1).set
      sleep mode.pick(10_000.us, 30_000.us)
    end
  end
end

# OUT pin: SPI mode 0 transmit, 4 cycles per bit
class SpiTx12 < Pico::PIO::TimedProgram
  clock 12_000_000
  output :sck, side: true
  output :mosi, out: true
  def main
    loop do
      inbox.each_bit(8) do |bit|
        sck.off
        mosi.put(bit)
        sleep 2.cycles
        sck.on
        sleep 2.cycles
      end
    end
  end
end

# Count the pin's High width: wait for a rising edge, then decrement x once every 2 cycles until it goes Low
high = Pico::PIO.asm(:sample_high) do
  wrap_target
  wait 0, :gpio, PIN
  wait 1, :gpio, PIN
  mov :x, :null, op: :invert
  label :count
  jmp :x_dec, :next
  label :next
  jmp :pin, :count
  mov :isr, :x, op: :invert
  push block: false
  wrap
end

# Low width
low = Pico::PIO.asm(:sample_low) do
  wrap_target
  wait 1, :gpio, PIN
  wait 0, :gpio, PIN
  mov :x, :null, op: :invert
  label :count
  jmp :pin, :done
  jmp :x_dec, :count
  label :done
  mov :isr, :x, op: :invert
  push block: false
  wrap
end

# bit.branch: Manchester, 4-cycle halves (1 = low then high, 0 = high then low)
class Manchester12 < Pico::PIO::TimedProgram
  clock 12_000_000
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

# din.branch: IRQ flag 0 every 10 ms while the input is high, flag 1 while low
class GateTick < Pico::PIO::TimedProgram
  clock 100_000
  input :din
  def main
    loop do
      din.branch do |high|
        if high
          irq(0).set
        else
          irq(1).set
        end
        sleep 10_000.us
      end
    end
  end
end

# inbox.preset: Low = the ISR value + 5, High = the received value + 3
class PresetPwm12 < Pico::PIO::TimedProgram
  clock 12_000_000
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

# out pins, n with autopull (one pin here): a bit of the received word every 4 cycles, MSB first
class OutNext12 < Pico::PIO::TimedProgram
  clock 12_000_000
  output :d, out: true, width: 1
  def main
    loop do
      d.write(inbox.next(1))
      sleep 4.cycles
    end
  end
end

# mov_status and clock_div: STATUS is all ones while the TX FIFO is empty; each pass pushes it
status = Pico::PIO.asm(:status_probe) do
  mov_status :txfifo, 1
  clock_div 2.5
  wrap_target
  mov :isr, :status
  push block: false
  wrap
end

# a repeat inside a repeat: 2 groups of 3 pulses (2 High / 3 Low), 13 Low after a group, 33 after the second
class Groups12 < Pico::PIO::TimedProgram
  clock 12_000_000
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

# branches on two inputs: en (the JMP pin) and dir (read through the OSR): flag 0 for en and dir, 1 for en only, 2 without en
class GateTwo < Pico::PIO::TimedProgram
  clock 100_000
  input :en
  input :dir
  def main
    loop do
      en.branch do |on|
        if on
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

puts "# Generated by: ruby tools/export_selftest.rb (do not edit by hand)"
puts "SELFTEST_PIN = #{PIN}"
puts WS2812At12MHz.assemble.assembled.to_ruby("WS2812_12MHZ")
puts high.to_ruby("SAMPLE_HIGH")
puts low.to_ruby("SAMPLE_LOW")
puts WS2812SideAt12MHz.assemble.assembled.to_ruby("WS2812_SIDE_12MHZ")
puts EdgeIrq.assemble.assembled.to_ruby("EDGE_IRQ")
puts Gen8.assemble.assembled.to_ruby("GEN8")
puts Sample2.assemble.assembled.to_ruby("SAMPLE2")
puts Handshake20.assemble.assembled.to_ruby("HANDSHAKE20")
puts IrqTick10ms.assemble.assembled.to_ruby("IRQ_TICK_10MS")
puts Burst3.assemble.assembled.to_ruby("BURST3")
puts PickTick.assemble.assembled.to_ruby("PICK_TICK")
puts SpiTx12.assemble.assembled.to_ruby("SPI_TX12")
puts Manchester12.assemble.assembled.to_ruby("MANCHESTER12")
puts GateTick.assemble.assembled.to_ruby("GATE_TICK")
puts PresetPwm12.assemble.assembled.to_ruby("PRESET_PWM12")
puts OutNext12.assemble.assembled.to_ruby("OUT_NEXT12")
puts status.to_ruby("STATUS_PROBE")
puts Groups12.assemble.assembled.to_ruby("GROUPS12")
puts GateTwo.assemble.assembled.to_ruby("GATE_TWO")
