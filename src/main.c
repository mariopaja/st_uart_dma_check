/*
 * Hardware check for the stm32 async UART TX/RX DMA changes.
 * Drives the "dut" UART (see boards/<board>.overlay) and reports, per case,
 * which TX events arrived, how long TX took, and whether a PM lock is left held.
 */
#include <zephyr/kernel.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/pm/policy.h>
#include <zephyr/sys/printk.h>
#include <stm32_ll_usart.h>

#define DUT DT_NODELABEL(dut)
#define TX_LEN 200
/* 115200 8N1: ~86.8 us per byte */
#define TX_EXPECT_US (TX_LEN * 868 / 10)

static const struct device *const dut = DEVICE_DT_GET(DUT);
static uint8_t tx_buf[TX_LEN];
static uint8_t rx_buf[2][64];
static int rx_idx;

static volatile int n_done, n_aborted, n_rx_disabled;
static volatile size_t done_len, aborted_len;
static volatile uint32_t t_done;

static void cb(const struct device *dev, struct uart_event *evt, void *user_data)
{
	switch (evt->type) {
	case UART_TX_DONE:
		n_done++;
		done_len = evt->data.tx.len;
		t_done = k_cycle_get_32();
		break;
	case UART_TX_ABORTED:
		n_aborted++;
		aborted_len = evt->data.tx.len;
		break;
	case UART_RX_BUF_REQUEST:
		uart_rx_buf_rsp(dev, rx_buf[rx_idx], sizeof(rx_buf[0]));
		rx_idx ^= 1;
		break;
	case UART_RX_DISABLED:
		n_rx_disabled++;
		break;
	default:
		break;
	}
}

static bool pm_locked(void)
{
#ifdef CONFIG_PM
	return pm_policy_state_lock_is_active(PM_STATE_SUSPEND_TO_IDLE, PM_ALL_SUBSTATES);
#else
	return false;
#endif
}

static void reset(void)
{
	n_done = 0;
	n_aborted = 0;
	done_len = 0;
	aborted_len = 0;
}

static int failures;

/* LL accessors, as the register layout differs between families (e.g. F4 vs U5) */
static void regs(const char *tag)
{
	USART_TypeDef *u = (USART_TypeDef *)DT_REG_ADDR(DUT);
#ifdef USART_ISR_TXE_TXFNF
	uint32_t txe = LL_USART_IsActiveFlag_TXE_TXFNF(u);
#else
	uint32_t txe = LL_USART_IsActiveFlag_TXE(u);
#endif

	printk("    [%s] UE=%u TE=%u TCIE=%u TC=%u TXE=%u done=%d\n", tag,
	       LL_USART_IsEnabled(u), LL_USART_GetTransferDirection(u) & LL_USART_DIRECTION_TX
				       ? 1U : 0U,
	       LL_USART_IsEnabledIT_TC(u), LL_USART_IsActiveFlag_TC(u), txe, n_done);
}

static void report(const char *name, bool ok, uint32_t t_start)
{
	uint32_t us = n_done ? k_cyc_to_us_floor32(t_done - t_start) : 0;

	printk("%-34s %s done=%d len=%u t=%uus aborted=%d len=%u pm_lock=%d\n", name,
	       ok ? "PASS" : "FAIL", n_done, (unsigned int)done_len, us, n_aborted,
	       (unsigned int)aborted_len, pm_locked());
	failures += ok ? 0 : 1;
}

static void rx_on(void)
{
	rx_idx = 1;
	int rc = uart_rx_enable(dut, rx_buf[0], sizeof(rx_buf[0]), 10000);

	if (rc != 0) {
		printk("rx_enable failed %d\n", rc);
	}
}

static void rx_off(void)
{
	n_rx_disabled = 0;
	uart_rx_disable(dut);
	k_msleep(5);
}

/* Normal TX: TX_DONE with full length after the full transfer time */
static void case_plain(void)
{
	uint32_t t0;

	reset();
	t0 = k_cycle_get_32();
	uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);
	k_msleep(40);
	report("plain tx", n_done == 1 && done_len == TX_LEN && n_aborted == 0 && !pm_locked() &&
		k_cyc_to_us_floor32(t_done - t0) >= TX_EXPECT_US * 9 / 10, t0);
}

/* RX enabled while TX is running: TX must not end early */
static void case_rx_enable_during_tx(void)
{
	uint32_t t0;
	int rc;

	reset();
	t0 = k_cycle_get_32();
	uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);
	k_busy_wait(2000);
	regs("before rx_on");
	rx_on();
	regs("after rx_on");
	k_msleep(40);
	bool ok = n_done == 1 && done_len == TX_LEN &&
		  k_cyc_to_us_floor32(t_done - t0) >= TX_EXPECT_US * 9 / 10;
	report("rx_enable during tx", ok, t0);

	/* The next TX must be accepted and complete normally */
	reset();
	t0 = k_cycle_get_32();
	rc = uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);
	k_msleep(40);
	report("  next tx after it", rc == 0 && n_done == 1 && done_len == TX_LEN, t0);
	rx_off();
	k_msleep(5);
	printk("  pm_lock after rx_disable=%d\n", pm_locked());
}

/* Abort in the middle of a TX: TX_ABORTED only, PM lock released */
static void case_abort_mid(void)
{
	uint32_t t0;

	reset();
	t0 = k_cycle_get_32();
	uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);
	k_busy_wait(3000);
	regs("before abort");
	uart_tx_abort(dut);
	regs("after abort");
	k_busy_wait(1000);
	regs("abort+1ms");
	k_msleep(40);
	report("abort mid tx", n_aborted == 1 && n_done == 0 && !pm_locked(), t0);
}

/* Abort right after starting, before the first byte is out */
static void case_abort_immediate(void)
{
	uint32_t t0;

	reset();
	t0 = k_cycle_get_32();
	uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);
	uart_tx_abort(dut);
	k_msleep(40);
	report("abort immediately", n_aborted == 1 && n_done == 0 && !pm_locked(), t0);
}

/* RX enabled during TX (reset deferred), then TX aborted: deferred reset runs on abort */
static void case_rx_enable_then_abort(void)
{
	uint32_t t0;

	reset();
	t0 = k_cycle_get_32();
	uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);
	k_busy_wait(2000);
	rx_on();
	k_busy_wait(2000);
	uart_tx_abort(dut);
	k_msleep(40);
	report("rx_enable, then abort", n_aborted == 1 && n_done == 0 && !pm_locked(), t0);

	reset();
	t0 = k_cycle_get_32();
	int rc = uart_tx(dut, tx_buf, TX_LEN, SYS_FOREVER_US);

	k_msleep(40);
	report("  next tx after it", rc == 0 && n_done == 1 && done_len == TX_LEN, t0);
	rx_off();
}

/* TX timeout: the driver aborts by itself */
static void case_tx_timeout(void)
{
	uint32_t t0;

	reset();
	t0 = k_cycle_get_32();
	uart_tx(dut, tx_buf, TX_LEN, 5000);
	k_msleep(40);
	report("tx timeout (driver abort)", n_aborted == 1 && n_done == 0 && !pm_locked(), t0);
}

int main(void)
{
	for (int i = 0; i < TX_LEN; i++) {
		tx_buf[i] = 'a' + (i % 26);
	}

	uart_callback_set(dut, cb, NULL);
	k_msleep(100);
	printk("\n=== uart dma check: start pm_lock=%d ===\n", pm_locked());

	for (int round = 0; round < 3; round++) {
		printk("--- round %d\n", round);
		case_plain();
		case_rx_enable_during_tx();
		case_abort_mid();
		case_abort_immediate();
		case_rx_enable_then_abort();
		case_tx_timeout();
		case_plain();
	}

	printk("=== uart dma check: %d failures, end pm_lock=%d ===\n", failures, pm_locked());
	return 0;
}
