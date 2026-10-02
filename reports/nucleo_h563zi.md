# NUCLEO-H563ZI: STM32 async UART DMA test report

| | |
|---|---|
| Date | 2026-10-02 |
| Board | NUCLEO-H563ZI (STM32H563ZI, device ID 0x484), ST-LINK V3 |
| Branch | `st_uart_dma_reset_fix` at `67b70ed6bef` (PR #120833) |
| Baseline | `main` at `5075ddf1460` |
| DMA | GPDMA1 (`st,stm32u5-dma`) |
| DMAT erratum | Affected (ES0565): `CONFIG_UART_STM32U5_ERRATA_DMAT_AFFECTED=y`, `NOCLEAR` without PM, `LOWPOWER` with PM |

Every image was built from the commit named in its `BUILD_VERSION` and flashed with
STM32_Programmer_CLI without a rebuild. The new board overlays (see below) were present in both
builds.

## Summary

| Test | `main` | PR |
|---|---|---|
| Check app, no PM | **15 failures** | 0 failures |
| Check app, device PM | **20 failures**, PM lock stuck from the first RX-enable case | 0 failures, PM lock free after every case |
| Sample `async_api`, `CONFIG_LOG=n` | **4 corrupted packets**, 6 packets received over 4 loops | 26 packets over 9 loops, all intact |
| `tests/drivers/uart/uart_async_api` (USART2, PD5-PD6 loopback) | 10/10 | 10/10 |
| `tests/drivers/uart/uart_async_api` with device PM | 6/11 (5 RX cases fail, PM suite passes) | 6/11 (same cases) |
| Sample `async_api`, device PM, `CONFIG_LOG=n` | **4 corrupted packets**, 8 received | 19 intact, 1 corrupted: first byte after the boot banner (clean with `CONFIG_BOOT_BANNER=n`) |

The H563 behaves like the U575: all PR changes apply (UE-toggle deferral, TC disable on abort,
GPDMA FIFO count, TX error cleanup).

## Check app (`uart_dma_check`)

`dut` = LPUART1 (Arduino D1 = PB6 TX / D0 = PB7 RX) on GPDMA1, TX ch 2 / request 46, RX ch 3 /
request 45. Tables below show the first round.

The app runs its case list three times; each round prints 9 lines, so a run has 27 PASS/FAIL
lines. A line passes when:

| Case | Pass condition | Checks PM lock |
|---|---|---|
| plain tx (start and end of each round) | one TX_DONE with all 200 bytes, no TX_ABORTED, TX time at least 90 % of 17.4 ms | yes |
| rx_enable during tx | `uart_rx_enable()` 2 ms into the TX; one TX_DONE with all 200 bytes, not early | no |
| next tx after it (twice per round) | the next `uart_tx()` is accepted and completes with all 200 bytes | no |
| abort mid tx / abort immediately / rx_enable, then abort / tx timeout | exactly one TX_ABORTED and no TX_DONE | yes |

### Without PM

| Case | `main` | PR |
|---|---|---|
| plain tx | PASS | PASS |
| rx_enable during tx | **FAIL** `done=2 len=0` (early TX_DONE) | PASS `done=1 len=200 t=17368us` |
| next tx after it | PASS | PASS |
| abort mid tx | **FAIL** `done=1`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=89` |
| abort immediately | **FAIL** `done=1`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=2` |
| rx_enable, then abort | **FAIL** `done=2`, no TX_ABORTED | PASS, TX_ABORTED `len=48` |
| next tx after it | PASS | PASS |
| tx timeout (driver abort) | **FAIL** `done=1`, TX_ABORTED `len=0` | PASS, TX_ABORTED `len=60` |
| Result | 15 failures | 0 failures |

### With device PM (`pm.conf`, all of the H5's `stop` state)

| Case | `main` | PR |
|---|---|---|
| rx_enable during tx | **FAIL** `done=2`, `pm_lock=1` | PASS, `pm_lock=0` |
| pm_lock after rx_disable | **1** | 0 |
| abort cases | **FAIL** (extra TX_DONE), `pm_lock=1` | PASS, `pm_lock=0` |
| Result | 20 failures, lock never released again | 0 failures |

On `main`, the early and the real TX_DONE both release the PM lock, so the count underflows and
the SoC can no longer enter STOP. `end pm_lock=1` on the last line of both PM runs is the
console's own TX lock, read right after a printk.

### How the failure counts add up

Counted from `logs/nucleo_h563zi/base_app_nopm.log` and `base_app_pm.log`:

| Line (per run) | Lines | `main` no PM | `main` device PM | PR |
|---|---|---|---|---|
| rx_enable during tx | 3 | 3 FAIL | 3 FAIL | 0 |
| abort mid tx | 3 | 3 FAIL | 3 FAIL | 0 |
| abort immediately | 3 | 3 FAIL | 3 FAIL | 0 |
| rx_enable, then abort | 3 | 3 FAIL | 3 FAIL | 0 |
| tx timeout (driver abort) | 3 | 3 FAIL | 3 FAIL | 0 |
| plain tx | 6 | 0 | 5 FAIL | 0 |
| next tx after it | 6 | 0 | 0 | 0 |
| **Total** | **27** | **15** | **20** | **0** |

Without PM, the five failing cases fail in every round: 5 x 3 = 15.

With device PM, the first "rx_enable during tx" on `main` leaves the PM lock held for good: the
early and the real TX_DONE both release it, so the lock count underflows. From then on every plain
tx also fails, on the lock check alone. Only the first plain tx of round 1 runs before that, so 5
of the 6 plain tx lines fail: 15 + 5 = 20. The abort cases also see the held lock, but they already
fail on the extra TX_DONE and are counted once. The "next tx after it" lines do not check the lock
and still pass.


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

Overlay `samples/drivers/uart/async_api/boards/nucleo_h563zi.overlay` (new, untracked): USART3
(console) on GPDMA1, TX ch 0 / request 26, RX ch 1 / request 25. Build:
`west build -b nucleo_h563zi samples/drivers/uart/async_api -- -DCONFIG_LOG=n`; 47 s capture.

### Results

| | `main` | PR |
|---|---|---|
| Intact packets | 6 | 26 |
| Corrupted lines | 4 (`�op 2/4/6/8: Packet: 0`: first packet of every RX-enable loop) | 0 |
| Loops seen | 4 (packets lost to `TX from ISR failed`) | 9, no gaps |

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
| `uart_async_pm` / `test_uart_pm_light_sleep` | Only with `CONFIG_PM=y`: a low-power state is entered between transfers (see the device PM section) |

Run: build `tests/drivers/uart/uart_async_api` for the board, flash, capture with
`tools/ztest_capture.py` (or `west twister --device-testing ... --fixture gpio_loopback`).

### Setup on this board

Overlay `tests/drivers/uart/uart_async_api/boards/nucleo_h563zi.overlay` (new, untracked): `dut` =
USART2 on PD5 (TX) / PD6 (RX), GPDMA1 TX ch 0 / request 24, RX ch 1 / request 23. Loopback: PD5 to
PD6. The board does not enable USART2, so the overlay sets its pins, baud rate and status, as the
`nucleo_h753zi` overlay does.

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

Result: `main` 10/10, PR 10/10.

The first version of the overlay used LPUART1 (Arduino D1/D0). With it, `test_long_buffers`
failed on both builds (9/10): on LPUART instances the driver's RX timeout runs from the IDLE event
instead of the last received byte, so 508 bytes were reported as 115 + 393. This is an existing
driver issue, unrelated to the PR, and the reason the overlay uses USART2. Details:
[issue_stm32_lpuart_async_rx_timeout.md](issue_stm32_lpuart_async_rx_timeout.md).

## With device PM: Zephyr test and sample

PM is supported on this SoC (`HAS_PM`, one `stop` state). Both were built with
`uart_dma_check/pm.conf` (`CONFIG_PM`, `CONFIG_PM_DEVICE`, `CONFIG_PM_DEVICE_SYSTEM_MANAGED`),
which also builds the test's `uart_async_pm` suite and selects the `DMAT_LOWPOWER` TX workaround.

### `tests/drivers/uart/uart_async_api`

| Case | `main`, PM | PR, PM | PR, PM without power states |
|---|---|---|---|
| `uart_async_single_read.test_single_read` | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_multi_rx.test_multiple_rx_enable` | PASS | PASS | PASS |
| `uart_async_chain_read.test_chained_read` | PASS | PASS | PASS |
| `uart_async_double_buf.test_double_buffer` | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_read_abort.test_read_abort` | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_chain_write.test_chained_write` | PASS | PASS | PASS |
| `uart_async_long_buf.test_long_buffers` | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_var_buf_length.test_var_buf_length` | PASS | PASS | PASS |
| `uart_async_write_abort.test_write_abort` | **FAIL** (RX_RDY timeout) | **FAIL** (RX_RDY timeout) | PASS |
| `uart_async_timeout.test_forever_timeout` | PASS | PASS | PASS |
| `uart_async_pm.test_uart_pm_light_sleep` | PASS | PASS | FAIL (no state entered, expected) |

Result: `main` 6/11, PR 6/11, the same five cases failing.

The five failures are RX cases waiting for data or for the RX timeout: the SoC enters STOP while
reception is pending. The third column confirms it: with PM still enabled but the `stop` state
removed from `cpu0` (`/delete-property/ cpu-power-states`), all ten UART cases pass and only
`test_uart_pm_light_sleep` fails, as it requires a state to be entered. USART2 runs from a bus
clock that stops in STOP and is not configured as a wakeup source, and the driver holds no PM lock
while async RX is waiting. ST's `samples/boards/st/power_mgmt/serial_wakeup` covers RX in STOP with
`wakeup-source` and an HSI16 kernel clock. This is existing behavior, identical on `main` and the
PR, and not related to the PR. `test_uart_pm_light_sleep` passes on both builds, so the SoC does
reach the low-power state.

### `samples/drivers/uart/async_api`, `CONFIG_LOG=n`

| Run | `main`, PM | PR, PM |
|---|---|---|
| With boot banner (3 runs on the PR) | 8 intact, 4 corrupted (`op 2/4/6/8: Packet: 0`, every RX-enable loop) | 19 intact, 1 corrupted every run: `oop 0: Packet: 0` |
| `CONFIG_BOOT_BANNER=n` (2 runs) | not run | 23 intact, 0 corrupted |

The one corrupted line with the PR is the first packet after the boot banner. With PM the driver
uses the `DMAT_LOWPOWER` workaround: `uart_stm32_async_tx()` writes the first character of each
transfer directly with `LL_USART_TransmitData8()` without waiting for TXE, so it overwrites the last
character of the banner, which `printk()` has just written to the same UART by polling. Without the
banner the output is clean. That code is unchanged by the PR. The RX-enable loops, which are what
the PR fixes, are intact with the PR and corrupted on `main`.

## What was not tested

- Current consumption. Entry into the low-power state is confirmed by `test_uart_pm_light_sleep` (PM notifier), not by measurement.
- RX in STOP with USART2 set up as a wakeup source (`wakeup-source`, HSI16 kernel clock).

## Logs

`logs/nucleo_h563zi/`:

- check app: `{base,pr}_app_nopm.log`, `{base,pr}_app_pm.log`
- sample: `{base,pr}_sample.log`
- in-tree test, USART2: `{base,pr}_zt_usart2.log`
- device PM: `{base,pr}_zt_usart2_pm.log`, `pr_zt_usart2_pm_no_power_states.log`,
  `{base,pr}_sample_pm.log`, `pr_sample_pm_{2,3}.log`, `pr_sample_pm_nobanner_{1,2}.log`
- in-tree test, LPUART1 (first overlay): `{base,pr}_zt_lpuart1.log`,
  `pr_zt_lpuart1_fifo_enable.log`, `pr_zt_lpuart1_long_buf_debug.log`
