# NUCLEO-U575ZI-Q: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-10-01 |
| Board | NUCLEO-U575ZI-Q (STM32U575ZI, device ID 0x482), ST-LINK V3 |
| Branch | `st_uart_dma_reset_fix` at `a655b1d9346`, code-identical to `67b70ed6bef` (PR #120833; only trailers differ) |
| Baseline | `main` at `5075ddf1460` |
| DMA | GPDMA1 (`st,stm32u5-dma`), 8-byte FIFO on channels 0-11, 32-byte on 12-15 |
| DMAT erratum | Affected (ES0499): `CONFIG_UART_STM32U5_ERRATA_DMAT_AFFECTED=y`, `NOCLEAR` without PM, `LOWPOWER` with PM |

Raw logs were not kept; results below were recorded during the runs. Baseline images were flashed
with STM32_Programmer_CLI after confirming their `BUILD_VERSION` (an earlier attempt with plain
`west flash` rebuilt them from the branch and is not counted).

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | RX enable during TX and every abort case **FAIL** | all PASS |
| Check app, device PM | same **FAIL**s, PM lock stuck from the first RX-enable case | all PASS, PM lock free after every case |
| Sample `async_api`, `CONFIG_LOG=n` | first packet of every RX-enable loop **corrupted**, 12 packets received | 24/24 and 26/26 intact |
| Sample `async_api`, with logging | `dma stream 0 is busy`, `TX from ISR failed (-22)` on RX-enable loops | no errors |
| `tests/drivers/uart/uart_async_api` (PD5-PD6 jumper) | 10/10, but `test_write_abort` skips its check (0 bytes sent) | 10/10, check runs |

## Check app (`uart_dma_check`)

`dut` = USART2 (PD5/PD6) on GPDMA1, TX ch 2 / request 27, RX ch 3 / request 26.

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
| rx_enable during tx | **FAIL**: TX_DONE at the moment RX is enabled, then a second one | PASS, one TX_DONE, 200 bytes in 17.37 ms |
| abort mid tx / immediately / after RX enable / tx timeout | **FAIL**: extra TX_DONE, TX_ABORTED reports 0 bytes | PASS, TX_ABORTED only: 89 / 2 / 48 / 60 bytes |
| PM lock (device PM) | stays held after the first RX-enable case | free after every case |

Register dump on `main`: TCIE stays set after the abort and `done=1`; with the PR TCIE is 0 right
after the abort.

Failure counts follow the same pattern as on the NUCLEO-H563ZI (same SoC behavior: UE toggle and
GPDMA): on `main`, the five cases above fail in every round, and with device PM the plain tx lines
fail as well once the first "rx_enable during tx" has left the PM lock held. The total per run was
not recorded for this board; the PR passed all 27 lines in both builds.

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

Overlay `tests/drivers/uart/uart_async_api/boards/nucleo_u575zi_q.overlay` (in tree): `dut` =
USART2 on GPDMA1, TX ch 0 / request 27, RX ch 1 / request 26. Loopback: PD5 (TX) to PD6 (RX).

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
| `uart_async_write_abort.test_write_abort` | PASS | PASS (see below) |
| `uart_async_timeout.test_forever_timeout` | PASS | PASS |

Result: `main` 10/10, PR 10/10.

`test_write_abort` on `main` passes only because TX_ABORTED reports 0 bytes (the extra TX_DONE
resets the counter first), so its sent/received comparison is skipped. With the PR the
comparison runs:

| Build | `sent` (TX_ABORTED) | `received` | Result |
|---|---|---|---|
| `main` | 0 | 2 | PASS (check skipped) |
| PR without the DMA FIFO commit, TX ch 0 (8-byte FIFO) | 10 | 2 | **FAIL** |
| PR without the DMA FIFO commit, TX ch 12 (32-byte FIFO) | 34 | 2 | **FAIL** |
| PR | 2 | 2 | PASS |

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

Overlay `samples/drivers/uart/async_api/boards/nucleo_u575zi_q.overlay` (added by the PR): USART1
(console) on GPDMA1, TX ch 0 / request 25, RX ch 1 / request 24.

### Results

| Build | `main` | PR |
|---|---|---|
| With logging | `dma stream 0 is busy`, `uart_stm32: dma tx config error!`, `TX from ISR failed (-22)` on every RX-enable loop, packets missing | no errors; byte 2 of the first packet per loop lost to log/DMA overlap on the shared UART (also on `main`) |
| `CONFIG_LOG=n` | first packet of every RX-enable loop corrupted (`�op N: Packet: 0`), 12 packets received | 24/24 and 26/26 packets intact, no gaps |

## Builds

Every commit of the series builds for `nucleo_u575zi_q` with and without `CONFIG_PM`
(`CONFIG_COMPILER_WARNINGS_AS_ERRORS=y`).

## Notes

- `CONFIG_PM=y` alone hangs after the boot banner, on `main` too. Device PM needs `pm.conf` and
  `pm/nucleo_u575zi_q.overlay` (STOP0/STOP1).
- After a PM image only connect mode `POWERDOWN` reaches the target.

## Re-run 2026-11-18 (PR at `32899e5dde2`, `main` at `e9336422663`)

`tools/hw_matrix.sh`, PD5-PD6 jumper.

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | **15 failures** | 0 failures |
| Check app, device PM | **20 failures** | 0 failures |
| Sample `async_api`, `CONFIG_LOG=n` | **2 corrupted** (`�op 2/4: Packet: 0`, first packet of each RX-enable loop), 7 intact over 2 loops | 13 intact over 5 loops, no gaps |
| Sample `async_api`, device PM | **2 corrupted** (same), 5 intact over 2 loops | 11 intact, 1 corrupted: first byte after the boot banner (`oop 0`), as on the H563 |
| `tests/drivers/uart/uart_async_api` | 10/10 | 10/10 |
| `uart_async_api` with device PM, STOP0/STOP1 | 6/11 (5 RX cases time out on `rx_rdy`) | 6/11 (same cases) |

The device PM ztest first ran without `pm/nucleo_u575zi_q.overlay` (the script applied it to the
check app only), so STOP2 was allowed: it hung in `test_var_buf_length` on both builds. In STOP2,
USART2 and GPDMA1 stop; only LPUART1/LPDMA1 keep running. Rerun with the overlay (STOP0/STOP1,
PR at `229ec334fe5`, same driver code): 6/11 on both, the same cases as on the H563, F429 and
C5A3. The sample results with STOP0/STOP1 match the table above. Logs: `*_stop01.log`.
Logs: `reports/logs/nucleo_u575zi_q/2026-11-18_*.log`.
