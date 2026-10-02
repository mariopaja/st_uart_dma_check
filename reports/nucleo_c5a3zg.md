# NUCLEO-C5A3ZG: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-10-02 |
| Board | NUCLEO-C5A3ZG (STM32C5A3ZG, device ID 0x45A), ST-LINK V3 |
| Branch | `st_uart_dma_reset_fix` at `67b70ed6bef` (PR #120833) |
| Baseline | `main` at `5075ddf1460` |
| DMA | LPDMA1 (`st,stm32u5-dma` driver, 4 channels, no FIFO) |
| HAL | HAL2 (`CONFIG_STM32_HAL2=y`): the DMA FIFO count code is compiled out |
| DMAT erratum | Not affected: the UE-toggle workaround and the RX-enable change are compiled out |
| PM | Supported (`HAS_PM`, STOP0/STOP1); device PM builds use `uart_dma_check/pm.conf`, no PM overlay |

Every image was built from the commit named in its `BUILD_VERSION` and flashed with
STM32_Programmer_CLI without a rebuild. The test and sample overlays for this board are in the
tree (added by ST).

On this SoC only the TC-disable-on-abort and TX-error commits change behavior.

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | **12 failures** (4 abort cases x 3 rounds) | 0 failures |
| Check app, device PM | **12 failures** (same cases), PM lock free | 0 failures, PM lock free |
| Sample `async_api`, `CONFIG_LOG=n`, no PM | 21 packets over 9 loops, all intact | 29 packets over 10 loops, all intact |
| Sample `async_api`, `CONFIG_LOG=n`, device PM | 26 packets over 10 loops, all intact | 25 packets over 9 loops, all intact |
| `tests/drivers/uart/uart_async_api`, no PM (PD5-PD6 loopback) | 10/10 | 10/10 |
| `tests/drivers/uart/uart_async_api`, device PM | 6/11 (5 RX cases fail, PM suite passes) | 6/11 (same cases) |

## Check app (`uart_dma_check`)

`dut` = USART2 (PD5 TX / PD6 RX) on LPDMA1, TX ch 0 / request 15, RX ch 1 / request 14
(`uart_dma_check/boards/nucleo_c5a3zg.overlay`). No loopback is needed.

The app runs its case list three times; each round prints 9 lines, so a run has 27 PASS/FAIL
lines. A line passes when:

| Case | Pass condition | Checks PM lock |
|---|---|---|
| plain tx (start and end of each round) | one TX_DONE with all 200 bytes, no TX_ABORTED, TX time at least 90 % of 17.4 ms | yes |
| rx_enable during tx | `uart_rx_enable()` 2 ms into the TX; one TX_DONE with all 200 bytes, not early | no |
| next tx after it (twice per round) | the next `uart_tx()` is accepted and completes with all 200 bytes | no |
| abort mid tx / abort immediately / rx_enable, then abort / tx timeout | exactly one TX_ABORTED and no TX_DONE | yes |

| Case (first round) | `main`, no PM and device PM | PR, no PM and device PM |
|---|---|---|
| plain tx | PASS | PASS |
| rx_enable during tx | PASS (no UE toggle on C5) | PASS |
| next tx after it | PASS | PASS |
| abort mid tx | **FAIL**: TX_DONE `len=89`, then TX_ABORTED `len=0` | PASS, TX_ABORTED `len=89` |
| abort immediately | **FAIL**: TX_DONE `len=2`, then TX_ABORTED `len=0` | PASS, TX_ABORTED `len=2` |
| rx_enable, then abort | **FAIL**: TX_DONE `len=48`, then TX_ABORTED `len=0` | PASS, TX_ABORTED `len=48` |
| next tx after it | PASS | PASS |
| tx timeout (driver abort) | **FAIL**: TX_DONE `len=60` (`63` with PM), then TX_ABORTED `len=0` | PASS, TX_ABORTED `len=60` (`63` with PM) |
| plain tx | PASS | PASS |

### How the failure counts add up

| Line (per run) | Lines | `main` no PM | `main` device PM | PR |
|---|---|---|---|---|
| abort mid tx, abort immediately, rx_enable then abort, tx timeout | 4 x 3 | 12 FAIL | 12 FAIL | 0 |
| rx_enable during tx | 3 | 0 | 0 | 0 |
| plain tx, next tx after it | 12 | 0 | 0 | 0 |
| **Total** | **27** | **12** | **12** | **0** |

Unlike on F4/H7, the extra TX_DONE on `main` arrives before TX_ABORTED and takes the byte count, so
TX_ABORTED reports 0 bytes (the same symptom as on U5/H5). With the PR the TX_ABORTED lengths
match the other boards. With device PM the lock stays free on both builds: on `main` it is the
extra TX_DONE that releases it, and there is no UE toggle to release it twice. `end pm_lock=1` on
the last line of the PM runs is the console's own TX lock, read right after a printk.

## Zephyr sample `samples/drivers/uart/async_api`

### About the sample

`samples/drivers/uart/async_api` uses the async UART API on the board's `zephyr,shell-uart`, which
on Nucleo boards is also the console (ST-LINK VCP). Every 5 s it:

- queues 1 to 4 packets (`Loop N: Packet: M`) with `uart_tx()`; packets that arrive while a TX is
  running are queued and started from the `UART_TX_DONE` callback;
- toggles reception: `uart_rx_enable()` with two 32-byte buffers and a 100 us timeout, or
  `uart_rx_disable()`, and logs `RX is now enabled/disabled`;
- logs received data as `RX_RDY` hexdumps.

The board overlay gives the shell UART its TX/RX DMA channels. Twister scenarios:
`sample.drivers.uart.async_api` (keyboard harness) and `sample.drivers.uart.async_api.console`
(console harness, matches `Loop ... Sending` / `RX is now enabled/disabled`).

Because the console logger writes to the same UART by polling, log lines and DMA packets overwrite
each other. For this report the sample is built with `CONFIG_LOG=n`: every console line must then
be a `Loop N: Packet: M` line, numbered without gaps (`tools/sample_capture.py`).

### Setup on this board

Overlay `samples/drivers/uart/async_api/boards/nucleo_c5a3zg.overlay` (in tree): LPUART1
(console) on LPDMA1, TX ch 3 / request 23, RX ch 4 / request 22. Built with `CONFIG_LOG=n`, and
with device PM for the second row. 47 s capture.

### Results

| Build | `main` | PR |
|---|---|---|
| No PM | 21 packets over 9 loops, 0 corrupted, no gaps | 29 packets over 10 loops, 0 corrupted, no gaps |
| Device PM | 26 packets over 10 loops, 0 corrupted, no gaps | 25 packets over 9 loops, 0 corrupted, no gaps |

No difference, as expected: the RX-enable problem the PR fixes exists only on SoCs with the DMAT
erratum (U5/H5), and the sample does not abort TX. The number of packets per loop is random and
differs between boots.

Each capture contains two boots: the board starts once after programming and again on the capture
reset, and the C5 boots fast enough for both to be captured. Only the last boot is counted
(`tools/sample_capture.py` now does this itself).

## Zephyr test `tests/drivers/uart/uart_async_api`

### About the test

`tests/drivers/uart/uart_async_api`, scenario `drivers.uart.async_api` (ztest, fixture
`gpio_loopback`), drives the `dut` UART from the board overlay with TX wired to RX. Suites:

| Suite / case | What it checks |
|---|---|
| `uart_async_single_read` / `test_single_read` | TX of short buffers, received in one RX buffer with RX_RDY, buffer release and RX_DISABLED |
| `uart_async_multi_rx` / `test_multiple_rx_enable` | RX enabled, disabled and enabled again; no stale events |
| `uart_async_chain_read` / `test_chained_read` | RX buffers chained through RX_BUF_REQUEST across several TX |
| `uart_async_double_buf` / `test_double_buffer` | Double-buffered RX: data split over two buffers, compared to TX |
| `uart_async_read_abort` / `test_read_abort` | `uart_rx_disable()` while data is arriving |
| `uart_async_chain_write` / `test_chained_write` | Next `uart_tx()` started from the TX_DONE callback |
| `uart_async_long_buf` / `test_long_buffers` | Long TX and RX buffers, byte counts |
| `uart_async_var_buf_length` / `test_var_buf_length` | TX/RX with varying buffer lengths and baud rates |
| `uart_async_write_abort` / `test_write_abort` | `uart_tx_abort()` right after `uart_tx()`; TX_ABORTED length must equal the bytes received (only checked when it is not 0) |
| `uart_async_timeout` / `test_forever_timeout` | `SYS_FOREVER_US` TX/RX timeouts: no TX_ABORTED or RX_RDY without data |
| `uart_async_pm` / `test_uart_pm_light_sleep` | Only with `CONFIG_PM=y`: a low-power state is entered between transfers |

### Setup on this board

Overlay `tests/drivers/uart/uart_async_api/boards/nucleo_c5a3zg.overlay` (in tree): `dut` = USART2
on PD5 (TX) / PD6 (RX), LPDMA1 ch 0 / request 15 (TX), ch 1 / request 14 (RX). Loopback: PD5 to
PD6. Run without PM and with device PM (which adds `uart_async_pm`).

### Results

With the PD5-PD6 loopback fitted:

| Case | `main` | PR | `main`, PM | PR, PM | PR, PM without power states |
|---|---|---|---|---|---|
| `uart_async_single_read.test_single_read` | PASS | PASS | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_multi_rx.test_multiple_rx_enable` | PASS | PASS | PASS | PASS | PASS |
| `uart_async_chain_read.test_chained_read` | PASS | PASS | PASS | PASS | PASS |
| `uart_async_double_buf.test_double_buffer` | PASS | PASS | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_read_abort.test_read_abort` | PASS | PASS | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_chain_write.test_chained_write` | PASS | PASS | PASS | PASS | PASS |
| `uart_async_long_buf.test_long_buffers` | PASS | PASS | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_var_buf_length.test_var_buf_length` | PASS | PASS | PASS | PASS | PASS |
| `uart_async_write_abort.test_write_abort` | PASS | PASS | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_timeout.test_forever_timeout` | PASS | PASS | PASS | PASS | PASS |
| `uart_async_pm.test_uart_pm_light_sleep` | not built | not built | PASS | PASS | FAIL (no state entered, expected) |

Result without PM: `main` 10/10, PR 10/10. As on F4/H7, the extra TX_DONE after an abort on
`main` only adds a count to the test's `tx_done` semaphore, which the test resets, so this test
does not distinguish `main` from the PR here; the check app does.

Result with device PM: `main` 6/11, PR 6/11, the same five RX cases failing, and
`test_uart_pm_light_sleep` passing on both, so the SoC does enter STOP. With PM still enabled but
`cpu-power-states` deleted from `cpu0`, all ten UART cases pass and only `test_uart_pm_light_sleep`
fails, as it requires a state to be entered. The five failures therefore come from the SoC
entering STOP while async RX is waiting for data or for the RX timeout: USART2 is not configured
as a wakeup source and the driver holds no PM lock while RX is pending. The same happens on the
NUCLEO-H563ZI. It is existing behavior, identical on `main` and the PR.

Each capture contains two boots (programming, then the capture reset); only the last boot is
counted (`tools/ztest_capture.py` now does this itself). A first run without the loopback failed
all cases on RX timeouts; its logs are kept as `*_no_loopback.log`.

## What was not tested

- RX in STOP with USART2 set up as a wakeup source.
- Current consumption.

## Logs

`logs/nucleo_c5a3zg/`: `{base,pr}_app_nopm.log`, `{base,pr}_app_pm.log`, `{base,pr}_sample.log`,
`{base,pr}_sample_pm.log`, `{base,pr}_zt.log`, `{base,pr}_zt_pm.log` (in-tree test with loopback),
`pr_zt_pm_no_power_states.log`, `{base,pr}_zt{,_pm}_no_loopback.log` (first run, no loopback).
