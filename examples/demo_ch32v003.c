#include <stdint.h>
#include "ch32fun.h"

/*
 * Deliberately vulnerable CH32V003 voltage-glitch target.
 *
 * PC1: trigger
 * PC2: success
 * PC4: normal failure
 *
 * Marker protocol:
 *   PC2=1, PC4=0: vulnerable check returned success
 *   PC2=0, PC4=1: vulnerable check returned failure
 *   PC2=1, PC4=1: the target has just booted or rebooted
 *
 * The dual-high boot marker lets glitch_sweep_ch32_gpio.py distinguish a
 * brown-out reset from the failure marker emitted by the next execution.
 */

#define PIN_TRIGGER PC1
#define PIN_SUCCESS PC2
#define PIN_FAIL    PC4

/*
 * Build with -DDEMO_SUPPLIED_VALUE=0xA55A1234u for a positive-control image.
 * That image must pulse PIN_SUCCESS without requiring a successful glitch.
 */
#ifndef DEMO_SUPPLIED_VALUE
#define DEMO_SUPPLIED_VALUE 0xDEADBEEFu
#endif

/*
 * A fixed assembly NOP sled gives the glitcher several microseconds to react
 * to the trigger. At 48 MHz, 256 NOPs take about 5.33 us. Unlike a C delay
 * loop, the timing does not depend on optimization or loop overhead.
 */
#ifndef DEMO_PRE_BRANCH_NOPS
#define DEMO_PRE_BRANCH_NOPS 256
#endif

#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)

/*
 * Volatile values prevent GCC/LTO from resolving the comparison
 * during compilation.
 */
static volatile uint32_t supplied_value = DEMO_SUPPLIED_VALUE;
static volatile uint32_t expected_value = 0xA55A1234u;

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
 */
__attribute__((naked, noinline, used))
static int vulnerable_check(uint32_t supplied, uint32_t expected)
{
    __asm__ volatile(
        "bne a0, a1, 1f\n"  /* The single glitch target */
        "li  a0, 1\n"       /* Branch skipped: success */
        "ret\n"

        "1:\n"
        "li  a0, 0\n"       /* Normal path: failure */
        "ret\n"
    );
}

static void gpio_init(void)
{
    funGpioInitAll();

    funPinMode(PIN_TRIGGER, GPIO_Speed_10MHz | GPIO_CNF_OUT_PP);
    funPinMode(PIN_SUCCESS, GPIO_Speed_10MHz | GPIO_CNF_OUT_PP);
    funPinMode(PIN_FAIL,    GPIO_Speed_10MHz | GPIO_CNF_OUT_PP);

    funDigitalWrite(PIN_TRIGGER, FUN_LOW);
    funDigitalWrite(PIN_SUCCESS, FUN_LOW);
    funDigitalWrite(PIN_FAIL,    FUN_LOW);
}

static void signal_boot(void)
{
    /* Dual-high is reserved for a boot/reset indication. */
    funDigitalWrite(PIN_SUCCESS, FUN_HIGH);
    funDigitalWrite(PIN_FAIL, FUN_HIGH);
    Delay_Ms(20);
    funDigitalWrite(PIN_SUCCESS, FUN_LOW);
    funDigitalWrite(PIN_FAIL, FUN_LOW);
    Delay_Ms(5);
}

int main(void)
{
    SystemInit();
    gpio_init();
    signal_boot();

    while (1) {
        funDigitalWrite(PIN_SUCCESS, FUN_LOW);
        funDigitalWrite(PIN_FAIL, FUN_LOW);

        /* Trigger before a deterministic pre-branch timing window. */
        funDigitalWrite(PIN_TRIGGER, FUN_HIGH);

        __asm__ volatile(
            ".rept " STRINGIFY(DEMO_PRE_BRANCH_NOPS) "\n"
            "nop\n"
            ".endr\n"
            ::: "memory"
        );

        int ok = vulnerable_check(supplied_value, expected_value);

        funDigitalWrite(PIN_TRIGGER, FUN_LOW);

        if (ok) {
            funDigitalWrite(PIN_SUCCESS, FUN_HIGH);
            Delay_Ms(20);
            funDigitalWrite(PIN_SUCCESS, FUN_LOW);
        } else {
            funDigitalWrite(PIN_FAIL, FUN_HIGH);
            Delay_Ms(20);
            funDigitalWrite(PIN_FAIL, FUN_LOW);
        }

        Delay_Ms(20);
    }
}
