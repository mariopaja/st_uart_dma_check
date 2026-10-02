# STM32 LPUART: async RX timeout counts from the IDLE event, not from the last byte

Found while testing PR #120833 on NUCLEO-H563ZI. Present on `main` (`5075ddf1460`) and on the PR
branch (`67b70ed6bef`) with identical results, so it is not caused by the PR.

## Summary

With the async API on an LPUART instance (`IS_LPUART_INSTANCE()`), a continuous reception longer
than the RX timeout is reported as several `UART_RX_RDY` events, split every `timeout` after an
IDLE event, although data keeps arriving. The Zephyr UART API defines the `uart_rx_enable()`
timeout as inactivity time after the last received byte.

`tests/drivers/uart/uart_async_api` / `uart_async_long_buf.test_long_buffers` fails because of it.

## Environment

| | |
|---|---|
| Board | NUCLEO-H563ZI (STM32H563ZI) |
| UART | LPUART1, Arduino D1 (PB6, TX) to D0 (PB7, RX) loopback, 115200 baud |
| DMA | GPDMA1, TX ch 0 / request 46, RX ch 1 / request 45 |
| Test | `tests/drivers/uart/uart_async_api`, scenario `drivers.uart.async_api` |

Overlay used (`tests/drivers/uart/uart_async_api/boards/nucleo_h563zi.overlay` at the time):

```dts
dut: &lpuart1 {
	dmas = <&gpdma1 0 46 STM32_DMA_PERIPH_TX>,
	       <&gpdma1 1 45 STM32_DMA_PERIPH_RX>;
	dma-names = "tx", "rx";
};
```

## Reproduce

1. Use the overlay above and connect PB6 to PB7.
2. `west build -p -b nucleo_h563zi tests/drivers/uart/uart_async_api`, flash, read the console.

## Observed

| Build | Result |
|---|---|
| `main`, LPUART1 | 9/10, `test_long_buffers` FAIL |
| PR, LPUART1 | 9/10, `test_long_buffers` FAIL |
| PR, LPUART1 with `fifo-enable;` | 9/10, `test_long_buffers` FAIL |
| `main` and PR, USART2 (PD5/PD6, GPDMA1 requests 24/23) | 10/10 |

```
Assertion failed at .../test_uart_async.c:1070: uart_async_long_buf_test_long_buffers:
(long_received[0] not equal to tx_len1)
```

The test sends 508 bytes (`TX_LONG_BUFFER / 2`) after `uart_rx_enable(..., 10 * USEC_PER_MSEC)`
into a 1024-byte buffer and expects one RX_RDY of 508 bytes. A debug copy of the test printed:

```
LONG_BUF tx_len1=508 rx_events=2 rx[0]=115 rx[1]=393 buf=1024
```

All 508 bytes arrive; the first RX_RDY comes after 115 bytes, which is 115 x 86.8 us = 10.0 ms at
115200 baud, i.e. one RX timeout after the start of the transfer.

## Analysis (`drivers/serial/uart_stm32.c`)

1. `set_timeout_itr()` skips the hardware receiver timeout for LPUART instances and enables the
   IDLE interrupt instead:

   ```c
   #if HAS_LPUART
   	if (IS_LPUART_INSTANCE(usart)) {
   		goto enable_idle_itr;
   	}
   #endif
   ```

   The same IDLE path is taken on a USART when `timeout == SYS_FOREVER_US`, when the timeout does
   not fit the RTO register, or when the instance has no RTO (`LL_USART_GetRxTimeout() == 0`).

2. On IDLE, `uart_stm32_isr()` starts a one-shot software timer with the full RX timeout:

   ```c
   if (LL_USART_IsEnabledIT_IDLE(usart) && LL_USART_IsActiveFlag_IDLE(usart)) {
   	LL_USART_ClearFlag_IDLE(usart);
   	...
   	if (data->dma_rx.timeout == 0) {
   		uart_stm32_dma_rx_flush(dev);
   	} else {
   		async_timer_start(&data->dma_rx.timeout_work, data->dma_rx.timeout);
   	}
   }
   ```

3. When the timer expires, `uart_stm32_async_rx_timeout()` flushes what has been received so far.
   Reception is done by DMA, so no interrupt restarts or cancels the timer when bytes arrive again
   after the IDLE event.

So once an IDLE event occurs, RX_RDY is reported `timeout` later whether or not the line went
quiet. In this run the IDLE event came at the very start of the transfer (the split point is
exactly one timeout in); what produced that IDLE event (for example a short gap on the line before
or between the first bytes) was not determined, as no logic analyzer was used.

On USART instances with a supported timeout the hardware RTO counts bit times since the last
received character, which matches the API; `test_long_buffers` passes there (NUCLEO-H563ZI USART2,
NUCLEO-U575ZI-Q USART2, NUCLEO-F429ZI USART6).

## Possibly affected

- Every STM32 LPUART used with the async API and a finite RX timeout.
- In-tree `uart_async_api` overlays with an LPUART `dut`: `nucleo_wb55rg`, `nucleo_u385rg_q`,
  `nucleo_wba55cg`. Not run; whether `test_long_buffers` fails there was not checked.

## Possible fix directions (not implemented or tested)

- In `uart_stm32_async_rx_timeout()`, compare the DMA RX position with the one seen when the timer
  was started and, if data arrived meanwhile, re-arm the timer instead of flushing.
- Or cancel the timer when reception resumes (would need an RX activity interrupt, which the DMA
  path does not have today).

## Logs

`logs/nucleo_h563zi/`: `base_zt_lpuart1.log`, `pr_zt_lpuart1.log`,
`pr_zt_lpuart1_fifo_enable.log`, `pr_zt_lpuart1_long_buf_debug.log` (LPUART1 runs);
`base_zt_usart2.log`, `pr_zt_usart2.log` (USART2 runs).
