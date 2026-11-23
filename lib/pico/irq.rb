# Interrupts (names follow pico-sdk's hardware_irq without the irq_ prefix: irq_set_enabled -> IRQ.set_enabled).
# Device only (Spinel FFI).
#
# Ruby does not run inside the interrupt: Spinel code may allocate and run the GC, which an interrupt must not do.
# Instead every peripheral interrupt goes to one C handler that records it and switches that line off in the NVIC,
# so a source that stays asserted does not fire again and again. The program then sees it with fired?(n) or by
# sleeping in wait_for_interrupt / wait(n, ...), deals with the source (clears the peripheral's flag), and calls
# acknowledge(n), which clears the record and switches the line back on. Clear the source before acknowledge: if it is
# still asserted, the interrupt fires again at once.
#
# The first set_enabled copies bare-full's vector table (16 words: the core's exceptions, used for faults and SysTick)
# into RAM, adds the 32 peripheral entries, and points VTOR at the copy. Interrupt numbers come from
# chip.irq(:timer_irq_0), chip.irq(:dma_irq_0), ...
require_relative "chip"

module Pico
  module IRQFFI
    ffi_source <<~C
      #include <stdint.h>
      #define PICO_VTOR (*(volatile uint32_t *)0xE000ED08u)
      #define PICO_NVIC_ISER (*(volatile uint32_t *)0xE000E100u)
      #define PICO_NVIC_ICER (*(volatile uint32_t *)0xE000E180u)
      #define PICO_NVIC_ISPR (*(volatile uint32_t *)0xE000E200u)
      #define PICO_NVIC_ICPR (*(volatile uint32_t *)0xE000E280u)
      #define PICO_NVIC_IPR ((volatile uint32_t *)0xE000E400u)
      static uint32_t pico_irq_vectors[48] __attribute__((aligned(256)));
      static volatile uint32_t pico_irq_counts[32];
      static volatile uint32_t pico_irq_fired;      /* recorded by the handler, cleared by acknowledge */
      static volatile uint32_t pico_irq_wanted;     /* lines the program has enabled */

      static void pico_irq_handler(void) {
        uint32_t ipsr;
        __asm volatile("mrs %0, ipsr" : "=r"(ipsr));
        uint32_t n = (ipsr & 0x3fu) - 16u;
        PICO_NVIC_ICER = 1u << n;
        pico_irq_counts[n]++;
        pico_irq_fired |= 1u << n;                  /* the program changes it only with interrupts masked */
      }

      static void pico_irq_install(void) {
        if (PICO_VTOR == (uint32_t)(uintptr_t)pico_irq_vectors) return;
        const uint32_t *old = (const uint32_t *)(uintptr_t)PICO_VTOR;
        for (int i = 0; i < 16; i++) pico_irq_vectors[i] = old[i];
        for (int i = 16; i < 48; i++) pico_irq_vectors[i] = (uint32_t)(uintptr_t)pico_irq_handler;
        __asm volatile("dsb" ::: "memory");
        PICO_VTOR = (uint32_t)(uintptr_t)pico_irq_vectors;
        __asm volatile("dsb\\n isb" ::: "memory");
      }

      static intptr_t pico_irq_set_enabled(intptr_t n, intptr_t on) {
        uint32_t m = 1u << n;
        if (on) {
          pico_irq_install();
          pico_irq_wanted |= m;
          PICO_NVIC_ICPR = m;                       /* forget an interrupt that was pending before */
          PICO_NVIC_ISER = m;
        } else {
          PICO_NVIC_ICER = m;
          pico_irq_wanted &= ~m;
        }
        return 0;
      }

      static intptr_t pico_irq_is_enabled(intptr_t n) { return (pico_irq_wanted >> n) & 1u; }
      static intptr_t pico_irq_line_on(intptr_t n) { return (PICO_NVIC_ISER >> n) & 1u; }
      static intptr_t pico_irq_set_pending(intptr_t n) { PICO_NVIC_ISPR = 1u << n; return 0; }
      static intptr_t pico_irq_clear_pending(intptr_t n) { PICO_NVIC_ICPR = 1u << n; return 0; }
      static intptr_t pico_irq_is_pending(intptr_t n) { return (PICO_NVIC_ISPR >> n) & 1u; }

      static intptr_t pico_irq_set_priority(intptr_t n, intptr_t prio) {
        volatile uint32_t *r = &PICO_NVIC_IPR[n >> 2];
        uint32_t shift = 8u * ((uint32_t)n & 3u);
        *r = (*r & ~(0xffu << shift)) | (((uint32_t)prio & 0xc0u) << shift);   /* M0+: top 2 bits only */
        return 0;
      }

      static intptr_t pico_irq_get_priority(intptr_t n) { return (PICO_NVIC_IPR[n >> 2] >> (8u * ((uint32_t)n & 3u))) & 0xffu; }
      static intptr_t pico_irq_fired_mask(void) { return (intptr_t)pico_irq_fired; }
      static intptr_t pico_irq_count(intptr_t n) { return (intptr_t)pico_irq_counts[n]; }

      static intptr_t pico_irq_acknowledge(intptr_t n) {
        uint32_t m = 1u << n, primask;
        __asm volatile("mrs %0, primask\\n cpsid i" : "=r"(primask) :: "memory");
        pico_irq_fired &= ~m;
        __asm volatile("msr primask, %0" :: "r"(primask) : "memory");
        if (pico_irq_wanted & m) {
          /* the NVIC kept the request that came while the line was off; drop it, or switching the line on fires
             it again. A source still asserted pends again at once */
          PICO_NVIC_ICPR = m;
          PICO_NVIC_ISER = m;
        }
        return 0;
      }

      static intptr_t pico_irq_wfi(void) { __asm volatile("wfi" ::: "memory"); return 0; }
    C
    ffi_func :pico_irq_set_enabled, [:long, :long], :long
    ffi_func :pico_irq_is_enabled, [:long], :long
    ffi_func :pico_irq_line_on, [:long], :long
    ffi_func :pico_irq_set_pending, [:long], :long
    ffi_func :pico_irq_clear_pending, [:long], :long
    ffi_func :pico_irq_is_pending, [:long], :long
    ffi_func :pico_irq_set_priority, [:long, :long], :long
    ffi_func :pico_irq_get_priority, [:long], :long
    ffi_func :pico_irq_fired_mask, [], :long
    ffi_func :pico_irq_count, [:long], :long
    ffi_func :pico_irq_acknowledge, [:long], :long
    ffi_func :pico_irq_wfi, [], :long
  end

  module IRQ
    # RP2040 only: the vector table and the NVIC words here are the Cortex-M0+'s 32 interrupts (RP2350 has 52 on its
    # Cortex-M33s)
    def self.check(n)
      raise "interrupt number must be 0-31 (got #{n})" unless n.between?(0, 31)
      n
    end

    def self.set_enabled(n, on) = IRQFFI.pico_irq_set_enabled(check(n), on ? 1 : 0)
    def self.is_enabled?(n) = IRQFFI.pico_irq_is_enabled(check(n)) != 0

    # Whether the line is switched on in the NVIC right now (off between a fire and acknowledge)
    def self.line_on?(n) = IRQFFI.pico_irq_line_on(check(n)) != 0

    # Make the interrupt pending by software (pico-sdk's irq_set_pending); clear_pending is pico-sdk's irq_clear
    def self.set_pending(n) = IRQFFI.pico_irq_set_pending(check(n))
    def self.clear_pending(n) = IRQFFI.pico_irq_clear_pending(check(n))
    def self.is_pending?(n) = IRQFFI.pico_irq_is_pending(check(n)) != 0

    # 0 (highest) to 255; the RP2040's Cortex-M0+ keeps only the top 2 bits (0, 64, 128, 192)
    def self.set_priority(n, prio)
      raise "interrupt priority must be 0-255 (got #{prio})" unless prio.between?(0, 255)
      IRQFFI.pico_irq_set_priority(check(n), prio)
    end

    def self.get_priority(n) = IRQFFI.pico_irq_get_priority(check(n))

    # Fired since the last acknowledge(n)
    def self.fired?(n) = ((IRQFFI.pico_irq_fired_mask >> check(n)) & 1) != 0

    # Times the interrupt has fired since the program started
    def self.count(n) = IRQFFI.pico_irq_count(check(n))

    def self.acknowledge(n) = IRQFFI.pico_irq_acknowledge(check(n))

    # Sleep until an interrupt arrives (pico-sdk's __wfi). Only lines switched on in the NVIC wake the core, and
    # bare-full runs no periodic interrupt, so call it only when an enabled interrupt is sure to come (an alarm set
    # with Timer#alarm_set_target, a DMA transfer that will finish, ...)
    def self.wait_for_interrupt = IRQFFI.pico_irq_wfi

    # Wait until interrupt n has fired or timeout_us of the given Pico::Timer has passed; true if it fired.
    # It checks without sleeping, so it also returns on time when no interrupt comes
    def self.wait(n, timer, timeout_us)
      start = timer.time_us_31
      until fired?(n)
        return false if ((timer.time_us_31 - start) & 0x7FFF_FFFF) >= timeout_us
      end
      true
    end
  end
end
