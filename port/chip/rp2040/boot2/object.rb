#!/usr/bin/env ruby
# frozen_string_literal: true
#
# chip/rp2040/boot2/object.rb -- the RP2040's second stage as an object.
#
#   object.rb --board BOARD.yaml --header bf-board.h --out DIR -- CC [FLAG...]
#
# The boot ROM copies the first 256 bytes of flash into RAM, checks the CRC-32
# of the first 252 against the last 4, and runs them. This assembles the
# second stage the board names (flash.boot2: NAME is NAME.S beside this file)
# with the board's values, pads it to 252 bytes, appends the checksum, and
# puts the 256 bytes into DIR/chip-boot2.o as section .boot2, which the
# family's link part places first in flash. The intermediates go to
# DIR/boot2/. It prints the object's path. CC and its flags are the compiler
# for the target, as the driver gives them; llvm-objcopy is taken from beside
# CC.
require "fileutils"
require "open3"
require "yaml"

def die(msg)
  warn "rp2040 boot2: #{msg}"
  exit 1
end

def run!(*cmd)
  out, st = Open3.capture2e(*cmd)
  die("failed: #{cmd.first(3).join(' ')} ...\n#{out}") unless st.success?
end

# The boot ROM's check, as its own code does it (its CRC loop at 0x25b4,
# called with 252 bytes and a start of 0xffffffff, the result compared with
# the word after them): CRC-32, polynomial 0x04c11db7, most significant bit
# first, from 0xffffffff, with no final xor
def boot2_crc(bytes)
  crc = 0xffffffff
  bytes.each_byte do |b|
    crc ^= b << 24
    8.times { crc = (crc & 0x80000000).zero? ? (crc << 1) : ((crc << 1) ^ 0x04c11db7) }
    crc &= 0xffffffff
  end
  crc
end

opts = {}
args = ARGV.dup
until args.empty? || args.first == "--"
  k = args.shift
  die("usage: object.rb --board BOARD.yaml --header bf-board.h --out DIR -- CC [FLAG...]") unless
    %w[--board --header --out].include?(k) && !args.empty?
  opts[k] = args.shift
end
args.shift
cc = args
die("usage: object.rb --board BOARD.yaml --header bf-board.h --out DIR -- CC [FLAG...]") unless
  cc.any? && %w[--board --header --out].all? { |k| opts[k] }

name = YAML.safe_load_file(opts["--board"]).dig("flash", "boot2").to_s
src = File.join(__dir__, "#{name}.S")
die("flash.boot2 is #{name.inspect}; there is no #{name}.S beside #{File.basename(__FILE__)}") unless
  name.match?(/\A[a-z0-9_]+\z/) && File.file?(src)
out = opts["--out"]
work = File.join(out, "boot2")
FileUtils.mkdir_p(work)
cc += ["-include", opts["--header"]]
raw = File.join(work, "boot2.o")
run!(*cc, "-c", src, "-o", raw)
bin = File.join(work, "boot2.bin")
run!(File.join(File.dirname(cc.first), "llvm-objcopy"), "-O", "binary", "--only-section=.text", raw, bin)
code = File.binread(bin)
die("#{name} is #{code.bytesize} bytes; at most 252 fit") if code.bytesize > 252
code += "\0" * (252 - code.bytesize)
code += [boot2_crc(code)].pack("V")
asm = File.join(work, "boot2-crc.S")
File.write(asm, ".section .boot2, \"ax\"\n" + code.bytes.each_slice(16).map { |s| ".byte #{s.join(', ')}\n" }.join)
obj = File.join(out, "chip-boot2.o")
run!(*cc, "-c", asm, "-o", obj)
puts obj
