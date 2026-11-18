# NUCLEO-U3C5ZI-Q: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-11-18 |
| Board | NUCLEO-U3C5ZI-Q (STM32U3C5ZI), ST-LINK SN 002E00353235510F37333439 |
| Branch | `st_uart_dma_reset_fix` at `32899e5dde2` |
| Baseline | `main` at `e9336422663` |
| DMA | GPDMA1 (`st,stm32u5-dma`) |
| DMAT erratum | Not affected (UE-toggle path not built) |
| Loopback | Wire PG7 - PG8 (a D0 - D1 jumper does not connect these pins on this board) |

Run with `tools/hw_matrix.sh nucleo_u3c5zi_q`: every image built from the commit named in its
`BUILD_VERSION`, base from a worktree at `main`, flashed with STM32_Programmer_CLI
(`mode=POWERDOWN`). The device PM variant adds `pm.conf`.

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | **12 failures** (every abort case) | 0 failures |
| Check app, device PM | **12 failures** (same) | 0 failures, PM lock free after every case |
| Sample `async_api`, `CONFIG_LOG=n` | 13 packets over 5 loops, intact, no gaps | 16 packets over 5 loops, intact, no gaps |
| Sample `async_api`, device PM | 12 packets over 5 loops, intact, no gaps | 12 packets over 5 loops, intact, no gaps |
| `tests/drivers/uart/uart_async_api` (LPUART1) | 10/10 | 10/10 |
| `uart_async_api` with device PM | 7/11 | 7/11 (same cases) |

The U3 has GPDMA but no DMAT erratum, so it is the only board here where the PR's GPDMA changes
run with device PM and without the UE-toggle workaround. RX enable during TX passes on both.

Check app abort cases (first round, device PM; no PM is the same):

| Case | `main` | PR |
|---|---|---|
| abort mid tx | **FAIL** `done=1 len=97`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=89` |
| abort immediately | **FAIL** `done=1 len=10`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=2` |
| rx_enable, then abort | **FAIL** `done=1 len=56`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=48` |
| tx timeout (driver abort) | **FAIL** `done=1 len=70`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=62` |

As on the H7S3L8, `main` reports the bytes still in the GPDMA FIFO as sent (97 vs 89).

ztest with device PM fails on both builds in `test_single_read`, `test_forever_timeout`,
`test_write_abort` (`tx_done` not given within 100 ms) and `test_var_buf_length`. The PR does not
change this. `test_uart_pm_light_sleep` passes on both.

The first run had the jumper on D0 - D1, which on this board is not PG8 - PG7: every ztest case
received 0 bytes, on both builds. Driving PG7 over SWD and reading PG8 confirmed the pins were not
connected; with a PG7 - PG8 wire PG8 follows PG7.

## Files

- `boards/nucleo_u3c5zi_q.overlay` (check app: `dut` = LPUART1, GPDMA1 TX ch 2 / request 35,
  RX ch 3 / request 34)
- `zephyr/tests/drivers/uart/uart_async_api/boards/nucleo_u3c5zi_q.overlay` (same UART, ch 0/1;
  not committed)
- `zephyr/samples/drivers/uart/async_api/boards/nucleo_u3c5zi_q.overlay` (USART1 console,
  requests 25/24; not committed)
- Logs: `reports/logs/nucleo_u3c5zi_q/{base,pr}_{app,sample,zt}_{nopm,pm}.log`, `summary.txt`
