# Third-party code and licences

The project's own licence is Apache-2.0 WITH LLVM-exception: see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). It
covers every file except those listed here, which keep the licence named.

| files | licence | licence text | note |
| --- | --- | --- | --- |
| `port/chip/rp2040/boot2/generic_03h.S`, `port/chip/rp2040/LICENSE.pico-sdk.TXT` | BSD-3-Clause | `port/chip/rp2040/LICENSE.pico-sdk.TXT` | the RP2040's second-stage boot: pico-sdk 2.3.1's `boot2_generic_03h.S` and `exit_from_boot2.S` with the SDK's macros replaced by their values. An image built for the RP2040 contains it |

Nothing else in this repository is third-party code.
