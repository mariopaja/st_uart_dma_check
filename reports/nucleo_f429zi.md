# NUCLEO-F429ZI: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-10-01 |
| Board | NUCLEO-F429ZI (STM32F429ZI, device ID 0x419), ST-LINK V2.1 |
| Branch | `st_uart_dma_reset_fix` at `67b70ed6bef` (PR #120833) |
| Baseline | `main` at `5075ddf1460` |
| DMA | DMA2 (`st,stm32-dma-v1`), FIFO enabled |
| DMAT erratum | Not affected: the UE-toggle workaround and the RX-enable change are compiled out |

Raw logs were not kept; results below were recorded during the runs.

On this SoC only the TC-disable-on-abort and TX-error commits change behavior. The DMA FIFO count
commit is for `st,stm32u5-dma` only.

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | 4 abort cases **FAIL** in every round | all PASS |
| Check app, device PM | same 4 **FAIL**s; PM lock free (released by the extra TX_DONE) | all PASS, lock released by the abort |
| `tests/drivers/uart/uart_async_api` (PG14-PG9 jumper) | 10/10 | 10/10 |

## Check app (`uart_dma_check`)

`dut` = USART6 (PG14/PG9) on DMA2, TX stream 7 / RX stream 2, channel 5, FIFO full.

The app runs its case list three times; each round prints 9 lines, so a run has 27 PASS/FAIL
lines. A line passes when:

| Case | Pass condition | Checks PM lock |
|---|---|---|
| plain tx (start and end of each round) | one TX_DONE with all 200 bytes, no TX_ABORTED, TX time at least 90 % of 17.4 ms | yes |
| rx_enable during tx | `uart_rx_enable()` 2 ms into the TX; one TX_DONE with all 200 bytes, not early | no |
| next tx after it (twice per round) | the next `uart_tx()` is accepted and completes with all 200 bytes | no |
| abort mid tx / abort immediately / rx_enable, then abort / tx timeout | exactly one TX_ABORTED and no TX_DONE | yes |

| Case | `main` | PR |
|---|---|---|
| rx_enable during tx | PASS (no UE toggle on F4) | PASS |
| abort mid tx / immediately / after RX enable / tx timeout | **FAIL**: extra `TX_DONE len=0` about 1 ms after TX_ABORTED | PASS, TX_ABORTED only |
| TX_ABORTED length | 89 / 1 / 48 / 60 | 89 / 1 / 48 / 60 |

Register dump on `main`: TCIE stays set after the abort, TC sets 1 ms later and TX_DONE follows.
With the PR TCIE is 0 right after the abort; TC still sets, without an event. On F4 the extra
TX_DONE comes after TX_ABORTED, so the abort length is correct on both builds.

With device PM (`pm.conf`, all F4 power states, no overlay) the image boots and both builds keep
the PM lock free; on `main` it is the extra TX_DONE that releases it.

Failure counts: on `main` only the four abort cases fail, in every round, both without PM and with
device PM (no UE toggle on F4, and the lock does not stay held); "rx_enable during tx" and the plain
tx lines pass. The total per run was not recorded for this board; the PR passed all 27 lines in
both builds.

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
| `uart_async_pm` / `test_uart_pm_light_sleep` | Only with `CONFIG_PM=y`; not built in these runs |

Run: build `tests/drivers/uart/uart_async_api` for the board, flash, capture with
`tools/ztest_capture.py` (or `west twister --device-testing ... --fixture gpio_loopback`).

### Setup on this board

Overlay `tests/drivers/uart/uart_async_api/boards/nucleo_f429zi.overlay` (in tree): `dut` = USART6
on DMA2, TX stream 7 / RX stream 2, channel 5, FIFO full. Loopback: PG14 (TX) to PG9 (RX).

### Results

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

Result: `main` 10/10, PR 10/10. The extra TX_DONE after an abort only adds a count to the test's
`tx_done` semaphore, which the test resets, so this test does not distinguish `main` from the PR
on F4. `test_write_abort` runs its sent/received comparison on both, as the F4 abort length is
not reset (the extra TX_DONE comes after TX_ABORTED).

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
be a `Loop N: Packet: M` line, numbered without gaps (`tools/sample_capture.py`). On U5/H5 the RX-enable
loops are the ones that hit the UE toggle while the first packet is being sent.

### Setup on this board

Overlay `samples/drivers/uart/async_api/boards/nucleo_f429zi.overlay` (in tree): USART3 (console)
on DMA1, TX stream 3 / RX stream 1, channel 4, FIFO full.

### Results

**Not run on this board.** Expected to show no difference between `main` and the PR: the UE
toggle that breaks the RX-enable loops on U5/H5 is not built for F4, and the sample does not
abort TX.

## What was not tested

- Sample `samples/drivers/uart/async_api` (see above).
- `uart_async_pm` suite (needs `CONFIG_PM=y`).
- Current consumption in STOP.

## Re-run 2026-11-18 (PR at `32899e5dde2`, `main` at `e9336422663`)

ST-LINK SN 0663FF353445503043082449, D0 (PG9) - D1 (PG14) jumper. Images flashed with
STM32_Programmer_CLI, no rebuild; base built from a separate worktree at `main`.

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | **12 failures** (every abort: extra `TX_DONE len=0`) | 0 failures |
| Check app, device PM | **12 failures** (same) | 0 failures, PM lock free after every case |
| Sample `async_api`, `CONFIG_LOG=n` | 12 packets, 5 loops, intact, no gaps | 12 packets, 5 loops, intact, no gaps |
| Sample `async_api`, device PM | 16 packets, 5 loops, intact, no gaps | 15 packets, 5 loops, intact, no gaps |
| `tests/drivers/uart/uart_async_api` | 10/10 | 10/10 |
| `uart_async_api` with device PM (`pm.conf`) | 6/11 (5 RX cases time out on `rx_rdy`) | 6/11 (same cases) |

Same as the first run: abort lengths 89 / 1 / 48 / 60 on both, TX times unchanged (17.37 ms).
Packet counts differ only by the sample's random 1 to 4 packets per loop.
Logs: `reports/logs/nucleo_f429zi/2026-11-18_*.log`.
