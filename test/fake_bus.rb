# A bus that just records writes, for checking register values on the host (no microcontroller needed).
# Registers read back what was written; fix(addr, value) makes a register always read a given value
# (for example status bits the hardware would set). Like MMIOBus on bare-full, read32 returns a signed 32-bit
# Integer (negative when bit 31 is set)
class FakeBus
  attr_reader :mem, :log

  def initialize
    @mem = {}
    @fixed = {}
    @log = []
  end

  def fix(a, v)
    @fixed[a] = v
  end

  def read32(a)
    v = @fixed[a]
    v = @mem[a] || 0 if v.nil?
    v &= 0xFFFFFFFF
    v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
  end

  def store(a, v)
    @mem[a] = v & 0xFFFFFFFF
    @log << [a, v & 0xFFFFFFFF]
  end

  def write32(a, v) = store(a, v)
  def write32_hl(a, hi, lo) = store(a, (hi << 16) | (lo & 0xFFFF))
  def set_bits(a, m) = store(a, (@mem[a] || 0) | m)
  def clear_bits(a, m) = store(a, (@mem[a] || 0) & ~m)
  def xor_bits(a, m) = store(a, (@mem[a] || 0) ^ m)
  def write_masked(a, v, mask) = xor_bits(a, (read32(a) ^ v) & mask)
  def writes_to(a) = @log.select { |e| e[0] == a }.map { |e| e[1] }
end

$fail = 0
def expect(what, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts "#{ok ? 'OK  ' : 'NG  '}#{what}: #{format('0x%08x', got)}#{ok ? '' : format(' (expected 0x%08x)', want)}"
end

def raises(what)
  yield
  puts "NG  #{what}: did not raise"
  $fail += 1
rescue => e
  puts "OK  #{what}: raised (#{e.message})"
end
