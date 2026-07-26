#include <stdint.h>

#include "py32f0xx.h"
#include "py32f0xx_ll_bus.h"
#include "py32f0xx_ll_gpio.h"
#include "py32f0xx_ll_rcc.h"
#include "py32f0xx_ll_system.h"

/*
 * Deliberately vulnerable PY32F003L16S6TU voltage-glitch target.
 * See demo_py32f003.md for the complete SOP-8 pinout and wiring.
 *
 * PA0 / package pin 2: trigger
 * PA1 / package pin 3: success
 * PA2 / package pin 4: normal failure
 *
 * Marker protocol:
 *   PA1=1, PA2=0: vulnerable check returned success
 *   PA1=0, PA2=1: vulnerable check returned failure
 *   PA1=1, PA2=1: the target has just booted or rebooted
 *
 * The dual-high boot marker lets glitch_sweep_py32_gpio.py distinguish a
 * brown-out reset from the failure marker emitted by the next execution.
 */

#define PIN_TRIGGER LL_GPIO_PIN_0
#define PIN_SUCCESS LL_GPIO_PIN_1
#define PIN_FAIL    LL_GPIO_PIN_2
#define OUTPUT_PINS (PIN_TRIGGER | PIN_SUCCESS | PIN_FAIL)

#define DEMO_CORE_CLOCK_HZ       24000000UL
#define DEMO_DELAY_LOOPS_PER_MS  (DEMO_CORE_CLOCK_HZ / 3000UL)

/*
 * Build with -DDEMO_SUPPLIED_VALUE=0xA55A1234UL for a positive-control image.
 * That image must pulse PIN_SUCCESS without requiring a successful glitch.
 */
#ifndef DEMO_SUPPLIED_VALUE
#define DEMO_SUPPLIED_VALUE 0xDEADBEEFUL
#endif

/*
 * A fixed assembly NOP sled gives the glitcher several microseconds to react
 * to the trigger. At 24 MHz, 128 NOPs take about 5.33 us, matching the
 * trigger-to-operand-load delay of the 48 MHz CH32V003 demo. Unlike a C delay
 * loop, its timing does not depend on optimization or loop overhead.
 */
#ifndef DEMO_PRE_BRANCH_NOPS
#define DEMO_PRE_BRANCH_NOPS 128
#endif

/*
 * Sacrificial instructions around BNE. This must be even so BNE and the
 * success MOVS remain on four-byte boundaries with the layout below.
 */
#ifndef DEMO_BRANCH_GUARD_NOPS
#define DEMO_BRANCH_GUARD_NOPS 16
#endif

#if (DEMO_BRANCH_GUARD_NOPS % 2) != 0
#error "DEMO_BRANCH_GUARD_NOPS must be even"
#endif

#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)

/* Prevent GCC/LTO from resolving the comparison during compilation. */
static volatile uint32_t supplied_value = DEMO_SUPPLIED_VALUE;
static volatile uint32_t expected_value = 0xA55A1234UL;

/*
 * Normal execution:
 *
 *     supplied != expected
 *     bne jumps to fail
 *     return 0
 *
 * Successful branch-skip glitch:
 *
 *     bne is skipped
 *     return 1
 *
 * Armv6-M has no register-to-register conditional branch. CMP therefore sets
 * the flags immediately before the 16-bit BNE that is the glitch target.
 */
/*
 * Isolate BNE from both the flag-producing CMP and the success-path MOVS.
 * With the function aligned to four bytes, the important instruction pairs
 * are:
 *
 *     word 0:             NOP  | CMP
 *     words 1..N:         NOP  | NOP       <- pre-target guard
 *     target word:        BNE  | NOP       <- glitch target
 *     following words:    NOP  | NOP       <- post-target guard
 *     success word:       MOVS | BX
 *
 * A disturbance of the aligned word containing BNE can therefore corrupt a
 * harmless NOP alongside it. The guard bands also tolerate corruption of
 * nearby instruction words without placing CMP or the success path in the
 * same short disturbance window. NOP does not change the condition flags, so
 * BNE still consumes the result produced by CMP.
 */
__attribute__((naked, noinline, used, aligned(4)))
static int vulnerable_check(uint32_t supplied __attribute__((unused)),
                            uint32_t expected __attribute__((unused)))
{
    __asm__ volatile(
        ".syntax unified\n"
        "nop\n"              /* Put CMP in the upper half of word 0. */
        "cmp  r0, r1\n"
        ".rept " STRINGIFY(DEMO_BRANCH_GUARD_NOPS) "\n"
        "nop\n"
        ".endr\n"
        "bne  1f\n"       /* The single glitch target. */
        "nop\n"              /* Harmless lower half of target word. */
        ".rept " STRINGIFY(DEMO_BRANCH_GUARD_NOPS) "\n"
        "nop\n"
        ".endr\n"
        "movs r0, #1\n"   /* Branch skipped: success. */
        "bx   lr\n"

        "1:\n"
        "movs r0, #0\n"   /* Normal path: failure. */
        "bx   lr\n"
    );
}

static inline void pin_set(uint32_t pin)
{
    LL_GPIO_SetOutputPin(GPIOA, pin);
}

static inline void pin_clear(uint32_t pin)
{
    LL_GPIO_ResetOutputPin(GPIOA, pin);
}

static void system_clock_init(void)
{
    /* The SOP-8 PY32F003L16S6TU is specified for a maximum 24 MHz SYSCLK. */
    LL_RCC_HSI_Enable();
    LL_RCC_HSI_SetCalibFreq(LL_RCC_HSICALIBRATION_24MHz);
    while (LL_RCC_HSI_IsReady() != 1U) {
    }

    LL_RCC_SetAHBPrescaler(LL_RCC_SYSCLK_DIV_1);
    LL_RCC_SetSysClkSource(LL_RCC_SYS_CLKSOURCE_HSISYS);
    while (LL_RCC_GetSysClkSource() != LL_RCC_SYS_CLKSOURCE_STATUS_HSISYS) {
    }

    LL_FLASH_SetLatency(LL_FLASH_LATENCY_0);
    LL_RCC_SetAPB1Prescaler(LL_RCC_APB1_DIV_1);
    SystemCoreClock = DEMO_CORE_CLOCK_HZ;
}

static void gpio_init(void)
{
    LL_IOP_GRP1_EnableClock(LL_IOP_GRP1_PERIPH_GPIOA);

    /* Establish low output levels before switching PA0..PA2 to output mode. */
    LL_GPIO_ResetOutputPin(GPIOA, OUTPUT_PINS);
    LL_GPIO_SetPinOutputType(GPIOA, OUTPUT_PINS, LL_GPIO_OUTPUT_PUSHPULL);

    LL_GPIO_SetPinSpeed(GPIOA, PIN_TRIGGER, LL_GPIO_SPEED_FREQ_HIGH);
    LL_GPIO_SetPinSpeed(GPIOA, PIN_SUCCESS, LL_GPIO_SPEED_FREQ_HIGH);
    LL_GPIO_SetPinSpeed(GPIOA, PIN_FAIL, LL_GPIO_SPEED_FREQ_HIGH);

    LL_GPIO_SetPinPull(GPIOA, PIN_TRIGGER, LL_GPIO_PULL_NO);
    LL_GPIO_SetPinPull(GPIOA, PIN_SUCCESS, LL_GPIO_PULL_NO);
    LL_GPIO_SetPinPull(GPIOA, PIN_FAIL, LL_GPIO_PULL_NO);

    LL_GPIO_SetPinMode(GPIOA, PIN_TRIGGER, LL_GPIO_MODE_OUTPUT);
    LL_GPIO_SetPinMode(GPIOA, PIN_SUCCESS, LL_GPIO_MODE_OUTPUT);
    LL_GPIO_SetPinMode(GPIOA, PIN_FAIL, LL_GPIO_MODE_OUTPUT);
}

/*
 * Keep marker timing independent of SysTick. LL_mDelay() polls SysTick's
 * one-bit COUNTFLAG and was observed to stall intermittently after reset while
 * debugging this target. A SUBS/BNE iteration takes approximately three core
 * cycles on Cortex-M0+, giving an approximately 1 ms inner loop at 24 MHz.
 * Exact millisecond accuracy is not required for the GPIO marker protocol.
 */
__attribute__((noinline))
static void delay_ms(uint32_t milliseconds)
{
    while (milliseconds-- != 0U) {
        uint32_t loops = DEMO_DELAY_LOOPS_PER_MS;

        __asm__ volatile(
            ".syntax unified\n"
            "1:\n"
            "subs %0, %0, #1\n"
            "bne 1b\n"
            : "+l"(loops)
            :
            : "cc", "memory"
        );
    }
}

static void signal_boot(void)
{
    /* Dual-high is reserved for a boot/reset indication. */
    pin_set(PIN_SUCCESS | PIN_FAIL);
    delay_ms(20);
    pin_clear(PIN_SUCCESS | PIN_FAIL);
    delay_ms(5);
}

int main(void)
{
    /* The SDK startup code calls SystemInit() before entering main(). */
    system_clock_init();
    gpio_init();
    signal_boot();

    while (1) {
        pin_clear(PIN_SUCCESS | PIN_FAIL);

        /* Trigger before a deterministic pre-branch timing window. */
        pin_set(PIN_TRIGGER);

        __asm__ volatile(
            ".rept " STRINGIFY(DEMO_PRE_BRANCH_NOPS) "\n"
            "nop\n"
            ".endr\n"
            ::: "memory"
        );

        int ok = vulnerable_check(supplied_value, expected_value);

        pin_clear(PIN_TRIGGER);

        if (ok != 0) {
            pin_set(PIN_SUCCESS);
            delay_ms(20);
            pin_clear(PIN_SUCCESS);
        } else {
            pin_set(PIN_FAIL);
            delay_ms(20);
            pin_clear(PIN_FAIL);
        }

        delay_ms(20);
    }
}
