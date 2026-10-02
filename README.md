# uart_dma_check

Hardware check for the STM32 async UART DMA changes (branch `st_uart_dma_reset_fix`). It drives the
`dut` UART and prints one line per case: PASS/FAIL, TX_DONE / TX_ABORTED events with their lengths,
TX time, and whether a PM lock is still held.

Cases, run three times: plain TX, RX enabled during a TX, abort mid-TX, abort right after starting,
RX enabled during a TX then abort, TX timeout (driver abort). The dut register state is printed
around the RX enable and the abort.

## Boards

The `dut` UART and its DMA come from `boards/<board>.overlay`. The device PM variant adds `pm.conf`
and, if present, `pm/<board>.overlay`. The console stays on the ST-LINK VCP (`/dev/ttyACM0`).

| Board | dut | DMA | Loopback pins (optional) | PM overlay |
|---|---|---|---|---|
| `nucleo_u575zi_q` | USART2 | GPDMA1 TX ch 2 / RX ch 3 | PD5 (TX) - PD6 (RX) | STOP0/STOP1 only |
| `nucleo_f429zi` | USART6 | DMA2 TX stream 7 / RX stream 2, FIFO on | PG14 (TX) - PG9 (RX) | none |
| `nucleo_h563zi` | LPUART1 | GPDMA1 TX ch 2 / RX ch 3 | D1 = PB6 (TX) - D0 = PB7 (RX) | none (single `stop` state) |
| `nucleo_h745zi_q/stm32h745xx/m7` | USART2 | DMA1 via DMAMUX1, TX req 44 / RX req 43 | PD5 (TX) - PD6 (RX) | no PM on H7; `.conf` sets `CONFIG_DCACHE=n` |
| `nucleo_c5a3zg` | USART2 | LPDMA1 TX ch 0 / RX ch 1 (req 15/14) | PD5 (TX) - PD6 (RX) | none (STOP0/STOP1); HAL2, CubeProgrammer only |

The U575 and H563 are affected by the DMAT erratum (`CONFIG_UART_STM32U5_ERRATA_DMAT_AFFECTED`, see
ES0499 and ES0565), so the UE-toggle workaround and the RX-enable-during-TX case apply to both. The
H563 overlay builds with and without device PM but has not been run on hardware yet.

The cases pass with or without the loopback jumper. The F429 setup matches
`tests/drivers/uart/uart_async_api/boards/nucleo_f429zi.overlay`, so the same jumper also serves
the in-tree test.

To add a board, add `boards/<board>.overlay` with a `dut` node and its case in `flash.sh` (pyOCD
target name).

## Build, flash and run

`flash.sh` builds (with `-b`), flashes, resets and captures the run. `./flash.sh -h` lists all
options. Build directories are `build_<board>` (no PM) and `build_<board>_pm` (device PM) in this
folder.

    ./flash.sh -b -P                  # pristine build, flash, capture (U575, no PM)
    ./flash.sh -b -P -v pm            # same with device PM
    ./flash.sh -B nucleo_f429zi -b -P # same on the F429
    ./flash.sh                        # flash the existing build again and capture
    ./flash.sh -r                     # reset only and capture the run again
    ./flash.sh -d <dir> -c 0          # flash another build dir (e.g. a base build), no capture
    ./flash.sh -e -m UR               # full chip erase, connect under reset
    ./flash.sh -t openocd             # flash with west flash -r openocd (also: west, pyocd)
    ./flash.sh -n -b -v pm            # print the commands only

Plain `CONFIG_PM=y` hangs after the boot banner on the U575, hence the device PM variant.

Notes:

- The default tool, `cubeprog`, runs STM32_Programmer_CLI on the hex and never rebuilds.
  Plain `west flash` rebuilds the build directory first: when comparing against another commit,
  this turns the "base" image into the current checkout. The `west`, `openocd` and `pyocd` tools
  pass `--no-rebuild`.
- After a PM image on the U575, only connect mode `POWERDOWN` (the default) reaches the target.
- `pyocd` needs the target pack once: `pyocd pack install stm32u575zitx` (or `stm32f429zitx`).
- To compare against `main`, build it into another directory while the zephyr tree is on that
  commit, switch back, then flash with `-d`: `./flash.sh -d build_base`. The script prints the
  image's `BUILD_VERSION` before flashing.
- Close any serial monitor on the port first (for example in VS Code); two readers on the same
  port make `run.py` fail with "device reports readiness to read but returned no data".

The run ends with `=== uart dma check: N failures, end pm_lock=X ===`. With PM, `end pm_lock=1` is
expected: it is read right after a printk while the console still holds its own TX lock. The
per-case values are read after a 40 ms wait.

## Expected results

U575, measured: on `main` (5075ddf1460) RX enable during TX and every abort case FAIL (early or
extra TX_DONE; with device PM the lock stays held after the first RX-enable case). On the branch
all 27 lines PASS, without PM and with device PM.

F429, measured: the U5/H5 UE-toggle workaround is not built for F4, so RX enable during TX
passes on `main` too. Every abort case FAILs on `main` (an extra `TX_DONE len=0` about 1 ms after
`TX_ABORTED`) and PASSes on the branch, without PM and with device PM. The abort lengths are the
same on both (89 / 1 / 48 / 60) and already match the data sent: the F4 DMA driver is not changed
by the branch, and on F4 the extra TX_DONE arrives after TX_ABORTED, so it does not zero the count.
With device PM the lock is free after every case on both; on `main` it is the extra TX_DONE that
releases it.
