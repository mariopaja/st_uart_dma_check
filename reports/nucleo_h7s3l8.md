# NUCLEO-H7S3L8: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-11-18 |
| Board | NUCLEO-H7S3L8 (STM32H7S3L8), ST-LINK V3 SN 001E00243433511737363934 |
| Branch | `st_uart_dma_reset_fix` at `32899e5dde2` |
| Baseline | `main` at `e9336422663` |
| DMA | GPDMA1 (`st,stm32u5-dma`) |
| DMAT erratum | Not affected (`CONFIG_UART_STM32U5_ERRATA_DMAT_AFFECTED` not set) |
| Loopback | D1 (PB14) - D0 (PA10) jumper fitted |

Every image was built from the commit named in its `BUILD_VERSION`; the base was built from a
separate worktree at `main`, checked by the `drivers/serial/uart_stm32.c` path in `build.ninja`.
Images were flashed with STM32_Programmer_CLI (`mode=UR`, no rebuild). No PM variant: the H7RS
has no `CONFIG_PM` support. `CONFIG_DCACHE=n` as on the H745.

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app | **12 failures** (every abort case) | 0 failures |
| Sample `async_api`, `CONFIG_LOG=n` | 14 packets over 5 loops, all intact, no gaps | 9 packets over 5 loops, all intact, no gaps |

The packet count differs only because the sample sends a random 1 to 4 packets per loop.
The H7S3 has no DMAT erratum, so the UE-toggle path is not built and RX enable during TX
passes on `main` too (as on the F429). The abort fixes (TC disable on abort, GPDMA FIFO count)
apply.

`tests/drivers/uart/uart_async_api` was not run: it overflows the 64 KB internal flash by 38 KB
(23 KB with `CONFIG_ASSERT=n`). In tree it is set up only for the `ext_flash_app` variant
(MCUboot + external flash). A rerun with `tools/hw_matrix.sh` on 2026-11-18 gave the same app
and sample results.

## Check app (`uart_dma_check`)

`dut` = USART1 (Arduino D1 = PB14 TX / D0 = PA10 RX) on GPDMA1, TX ch 2 / request 74, RX ch 3 /
request 73. First round shown; rounds 2 and 3 are identical.

| Case | `main` | PR |
|---|---|---|
| plain tx | PASS | PASS |
| rx_enable during tx | PASS | PASS `done=1 len=200 t=17375us` |
| next tx after it | PASS | PASS |
| abort mid tx | **FAIL** `done=1 len=97`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=89` |
| abort immediately | **FAIL** `done=1 len=10`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=2` |
| rx_enable, then abort | **FAIL** `done=1 len=56`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=48` |
| next tx after it | PASS | PASS |
| tx timeout (driver abort) | **FAIL** `done=1 len=68`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=60` |
| Result | 12 failures | 0 failures |

On `main` each abort produces both a TX_DONE and a TX_ABORTED with `len=0`. The TX_DONE
reports more bytes than the PR's TX_ABORTED (97 vs 89): on `main` the bytes still in the GPDMA
FIFO are counted as sent.

## Sample `samples/drivers/uart/async_api`

USART3 (console, ST-LINK VCP) on GPDMA1, TX ch 0 / request 78, RX ch 1 / request 77, with
`CONFIG_LOG=n`; checked with `tools/sample_capture.py` over 25 s.

| | `main` | PR |
|---|---|---|
| Intact packets | 14 | 9 |
| Corrupted lines | 0 | 0 |
| Loops seen | 5, no gaps | 5, no gaps |

## Files

- `boards/nucleo_h7s3l8.overlay`, `boards/nucleo_h7s3l8.conf` (check app)
- `zephyr/samples/drivers/uart/async_api/boards/nucleo_h7s3l8.{overlay,conf}` (not committed)
- Logs: `reports/logs/nucleo_h7s3l8/{base,pr}_{app,sample}.log`
