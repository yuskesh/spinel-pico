# Check spinel-pico's register numbers against pico-sdk's headers, for each chip: prints a C file of _Static_asserts
# (one per value) that tools/regs_check.sh compiles with that chip's hardware_regs headers.
#   ruby tools/regs_check.rb rp2040|rp2350 > check.c
require_relative "../lib/pico/chip"
require_relative "../lib/pico/gpio"
require_relative "../lib/pico/timer"
require_relative "../lib/pico/clocks"
require_relative "../lib/pico/dma"
require_relative "../lib/pico/pwm"
require_relative "../lib/pico/adc"
require_relative "../lib/pico/uart"
require_relative "../lib/pico/spi"
require_relative "../lib/pico/i2c"
require_relative "../lib/pico/pio/runtime"
require_relative "../lib/pico/usb_device"

chip_name = ARGV[0] || "rp2040"
chip = chip_name == "rp2350" ? Pico::Chip.rp2350 : Pico::Chip.rp2040
checks = []
add = ->(ruby, c, what) { checks << [ruby & 0xFFFF_FFFF, c, what] }

# ---- the chip table
add.(chip.resets_base, "RESETS_BASE", "resets_base")
add.(chip.io_bank0_base, "IO_BANK0_BASE", "io_bank0_base")
add.(chip.pads_bank0_base, "PADS_BANK0_BASE", "pads_bank0_base")
add.(chip.sio_base, "SIO_BASE", "sio_base")
add.(chip.clocks_base, "CLOCKS_BASE", "clocks_base")
add.(chip.xosc_base, "XOSC_BASE", "xosc_base")
add.(chip.pll_sys_base, "PLL_SYS_BASE", "pll_sys_base")
add.(chip.pll_usb_base, "PLL_USB_BASE", "pll_usb_base")
add.(chip.watchdog_base, "WATCHDOG_BASE", "watchdog_base")
add.(chip.timer_base, chip.rp2040? ? "TIMER_BASE" : "TIMER0_BASE", "timer_base")
add.(chip.xip_base, "XIP_BASE", "xip_base")
chip.uart_bases.each_with_index { |b, i| add.(b, "UART#{i}_BASE", "uart_bases[#{i}]") }
chip.pio_bases.each_with_index { |b, i| add.(b, "PIO#{i}_BASE", "pio_bases[#{i}]") }
chip.spi_bases.each_with_index { |b, i| add.(b, "SPI#{i}_BASE", "spi_bases[#{i}]") }
chip.i2c_bases.each_with_index { |b, i| add.(b, "I2C#{i}_BASE", "i2c_bases[#{i}]") }
add.(chip.pwm_base, "PWM_BASE", "pwm_base")
add.(chip.adc_base, "ADC_BASE", "adc_base")
add.(chip.dma_base, "DMA_BASE", "dma_base")
add.(chip.num_dma_channels, "NUM_DMA_CHANNELS", "num_dma_channels")
add.(chip.num_pwm_slices, "NUM_PWM_SLICES", "num_pwm_slices")
add.(chip.num_gpio, "NUM_BANK0_GPIOS", "num_gpio")
add.(chip.adc_temp_channel, "(NUM_ADC_CHANNELS - 1)", "adc_temp_channel")
add.(chip.adc_first_gpio, "ADC_BASE_PIN", "adc_first_gpio")
chip.reset_bits.each { |k, v| add.(1 << v, "RESETS_RESET_#{k.upcase}_BITS", "reset_bits[:#{k}]") }
chip.dreqs.each { |k, v| add.(v, "DREQ_#{k.upcase}", "dreqs[:#{k}]") }
chip.irqs.each { |k, v| add.(v, k.to_s.upcase, "irqs[:#{k}]") }
chip.funcsel.each { |k, v| add.(v, "GPIO_FUNC_#{k == :null ? 'NULL' : k.upcase}", "funcsel[:#{k}]") }
%w[gpio_in gpio_out out_set out_clr out_xor gpio_oe oe_set oe_clr oe_xor].each do |f|
  c = { "gpio_in" => "GPIO_IN", "gpio_out" => "GPIO_OUT", "out_set" => "GPIO_OUT_SET", "out_clr" => "GPIO_OUT_CLR",
        "out_xor" => "GPIO_OUT_XOR", "gpio_oe" => "GPIO_OE", "oe_set" => "GPIO_OE_SET", "oe_clr" => "GPIO_OE_CLR",
        "oe_xor" => "GPIO_OE_XOR" }[f]
  add.(chip.send("sio_#{f}"), "SIO_#{c}_OFFSET", "sio_#{f}")
end
add.(Pico::XOR_ALIAS, "REG_ALIAS_XOR_BITS", "XOR_ALIAS")
add.(Pico::SET_ALIAS, "REG_ALIAS_SET_BITS", "SET_ALIAS")
add.(Pico::CLR_ALIAS, "REG_ALIAS_CLR_BITS", "CLR_ALIAS")
add.(Pico::RESETS_RESET, "RESETS_RESET_OFFSET", "RESETS_RESET")
add.(Pico::RESETS_DONE, "RESETS_RESET_DONE_OFFSET", "RESETS_DONE")

# ---- driver constants: [Ruby constant, pico-sdk name]
G = Pico::GPIO
[[G::PAD_SLEWFAST, "PADS_BANK0_GPIO0_SLEWFAST_BITS"], [G::PAD_SCHMITT, "PADS_BANK0_GPIO0_SCHMITT_BITS"],
 [G::PAD_PDE, "PADS_BANK0_GPIO0_PDE_BITS"], [G::PAD_PUE, "PADS_BANK0_GPIO0_PUE_BITS"],
 [G::PAD_DRIVE_LSB, "PADS_BANK0_GPIO0_DRIVE_LSB"], [G::PAD_DRIVE, "PADS_BANK0_GPIO0_DRIVE_BITS"],
 [G::PAD_IE, "PADS_BANK0_GPIO0_IE_BITS"], [G::PAD_OD, "PADS_BANK0_GPIO0_OD_BITS"],
 [G::CTRL_FUNCSEL, "IO_BANK0_GPIO0_CTRL_FUNCSEL_BITS"], [G::CTRL_INOVER_LSB, "IO_BANK0_GPIO0_CTRL_INOVER_LSB"],
 [G::CTRL_IRQOVER_LSB, "IO_BANK0_GPIO0_CTRL_IRQOVER_LSB"]].each { |v, c| add.(v, c, "GPIO #{c}") }
add.(G::PAD_ISO, "PADS_BANK0_GPIO0_ISO_BITS", "GPIO PAD_ISO") unless chip.rp2040?
add.(chip.gpio_intr0, "IO_BANK0_INTR0_OFFSET", "gpio_intr0")
add.(chip.gpio_proc0_inte0, "IO_BANK0_PROC0_INTE0_OFFSET", "gpio_proc0_inte0")
add.(chip.gpio_proc0_ints0, "IO_BANK0_PROC0_INTS0_OFFSET", "gpio_proc0_ints0")

T = Pico::Timer
tp = "TIMER"
[[T::ALARM0, "#{tp}_ALARM0_OFFSET"], [T::ARMED, "#{tp}_ARMED_OFFSET"], [T::TIMERAWH, "#{tp}_TIMERAWH_OFFSET"],
 [T::TIMERAWL, "#{tp}_TIMERAWL_OFFSET"]].each { |v, c| add.(v, c, "Timer #{c}") }
if chip.rp2040?
  add.(chip.tick_base, "WATCHDOG_BASE", "tick_base")
  add.(chip.tick_ctrl, "WATCHDOG_TICK_OFFSET", "tick_ctrl")
  [[T::TICK_CYCLES, "WATCHDOG_TICK_CYCLES_BITS"], [T::TICK_ENABLE, "WATCHDOG_TICK_ENABLE_BITS"],
   [T::TICK_RUNNING, "WATCHDOG_TICK_RUNNING_BITS"]].each { |v, c| add.(v, c, "Timer #{c}") }
else
  add.(chip.tick_base, "TICKS_BASE", "tick_base")
  add.(chip.tick_ctrl, "TICKS_TIMER0_CTRL_OFFSET", "tick_ctrl")
  add.(chip.tick_ctrl + 4, "TICKS_TIMER0_CYCLES_OFFSET", "tick_ctrl + 4 (CYCLES)")
  [[T::TICK_CYCLES, "TICKS_TIMER0_CYCLES_BITS"]].each { |v, c| add.(v, c, "Timer #{c}") }
  add.(chip.tick_enable, "TICKS_TIMER0_CTRL_ENABLE_BITS", "tick_enable")
  add.(chip.tick_running, "TICKS_TIMER0_CTRL_RUNNING_BITS", "tick_running")
end

C = Pico::Clocks
[[C::CLK_REF_CTRL, "CLOCKS_CLK_REF_CTRL_OFFSET"], [C::CLK_REF_DIV, "CLOCKS_CLK_REF_DIV_OFFSET"],
 [C::CLK_REF_SELECTED, "CLOCKS_CLK_REF_SELECTED_OFFSET"], [C::CLK_SYS_CTRL, "CLOCKS_CLK_SYS_CTRL_OFFSET"],
 [C::CLK_SYS_DIV, "CLOCKS_CLK_SYS_DIV_OFFSET"], [C::CLK_SYS_SELECTED, "CLOCKS_CLK_SYS_SELECTED_OFFSET"],
 [C::CLK_PERI_CTRL, "CLOCKS_CLK_PERI_CTRL_OFFSET"], [C::CLK_PERI_SELECTED, "CLOCKS_CLK_PERI_SELECTED_OFFSET"],
 [C::CTRL_ENABLE, "CLOCKS_CLK_PERI_CTRL_ENABLE_BITS"], [C::CTRL_AUXSRC, "CLOCKS_CLK_PERI_CTRL_AUXSRC_BITS"],
 [C::FC0_STATUS_DONE, "CLOCKS_FC0_STATUS_DONE_BITS"], [C::FC0_STATUS_RUNNING, "CLOCKS_FC0_STATUS_RUNNING_BITS"],
 [C::PLL_CS, "PLL_CS_OFFSET"], [C::PLL_PWR, "PLL_PWR_OFFSET"], [C::PLL_FBDIV_INT, "PLL_FBDIV_INT_OFFSET"],
 [C::PLL_PRIM, "PLL_PRIM_OFFSET"], [C::PLL_CS_BYPASS, "PLL_CS_BYPASS_BITS"], [C::PLL_PWR_PD, "PLL_PWR_PD_BITS"],
 [C::PLL_PWR_POSTDIVPD, "PLL_PWR_POSTDIVPD_BITS"], [C::PLL_PWR_VCOPD, "PLL_PWR_VCOPD_BITS"],
 [C::UART_FR, "UART_UARTFR_OFFSET"], [C::UART_CR, "UART_UARTCR_OFFSET"], [C::UART_FR_BUSY, "UART_UARTFR_BUSY_BITS"]].each { |v, c| add.(v, c, "Clocks #{c}") }

D = Pico::DMA
[[D::CH_STRIDE, "(DMA_CH1_READ_ADDR_OFFSET - DMA_CH0_READ_ADDR_OFFSET)"], [D::READ_ADDR, "DMA_CH0_READ_ADDR_OFFSET"],
 [D::WRITE_ADDR, "DMA_CH0_WRITE_ADDR_OFFSET"], [D::TRANS_COUNT, "DMA_CH0_TRANS_COUNT_OFFSET"],
 [D::CTRL_TRIG, "DMA_CH0_CTRL_TRIG_OFFSET"], [D::AL1_CTRL, "DMA_CH0_AL1_CTRL_OFFSET"],
 [D::AL1_TRANS_COUNT_TRIG, "DMA_CH0_AL1_TRANS_COUNT_TRIG_OFFSET"], [D::AL2_WRITE_ADDR_TRIG, "DMA_CH0_AL2_WRITE_ADDR_TRIG_OFFSET"],
 [D::AL3_READ_ADDR_TRIG, "DMA_CH0_AL3_READ_ADDR_TRIG_OFFSET"], [D::INTR, "DMA_INTR_OFFSET"], [D::INTE0, "DMA_INTE0_OFFSET"],
 [D::INTS0, "DMA_INTS0_OFFSET"], [D::IRQN_STRIDE, "(DMA_INTE1_OFFSET - DMA_INTE0_OFFSET)"]].each { |v, c| add.(v, c, "DMA #{c}") }
dc = chip.dma_ctrl
{ en: "EN", high_priority: "HIGH_PRIORITY", data_size: "DATA_SIZE", incr_read: "INCR_READ", incr_write: "INCR_WRITE",
  ring_size: "RING_SIZE", ring_sel: "RING_SEL", chain_to: "CHAIN_TO", treq_sel: "TREQ_SEL", irq_quiet: "IRQ_QUIET",
  bswap: "BSWAP", sniff_en: "SNIFF_EN", busy: "BUSY" }.each { |k, c| add.(dc[k], "DMA_CH0_CTRL_TRIG_#{c}_LSB", "dma_ctrl[:#{k}]") }

P = Pico::PWM
[[P::CSR, "PWM_CH0_CSR_OFFSET"], [P::DIV, "PWM_CH0_DIV_OFFSET"], [P::CTR, "PWM_CH0_CTR_OFFSET"], [P::CC, "PWM_CH0_CC_OFFSET"],
 [P::TOP, "PWM_CH0_TOP_OFFSET"], [P::STRIDE, "(PWM_CH1_CSR_OFFSET - PWM_CH0_CSR_OFFSET)"],
 [P::CSR_EN, "PWM_CH0_CSR_EN_BITS"], [P::CSR_PH_CORRECT, "PWM_CH0_CSR_PH_CORRECT_BITS"], [P::CSR_A_INV, "PWM_CH0_CSR_A_INV_BITS"],
 [P::CSR_B_INV, "PWM_CH0_CSR_B_INV_BITS"], [P::CSR_DIVMODE, "PWM_CH0_CSR_DIVMODE_BITS"]].each { |v, c| add.(v, c, "PWM #{c}") }
add.(chip.pwm_en, "PWM_EN_OFFSET", "pwm_en")
add.(chip.pwm_intr, "PWM_INTR_OFFSET", "pwm_intr")
add.(chip.pwm_inte, chip.rp2040? ? "PWM_INTE_OFFSET" : "PWM_IRQ0_INTE_OFFSET", "pwm_inte")

A = Pico::ADC
[[A::CS, "ADC_CS_OFFSET"], [A::RESULT, "ADC_RESULT_OFFSET"], [A::CS_EN, "ADC_CS_EN_BITS"], [A::CS_TS_EN, "ADC_CS_TS_EN_BITS"],
 [A::CS_START_ONCE, "ADC_CS_START_ONCE_BITS"], [A::CS_READY, "ADC_CS_READY_BITS"], [A::CS_ERR, "ADC_CS_ERR_BITS"]].each { |v, c| add.(v, c, "ADC #{c}") }

U = Pico::UART
[[U::DR, "UART_UARTDR_OFFSET"], [U::FR, "UART_UARTFR_OFFSET"], [U::IBRD, "UART_UARTIBRD_OFFSET"], [U::FBRD, "UART_UARTFBRD_OFFSET"],
 [U::LCR_H, "UART_UARTLCR_H_OFFSET"], [U::CR, "UART_UARTCR_OFFSET"], [U::DMACR, "UART_UARTDMACR_OFFSET"],
 [U::FR_BUSY, "UART_UARTFR_BUSY_BITS"], [U::FR_RXFE, "UART_UARTFR_RXFE_BITS"], [U::FR_TXFF, "UART_UARTFR_TXFF_BITS"],
 [U::CR_UARTEN, "UART_UARTCR_UARTEN_BITS"], [U::CR_LBE, "UART_UARTCR_LBE_BITS"], [U::CR_TXE, "UART_UARTCR_TXE_BITS"],
 [U::CR_RXE, "UART_UARTCR_RXE_BITS"], [U::LCR_H_PEN, "UART_UARTLCR_H_PEN_BITS"], [U::LCR_H_EPS, "UART_UARTLCR_H_EPS_BITS"],
 [U::LCR_H_STP2, "UART_UARTLCR_H_STP2_BITS"], [U::LCR_H_FEN, "UART_UARTLCR_H_FEN_BITS"], [U::LCR_H_WLEN, "UART_UARTLCR_H_WLEN_BITS"]].each { |v, c| add.(v, c, "UART #{c}") }

S = Pico::SPI
[[S::SSPCR0, "SPI_SSPCR0_OFFSET"], [S::SSPCR1, "SPI_SSPCR1_OFFSET"], [S::SSPDR, "SPI_SSPDR_OFFSET"], [S::SSPSR, "SPI_SSPSR_OFFSET"],
 [S::SSPCPSR, "SPI_SSPCPSR_OFFSET"], [S::SSPDMACR, "SPI_SSPDMACR_OFFSET"], [S::CR1_LBM, "SPI_SSPCR1_LBM_BITS"],
 [S::CR1_SSE, "SPI_SSPCR1_SSE_BITS"], [S::CR1_MS, "SPI_SSPCR1_MS_BITS"], [S::SR_TFE, "SPI_SSPSR_TFE_BITS"],
 [S::SR_TNF, "SPI_SSPSR_TNF_BITS"], [S::SR_RNE, "SPI_SSPSR_RNE_BITS"], [S::SR_BSY, "SPI_SSPSR_BSY_BITS"]].each { |v, c| add.(v, c, "SPI #{c}") }

I = Pico::I2C
[[I::IC_CON, "I2C_IC_CON_OFFSET"], [I::IC_TAR, "I2C_IC_TAR_OFFSET"], [I::IC_SAR, "I2C_IC_SAR_OFFSET"],
 [I::IC_DATA_CMD, "I2C_IC_DATA_CMD_OFFSET"], [I::IC_FS_SCL_HCNT, "I2C_IC_FS_SCL_HCNT_OFFSET"],
 [I::IC_FS_SCL_LCNT, "I2C_IC_FS_SCL_LCNT_OFFSET"], [I::IC_RAW_INTR_STAT, "I2C_IC_RAW_INTR_STAT_OFFSET"],
 [I::IC_RX_TL, "I2C_IC_RX_TL_OFFSET"], [I::IC_TX_TL, "I2C_IC_TX_TL_OFFSET"], [I::IC_CLR_TX_ABRT, "I2C_IC_CLR_TX_ABRT_OFFSET"],
 [I::IC_CLR_STOP_DET, "I2C_IC_CLR_STOP_DET_OFFSET"], [I::IC_ENABLE, "I2C_IC_ENABLE_OFFSET"], [I::IC_TXFLR, "I2C_IC_TXFLR_OFFSET"],
 [I::IC_RXFLR, "I2C_IC_RXFLR_OFFSET"], [I::IC_SDA_HOLD, "I2C_IC_SDA_HOLD_OFFSET"], [I::IC_TX_ABRT_SOURCE, "I2C_IC_TX_ABRT_SOURCE_OFFSET"],
 [I::IC_DMA_CR, "I2C_IC_DMA_CR_OFFSET"], [I::IC_FS_SPKLEN, "I2C_IC_FS_SPKLEN_OFFSET"],
 [I::CON_MASTER_MODE, "I2C_IC_CON_MASTER_MODE_BITS"], [I::CON_SPEED, "I2C_IC_CON_SPEED_BITS"],
 [I::CON_SPEED_FAST, "(I2C_IC_CON_SPEED_VALUE_FAST << I2C_IC_CON_SPEED_LSB)"], [I::CON_RESTART_EN, "I2C_IC_CON_IC_RESTART_EN_BITS"],
 [I::CON_SLAVE_DISABLE, "I2C_IC_CON_IC_SLAVE_DISABLE_BITS"], [I::CON_TX_EMPTY_CTRL, "I2C_IC_CON_TX_EMPTY_CTRL_BITS"],
 [I::CON_RX_FIFO_FULL_HLD_CTRL, "I2C_IC_CON_RX_FIFO_FULL_HLD_CTRL_BITS"], [I::CMD_READ, "I2C_IC_DATA_CMD_CMD_BITS"],
 [I::CMD_STOP, "I2C_IC_DATA_CMD_STOP_BITS"], [I::CMD_RESTART, "I2C_IC_DATA_CMD_RESTART_BITS"],
 [I::RAW_TX_EMPTY, "I2C_IC_RAW_INTR_STAT_TX_EMPTY_BITS"], [I::RAW_TX_ABRT, "I2C_IC_RAW_INTR_STAT_TX_ABRT_BITS"],
 [I::RAW_STOP_DET, "I2C_IC_RAW_INTR_STAT_STOP_DET_BITS"], [I::ABRT_7B_ADDR_NOACK, "I2C_IC_TX_ABRT_SOURCE_ABRT_7B_ADDR_NOACK_BITS"],
 [I::ABRT_TXDATA_NOACK, "I2C_IC_TX_ABRT_SOURCE_ABRT_TXDATA_NOACK_BITS"]].each { |v, c| add.(v, c, "I2C #{c}") }

R = Pico::PIO::Regs
[[R::CTRL, "PIO_CTRL_OFFSET"], [R::FSTAT, "PIO_FSTAT_OFFSET"], [R::FDEBUG, "PIO_FDEBUG_OFFSET"], [R::FLEVEL, "PIO_FLEVEL_OFFSET"],
 [R::TXF0, "PIO_TXF0_OFFSET"], [R::RXF0, "PIO_RXF0_OFFSET"], [R::IRQ, "PIO_IRQ_OFFSET"], [R::IRQ_FORCE, "PIO_IRQ_FORCE_OFFSET"],
 [R::INSTR_MEM0, "PIO_INSTR_MEM0_OFFSET"], [R::SM0, "PIO_SM0_CLKDIV_OFFSET"], [R::SM_STRIDE, "(PIO_SM1_CLKDIV_OFFSET - PIO_SM0_CLKDIV_OFFSET)"],
 [R::SM_EXECCTRL, "(PIO_SM0_EXECCTRL_OFFSET - PIO_SM0_CLKDIV_OFFSET)"], [R::SM_SHIFTCTRL, "(PIO_SM0_SHIFTCTRL_OFFSET - PIO_SM0_CLKDIV_OFFSET)"],
 [R::SM_ADDR, "(PIO_SM0_ADDR_OFFSET - PIO_SM0_CLKDIV_OFFSET)"], [R::SM_INSTR, "(PIO_SM0_INSTR_OFFSET - PIO_SM0_CLKDIV_OFFSET)"],
 [R::SM_PINCTRL, "(PIO_SM0_PINCTRL_OFFSET - PIO_SM0_CLKDIV_OFFSET)"], [R::EXECCTRL_OUT_STICKY, "PIO_SM0_EXECCTRL_OUT_STICKY_BITS"],
 [R::SHIFTCTRL_FJOIN_RX, "PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS"], [R::SHIFTCTRL_AUTOPULL, "PIO_SM0_SHIFTCTRL_AUTOPULL_BITS"]].each { |v, c| add.(v, c, "PIO #{c}") }
add.(chip.pio_intr, "PIO_INTR_OFFSET", "pio_intr")
add.(chip.pio_irq0_inte, "PIO_IRQ0_INTE_OFFSET", "pio_irq0_inte")
add.(chip.pio_irq0_inte + 4, "PIO_IRQ0_INTF_OFFSET", "pio_irq0_inte + 4 (INTF)")
add.(chip.pio_irq0_inte + 8, "PIO_IRQ0_INTS_OFFSET", "pio_irq0_inte + 8 (INTS)")
add.(R::IRQN_STRIDE, "(PIO_IRQ1_INTE_OFFSET - PIO_IRQ0_INTE_OFFSET)", "PIO IRQN_STRIDE")

# per-chip fields
add.(chip.gpio_outover_lsb, "IO_BANK0_GPIO0_CTRL_OUTOVER_LSB", "gpio_outover_lsb")
add.(chip.gpio_oeover_lsb, "IO_BANK0_GPIO0_CTRL_OEOVER_LSB", "gpio_oeover_lsb")
add.(chip.timer_intr, "TIMER_INTR_OFFSET", "timer_intr")
add.(chip.timer_inte, "TIMER_INTE_OFFSET", "timer_inte")
add.(chip.clk_usb_ctrl, "CLOCKS_CLK_USB_CTRL_OFFSET", "clk_usb_ctrl")
add.(chip.clk_usb_ctrl + 4, "CLOCKS_CLK_USB_DIV_OFFSET", "clk_usb_ctrl + 4 (DIV)")
add.(chip.clk_adc_ctrl, "CLOCKS_CLK_ADC_CTRL_OFFSET", "clk_adc_ctrl")
add.(chip.clk_adc_ctrl + 4, "CLOCKS_CLK_ADC_DIV_OFFSET", "clk_adc_ctrl + 4 (DIV)")
{ C::FC0_REF_KHZ => "REF_KHZ", C::FC0_MIN_KHZ => "MIN_KHZ", C::FC0_MAX_KHZ => "MAX_KHZ", C::FC0_INTERVAL => "INTERVAL",
  C::FC0_SRC => "SRC", C::FC0_STATUS => "STATUS", C::FC0_RESULT => "RESULT" }.each do |off, n|
  add.(chip.fc0_ref_khz + off - C::FC0_REF_KHZ, "CLOCKS_FC0_#{n}_OFFSET", "Clocks#fc0(FC0_#{n})")
end
add.(chip.dma_timer0, "DMA_TIMER0_OFFSET", "dma_timer0")
add.(chip.dma_multi_chan_trigger, "DMA_MULTI_CHAN_TRIGGER_OFFSET", "dma_multi_chan_trigger")
add.(chip.dma_sniff_ctrl, "DMA_SNIFF_CTRL_OFFSET", "dma_sniff_ctrl")
add.(chip.dma_sniff_ctrl + 4, "DMA_SNIFF_DATA_OFFSET", "dma_sniff_ctrl + 4 (SNIFF_DATA)")
add.(chip.dma_chan_abort, "DMA_CHAN_ABORT_OFFSET", "dma_chan_abort")
add.(chip.adc_ainsel, "ADC_CS_AINSEL_BITS", "adc_ainsel")
add.(chip.adc_rrobin, "ADC_CS_RROBIN_BITS", "adc_rrobin")
# clock source numbers written or decoded by Pico::Clocks
add.(2, "CLOCKS_CLK_REF_CTRL_SRC_VALUE_XOSC_CLKSRC", "clk_ref SRC xosc")
add.(1, "CLOCKS_CLK_REF_CTRL_SRC_VALUE_CLKSRC_CLK_REF_AUX", "clk_ref SRC aux")
add.(0, "CLOCKS_CLK_REF_CTRL_AUXSRC_VALUE_CLKSRC_PLL_USB", "clk_ref AUXSRC pll_usb")
add.(1, "CLOCKS_CLK_SYS_CTRL_SRC_VALUE_CLKSRC_CLK_SYS_AUX", "clk_sys SRC aux")
%w[CLKSRC_PLL_SYS CLKSRC_PLL_USB ROSC_CLKSRC XOSC_CLKSRC].each_with_index { |n, i| add.(i, "CLOCKS_CLK_SYS_CTRL_AUXSRC_VALUE_#{n}", "clk_sys AUXSRC #{n}") }
%w[CLK_SYS CLKSRC_PLL_SYS CLKSRC_PLL_USB ROSC_CLKSRC_PH XOSC_CLKSRC].each_with_index { |n, i| add.(i, "CLOCKS_CLK_PERI_CTRL_AUXSRC_VALUE_#{n}", "clk_peri AUXSRC #{n}") }
%w[CLKSRC_PLL_USB CLKSRC_PLL_SYS ROSC_CLKSRC_PH XOSC_CLKSRC].each_with_index do |n, i|
  add.(i, "CLOCKS_CLK_USB_CTRL_AUXSRC_VALUE_#{n}", "clk_usb AUXSRC #{n}")
  add.(i, "CLOCKS_CLK_ADC_CTRL_AUXSRC_VALUE_#{n}", "clk_adc AUXSRC #{n}")
end
{ 1 => "PLL_SYS_CLKSRC_PRIMARY", 2 => "PLL_USB_CLKSRC_PRIMARY", 3 => "ROSC_CLKSRC", 5 => "XOSC_CLKSRC", 8 => "CLK_REF",
  9 => "CLK_SYS", 10 => "CLK_PERI", 11 => "CLK_USB", 12 => "CLK_ADC" }.each { |v, n| add.(v, "CLOCKS_FC0_SRC_VALUE_#{n}", "FC0 SRC #{n}") }
add.(13, "CLOCKS_FC0_SRC_VALUE_CLK_RTC", "FC0 SRC CLK_RTC") if chip.rp2040?

# bit positions Pico::PIO::StateMachine and Block write by number
{ "CTRL_SM_RESTART" => 4, "CTRL_CLKDIV_RESTART" => 8, "FSTAT_RXFULL" => 0, "FSTAT_RXEMPTY" => 8, "FSTAT_TXFULL" => 16,
  "FSTAT_TXEMPTY" => 24, "FLEVEL_TX0" => 0, "FLEVEL_RX0" => 4, "FLEVEL_TX1" => 8,
  "SM0_EXECCTRL_SIDE_EN" => 30, "SM0_EXECCTRL_SIDE_PINDIR" => 29, "SM0_EXECCTRL_JMP_PIN" => 24,
  "SM0_EXECCTRL_WRAP_TOP" => 12, "SM0_EXECCTRL_WRAP_BOTTOM" => 7, "SM0_SHIFTCTRL_FJOIN_RX" => 31,
  "SM0_SHIFTCTRL_FJOIN_TX" => 30, "SM0_SHIFTCTRL_PULL_THRESH" => 25, "SM0_SHIFTCTRL_PUSH_THRESH" => 20,
  "SM0_SHIFTCTRL_OUT_SHIFTDIR" => 19, "SM0_SHIFTCTRL_IN_SHIFTDIR" => 18, "SM0_SHIFTCTRL_AUTOPULL" => 17,
  "SM0_SHIFTCTRL_AUTOPUSH" => 16, "SM0_PINCTRL_SIDESET_COUNT" => 29, "SM0_PINCTRL_SET_COUNT" => 26,
  "SM0_PINCTRL_OUT_COUNT" => 20, "SM0_PINCTRL_IN_BASE" => 15, "SM0_PINCTRL_SIDESET_BASE" => 10,
  "SM0_PINCTRL_SET_BASE" => 5, "SM0_PINCTRL_OUT_BASE" => 0, "SM0_CLKDIV_INT" => 16, "SM0_CLKDIV_FRAC" => 8 }.each do |n, v|
  add.(v, "PIO_#{n}_LSB", "PIO #{n} bit")
end
unless chip.rp2040?
  add.(14, "PIO_SM0_SHIFTCTRL_FJOIN_RX_GET_LSB", "PIO FJOIN_RX_GET bit")
  add.(15, "PIO_SM0_SHIFTCTRL_FJOIN_RX_PUT_LSB", "PIO FJOIN_RX_PUT bit")
end

# ---- USB device controller
add.(chip.usbctrl_dpram_base, "USBCTRL_DPRAM_BASE", "usbctrl_dpram_base")
add.(chip.usbctrl_regs_base, "USBCTRL_REGS_BASE", "usbctrl_regs_base")
UD = Pico::USBDevice
[[UD::ADDR_ENDP, "USB_ADDR_ENDP_OFFSET"], [UD::MAIN_CTRL, "USB_MAIN_CTRL_OFFSET"], [UD::SIE_CTRL, "USB_SIE_CTRL_OFFSET"],
 [UD::SIE_STATUS, "USB_SIE_STATUS_OFFSET"], [UD::BUFF_STATUS, "USB_BUFF_STATUS_OFFSET"], [UD::EP_STALL_ARM, "USB_EP_STALL_ARM_OFFSET"],
 [UD::USB_MUXING, "USB_USB_MUXING_OFFSET"], [UD::USB_PWR, "USB_USB_PWR_OFFSET"], [UD::MAIN_CTRL_CONTROLLER_EN, "USB_MAIN_CTRL_CONTROLLER_EN_BITS"],
 [UD::SIE_CTRL_PULLUP_EN_HI << 16, "USB_SIE_CTRL_PULLUP_EN_BITS"], [UD::SIE_CTRL_EP0_INT_1BUF_HI << 16, "USB_SIE_CTRL_EP0_INT_1BUF_BITS"],
 [UD::SIE_STATUS_VBUS_DETECTED, "USB_SIE_STATUS_VBUS_DETECTED_BITS"], [UD::SIE_STATUS_SUSPENDED, "USB_SIE_STATUS_SUSPENDED_BITS"],
 [UD::SIE_STATUS_CONNECTED, "USB_SIE_STATUS_CONNECTED_BITS"], [UD::SIE_STATUS_SETUP_REC, "USB_SIE_STATUS_SETUP_REC_BITS"],
 [UD::SIE_STATUS_BUS_RESET, "USB_SIE_STATUS_BUS_RESET_BITS"], [UD::MUXING_TO_PHY, "USB_USB_MUXING_TO_PHY_BITS"],
 [UD::MUXING_SOFTCON, "USB_USB_MUXING_SOFTCON_BITS"], [UD::PWR_VBUS_DETECT, "USB_USB_PWR_VBUS_DETECT_BITS"],
 [UD::PWR_VBUS_DETECT_OVERRIDE_EN, "USB_USB_PWR_VBUS_DETECT_OVERRIDE_EN_BITS"], [UD::STALL_ARM_EP0_IN, "USB_EP_STALL_ARM_EP0_IN_BITS"],
 [UD::STALL_ARM_EP0_OUT, "USB_EP_STALL_ARM_EP0_OUT_BITS"], [UD::INTE, "USB_INTE_OFFSET"], [UD::INTF, "USB_INTF_OFFSET"],
 [UD::INTS, "USB_INTS_OFFSET"], [UD::INT_BUFF_STATUS, "USB_INTS_BUFF_STATUS_BITS"], [UD::INT_BUS_RESET, "USB_INTS_BUS_RESET_BITS"],
 [UD::INT_DEV_SUSPEND, "USB_INTS_DEV_SUSPEND_BITS"], [UD::INT_DEV_RESUME_FROM_HOST, "USB_INTS_DEV_RESUME_FROM_HOST_BITS"],
 [UD::INT_SETUP_REQ, "USB_INTS_SETUP_REQ_BITS"], [UD::SIE_CTRL_RESUME, "USB_SIE_CTRL_RESUME_BITS"],
 [UD::SIE_STATUS_RESUME, "USB_SIE_STATUS_RESUME_BITS"],
 # hardware/structs/usb_dpram.h (copied below: the header pulls in the whole SDK)
 [UD::BUF_FULL, "USB_BUF_CTRL_FULL"], [UD::BUF_DATA1, "USB_BUF_CTRL_DATA1_PID"], [UD::BUF_STALL, "USB_BUF_CTRL_STALL"],
 [UD::BUF_AVAIL, "USB_BUF_CTRL_AVAIL"], [UD::BUF_LEN, "USB_BUF_CTRL_LEN_MASK"], [UD::EP_CTRL_ENABLE_HI << 16, "EP_CTRL_ENABLE_BITS"],
 [UD::EP_CTRL_PER_BUFFER_HI << 16, "EP_CTRL_INTERRUPT_PER_BUFFER"], [UD::EP_CTRL_TYPE_LSB_HI + 16, "EP_CTRL_BUFFER_TYPE_LSB"],
 [UD::DPRAM_SIZE, "USB_DPRAM_SIZE"]].each { |v, c| add.(v, c, "USB #{c}") }
add.(UD::MAIN_CTRL_PHY_ISO, "USB_MAIN_CTRL_PHY_ISO_BITS", "USB MAIN_CTRL_PHY_ISO") unless chip.rp2040?

add.(chip.pio_status_sel_lsb, "PIO_SM0_EXECCTRL_STATUS_SEL_LSB", "pio_status_sel_lsb")
add.(chip.pio_status_n_max, "PIO_SM0_EXECCTRL_STATUS_N_BITS", "pio_status_n_max")
add.(1, "PIO_SM0_EXECCTRL_STATUS_SEL_VALUE_RXLEVEL", "mov_status :rxfifo")
add.(2, "PIO_SM0_EXECCTRL_STATUS_SEL_VALUE_IRQ", "mov_status :irq") unless chip.rp2040?

puts "// Generated by: ruby tools/regs_check.rb #{chip_name} (#{checks.size} values)"
puts "#include \"hardware/platform_defs.h\""
puts "#include \"hardware/regs/addressmap.h\""
%w[resets io_bank0 pads_bank0 sio clocks xosc pll watchdog timer uart pio spi i2c pwm adc dma dreq intctrl].each { |h| puts "#include \"hardware/regs/#{h}.h\"" }
puts "#include \"hardware/regs/ticks.h\"" unless chip.rp2040?
puts "#include \"hardware/regs/dreq.h\""
# GPIO_FUNC_* (pico-sdk keeps them in hardware/structs/io_bank0.h, which pulls in the whole SDK): copied here
if chip.rp2040?
  puts "enum { GPIO_FUNC_XIP = 0, GPIO_FUNC_SPI = 1, GPIO_FUNC_UART = 2, GPIO_FUNC_I2C = 3, GPIO_FUNC_PWM = 4, GPIO_FUNC_SIO = 5," \
       " GPIO_FUNC_PIO0 = 6, GPIO_FUNC_PIO1 = 7, GPIO_FUNC_GPCK = 8, GPIO_FUNC_USB = 9, GPIO_FUNC_NULL = 0x1f };"
else
  puts "enum { GPIO_FUNC_HSTX = 0, GPIO_FUNC_SPI = 1, GPIO_FUNC_UART = 2, GPIO_FUNC_I2C = 3, GPIO_FUNC_PWM = 4, GPIO_FUNC_SIO = 5," \
       " GPIO_FUNC_PIO0 = 6, GPIO_FUNC_PIO1 = 7, GPIO_FUNC_PIO2 = 8, GPIO_FUNC_GPCK = 9, GPIO_FUNC_XIP_CS1 = 9," \
       " GPIO_FUNC_CORESIGHT_TRACE = 9, GPIO_FUNC_USB = 10, GPIO_FUNC_UART_AUX = 11, GPIO_FUNC_NULL = 0x1f };"
end
puts "#include \"hardware/regs/usb.h\""
puts "#define USB_BUF_CTRL_FULL 0x00008000u\n#define USB_BUF_CTRL_DATA1_PID 0x00002000u\n#define USB_BUF_CTRL_STALL 0x00000800u"
puts "#define USB_BUF_CTRL_AVAIL 0x00000400u\n#define USB_BUF_CTRL_LEN_MASK 0x000003FFu\n#define EP_CTRL_ENABLE_BITS (1u << 31u)"
puts "#define EP_CTRL_INTERRUPT_PER_BUFFER (1u << 29)\n#define EP_CTRL_BUFFER_TYPE_LSB 26u\n#define USB_DPRAM_SIZE 4096u"
checks.each do |v, c, what|
  puts "_Static_assert((uint32_t)(#{c}) == #{format('0x%08xu', v)}, \"#{chip.name} #{what}: spinel-pico has #{format('0x%x', v)}\");"
end
