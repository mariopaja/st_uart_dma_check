# NUCLEO-F767ZI: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-11-18 |
| Board | NUCLEO-F767ZI (STM32F767ZI, Cortex-M7), ST-LINK SN 0671FF555567894967085923 |
| Branch | `st_uart_dma_reset_fix` at `32899e5dde2` |
| Baseline | `main` at `e9336422663` |
| DMA | DMA2 (`st,stm32-dma-v1`, same driver as the F4) |
| DMAT erratum | Not affected |
| Loopback | D1 (PG14) - D0 (PG9) jumper fitted |

Run with `tools/hw_matrix.sh nucleo_f767zi`: every image built from the commit named in its
`BUILD_VERSION`, base from a worktree at `main`, flashed with STM32_Programmer_CLI. No PM variant:
the F7 has no `HAS_PM`. `CONFIG_DCACHE=n` (the driver rejects DMA buffers in cached memory).

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app | **12 failures** (every abort case) | 0 failures |
| Sample `async_api`, `CONFIG_LOG=n` | 11 packets over 5 loops, intact, no gaps | 12 packets over 5 loops, intact, no gaps |
| `tests/drivers/uart/uart_async_api` (USART6, PG14-PG9) | 10/10 | 10/10 |

Same behaviour as the F429: on `main` every abort produces an extra `TX_DONE len=0` after the
TX_ABORTED; the abort lengths are the same on both (89 / 2 / 48 / 60). Plain TX and RX enable
during TX pass on both with the same TX time. Packet counts differ only by the sample's random
1 to 4 packets per loop.

## Files

- `boards/nucleo_f767zi.overlay`, `boards/nucleo_f767zi.conf` (check app; same `dut` as the F429)
- `zephyr/samples/drivers/uart/async_api/boards/nucleo_f767zi.{overlay,conf}` (copy of the F746
  ones: USART3 console on DMA1; not committed)
- ztest: in-tree `tests/drivers/uart/uart_async_api/boards/nucleo_f767zi.{overlay,conf}`
- Logs: `reports/logs/nucleo_f767zi/{base,pr}_{app,sample,zt}_nopm.log`, `summary.txt`
