# Notes on Spinel

## Known differences from Spinel

In Spinel, constants inside a `define_method` block are resolved in the subclass scope. `lib/pico/pio.rb` avoids this by writing the fully qualified name `Pico::PIO::Output`.

`<<` on a value Spinel cannot type (for example `(n & 15) << 12` where `n` comes from an Array that mixes Integers and Strings) generates a dispatch that can also reach `IO#write` and `Queue#push`, which use socket and sleep functions. bare-full supplies `send`, `getsockopt`, `fcntl`, `poll` and `nanosleep` (the first four only to fail), so such a program links. `[2, 4, 8, 12].index(ma)` has the same effect; `gpio.rb` uses `case` there.

A method that no program calls still constrains the methods it calls: Spinel cannot type its parameters, so a value derived from one widens the parameter it is passed to everywhere. Example:

```ruby
class T
  def now = 100
  def since(start) = now - start
end

class U
  def wait(timer)              # never called
    timer.since(timer.now)
  end
end

t = T.new
puts t.since(t.now)            # T#since now takes a boxed value
```

`Pico::UART#getc_timeout(timer, ...)` works out the elapsed time itself for this reason: calling `Pico::Timer#us_since` there would make every `us_since` call box its argument, in programs that never use `getc_timeout` too.

Calling, through a class held in a variable, a class method whose result is a method call on `new` (for example `klass.make` where `def self.make = new.done`) makes Spinel's C code generator emit a call to a function it never defines, and the C compile fails. `TimedProgram.assemble` has this shape, so the tests assemble with the class written directly (`check(PerWord.assemble)`) instead of passing the class (`check(PerWord)`). Writing `o = new; o` or calling `A.make` directly does not trigger it.
