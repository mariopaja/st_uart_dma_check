# NUCLEO-H745ZI-Q (M7 core): STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-10-02 |
| Board | NUCLEO-H745ZI-Q (STM32H745ZI, device ID 0x450), ST-LINK V3; Zephyr target `nucleo_h745zi_q/stm32h745xx/m7`, M7 image only |
| Branch | `st_uart_dma_reset_fix` at `67b70ed6bef` (PR #120833) |
| Baseline | `main` at `5075ddf1460` |
| DMA | DMA1/DMA2 through DMAMUX1 (`st,stm32-dma-v1`) |
| DMAT erratum | Not affected: the UE-toggle workaround and the RX-enable change are compiled out |
| PM | Not available: the STM32H7 series does not enable `HAS_PM` in Zephyr |
| Cache | `CONFIG_DCACHE=n` in every build (board `.conf`), as in the in-tree H7 overlays |

Every image was built from the commit named in its `BUILD_VERSION` and flashed with
STM32_Programmer_CLI without a rebuild. The new board overlays (see below) were present in both
builds.

On this SoC only the TC-disable-on-abort and TX-error commits change behavior; the DMA FIFO count
commit is for `st,stm32u5-dma` only. The board behaves like the NUCLEO-F429ZI.

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app | **12 failures** (4 abort cases x 3 rounds) | 0 failures |
| Sample `async_api`, `CONFIG_LOG=n` | 29 packets over 10 loops, all intact | 19 packets over 9 loops, all intact |
| `tests/drivers/uart/uart_async_api` (PD5-PD6 loopback) | 10/10 | 10/10 |

## Check app (`uart_dma_check`)

`dut` = USART2 (PD5 TX / PD6 RX) on DMA1 through DMAMUX1, TX stream 2 / request 44, RX stream 3 /
request 43 (`uart_dma_check/boards/nucleo_h745zi_q_stm32h745xx_m7.overlay`, with
`CONFIG_DCACHE=n` in the matching `.conf`). No loopback is needed.

The app runs its case list three times; each round prints 9 lines, so a run has 27 PASS/FAIL
lines. A line passes when:

| Case | Pass condition | Checks PM lock |
|---|---|---|
| plain tx (start and end of each round) | one TX_DONE with all 200 bytes, no TX_ABORTED, TX time at least 90 % of 17.4 ms | yes |
| rx_enable during tx | `uart_rx_enable()` 2 ms into the TX; one TX_DONE with all 200 bytes, not early | no |
| next tx after it (twice per round) | the next `uart_tx()` is accepted and completes with all 200 bytes | no |
| abort mid tx / abort immediately / rx_enable, then abort / tx timeout | exactly one TX_ABORTED and no TX_DONE | yes |

(PM is not built on this board, so the PM lock check always passes.)

| Case (first round) | `main` | PR |
|---|---|---|
| plain tx | PASS | PASS |
| rx_enable during tx | PASS `done=1 len=200 t=17369us` (no UE toggle on H7) | PASS |
| next tx after it | PASS | PASS |
| abort mid tx | **FAIL** extra `TX_DONE len=0`, TX_ABORTED `len=89` | PASS, TX_ABORTED `len=89` |
| abort immediately | **FAIL** extra `TX_DONE len=0`, TX_ABORTED `len=2` | PASS, TX_ABORTED `len=2` |
| rx_enable, then abort | **FAIL** extra `TX_DONE len=0`, TX_ABORTED `len=48` | PASS, TX_ABORTED `len=48` |
| next tx after it | PASS | PASS |
| tx timeout (driver abort) | **FAIL** extra `TX_DONE len=0`, TX_ABORTED `len=60` | PASS, TX_ABORTED `len=60` |
| plain tx | PASS | PASS |

### How the failure counts add up

| Line (per run) | Lines | `main` | PR |
|---|---|---|---|
| abort mid tx, abort immediately, rx_enable then abort, tx timeout | 4 x 3 | 12 FAIL | 0 |
| rx_enable during tx | 3 | 0 | 0 |
| plain tx, next tx after it | 12 | 0 | 0 |
| **Total** | **27** | **12** | **0** |

On `main` the TC interrupt stays enabled after an abort, so TX_DONE follows TX_ABORTED. As on F4,
it comes after TX_ABORTED, so the abort lengths are the same on both builds.

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

Overlay `samples/drivers/uart/async_api/boards/nucleo_h745zi_q_stm32h745xx_m7.overlay` (new,
untracked): USART3 (console) on DMAMUX1, TX stream 2 / request 46, RX stream 3 / request 45;
`nucleo_h745zi_q_stm32h745xx_m7.conf` sets `CONFIG_DCACHE=n`. 47 s capture.

### Results

| | `main` | PR |
|---|---|---|
| Intact packets | 29 over 10 loops | 19 over 9 loops |
| Corrupted lines | 0 | 0 |
| Loops with gaps | 0 | 0 |

No difference, as expected: the RX-enable problem the PR fixes exists only on SoCs with the DMAT
erratum (U5/H5), and the sample does not abort TX. The number of packets per loop is random and
differs between boots.

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
| `uart_async_pm` / `test_uart_pm_light_sleep` | Only with `CONFIG_PM=y`; not available on H7 |

### Setup on this board

Overlay `tests/drivers/uart/uart_async_api/boards/nucleo_h745zi_q_stm32h745xx_m7.overlay` (new,
untracked): `dut` = USART2 on PD5 (TX) / PD6 (RX), DMAMUX1 stream 2 / request 44 (TX), stream 3 /
request 43 (RX), DMA1/DMA2/DMAMUX1 enabled; `.conf` sets `CONFIG_DCACHE=n`. Loopback: PD5 to PD6.

### Results

With the PD5-PD6 loopback fitted:

| Case | `main` | PR |
|---|---|---|
| `uart_async_single_read.test_single_read` | PASS | PASS |
| `uart_async_multi_rx.test_multiple_rx_enable` | PASS | PASS |
| `uart_async_chain_read.test_chained_read` | PASS | PASS |
| `uart_async_double_buf.test_double_buffer` | PASS | PASS |
| `uart_async_read_abort.test_read_abort` | PASS | PASS |
| `uart_async_chain_write.test_chained_write` | PASS | PASS |
| `uart_async_long_buf.test_long_buffers` | PASS | PASS |
| `uart_async_var_buf_length.test_var_buf_length` | PASS | PASS |
| `uart_async_write_abort.test_write_abort` | PASS | PASS |
| `uart_async_timeout.test_forever_timeout` | PASS | PASS |

Result: `main` 10/10, PR 10/10. As on the F429, the extra TX_DONE after an abort on `main` only adds
a count to the test's `tx_done` semaphore, which the test resets, so this test does not
distinguish `main` from the PR on this SoC; the check app does.

A first run without a working loopback failed all 10 cases on both builds on RX timeouts
(`k_sem_take(&rx_rdy, ...)`); its logs are kept as `*_zt_no_loopback.log`.

## What was not tested

- PM: not available for STM32H7 in Zephyr.
- M4 core.

## Logs

`logs/nucleo_h745zi_q_stm32h745xx_m7/`: `{base,pr}_app.log`, `{base,pr}_sample.log`,
`{base,pr}_zt_loopback.log` (in-tree test), `{base,pr}_zt_no_loopback.log` (first run, no
loopback).
