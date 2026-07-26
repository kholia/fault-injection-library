# Build examples/demo_py32f003.c for the PY32F003L16S6TU using
# py32f0-template.
#
# From the examples directory:
#   make -f demo_py32f003.mk
#
# Override PY32_SDK or CROSS_COMPILE when the SDK/toolchain live elsewhere:
#   make -f demo_py32f003.mk PY32_SDK=/path/to/py32f0-template
#
# Build and flash through a CMSIS-DAP adapter with pyOCD:
#   make -f demo_py32f003.mk flash
#
# If multiple probes are connected, select one by its pyOCD UID:
#   make -f demo_py32f003.mk flash PYOCD_UID=<probe-uid>
#
# Debug with GDB in two terminals. The debug target builds a separate image
# with full symbols, loads it through GDB, resets, and stops at main():
#
#   # Terminal 1
#   make -f demo_py32f003.mk debug-server
#
#   # Terminal 2
#   make -f demo_py32f003.mk debug
#
# Use debug-attach instead if the debug image is already flashed and must not
# be reprogrammed.

PROJECT       := demo
BUILD_DIR     := build/py32f003-demo
DEBUG_BUILD_DIR ?= build/py32f003-demo-debug
PY32_SDK      ?= ../../py32f0-template
CROSS_COMPILE ?= arm-none-eabi-
PYOCD         ?= pyocd
DEBUG         ?= 0

# Optional reproducible test overrides, for example:
#   make -f demo_py32f003.mk DEMO_SUPPLIED_VALUE=0xA55A1234UL
DEMO_SUPPLIED_VALUE  ?=
DEMO_PRE_BRANCH_NOPS ?=
DEMO_BRANCH_GUARD_NOPS ?=

PYOCD_TARGET    ?= py32f003x6
PYOCD_PACK      ?= $(PY32_SDK)/Misc/Puya.PY32F0xx_DFP.1.1.7.pack
PYOCD_FREQUENCY ?= 1m
PYOCD_CONNECT   ?= halt
PYOCD_UID       ?=
GDB              ?= $(CROSS_COMPILE)gdb
GDB_HOST         ?= localhost
GDB_PORT         ?= 3333
GDB_BREAK        ?= main

CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump

DEVICE_DIR := $(PY32_SDK)/Libraries/CMSIS/Device/PY32F0xx
CORE_DIR   := $(PY32_SDK)/Libraries/CMSIS/Core
LL_DIR     := $(PY32_SDK)/Libraries/PY32F0xx_LL_Driver
LDSCRIPT   := $(PY32_SDK)/Libraries/LDScripts/py32f003x6.ld

ARCH_FLAGS := -mcpu=cortex-m0plus -mthumb
CPPFLAGS   := -DPY32F003x6 \
              -I$(CORE_DIR)/Include \
              -I$(DEVICE_DIR)/Include \
              -isystem $(LL_DIR)/Inc
ifneq ($(strip $(DEMO_SUPPLIED_VALUE)),)
CPPFLAGS   += -DDEMO_SUPPLIED_VALUE=$(DEMO_SUPPLIED_VALUE)
endif
ifneq ($(strip $(DEMO_PRE_BRANCH_NOPS)),)
CPPFLAGS   += -DDEMO_PRE_BRANCH_NOPS=$(DEMO_PRE_BRANCH_NOPS)
endif
ifneq ($(strip $(DEMO_BRANCH_GUARD_NOPS)),)
CPPFLAGS   += -DDEMO_BRANCH_GUARD_NOPS=$(DEMO_BRANCH_GUARD_NOPS)
endif
ifeq ($(DEBUG),1)
# -Og/-O1 produce an out-of-range Thumb conditional branch across the inline
# 128-NOP sled with GCC 13. Keep the production layout and retain frame
# pointers for reliable backtraces instead of changing the debug firmware.
OPT_FLAGS  := -Os -fno-omit-frame-pointer
else
OPT_FLAGS  := -Os
endif
CFLAGS     := $(ARCH_FLAGS) -std=c17 $(OPT_FLAGS) -g3 -Wall -Wextra \
              -ffunction-sections -fdata-sections
ASFLAGS    := $(ARCH_FLAGS) -g3
LDFLAGS    := $(ARCH_FLAGS) -specs=nano.specs -specs=nosys.specs \
              -Wl,--gc-sections \
              -Wl,-Map=$(BUILD_DIR)/$(PROJECT).map \
              -T$(LDSCRIPT)

OBJECTS := $(BUILD_DIR)/demo.o \
           $(BUILD_DIR)/system_py32f0xx.o \
           $(BUILD_DIR)/startup_py32f003.o

.PHONY: all clean check-sdk check-flash check-debug flash \
        debug-build debug-server debug debug-attach

all: check-sdk \
     $(BUILD_DIR)/$(PROJECT).elf \
     $(BUILD_DIR)/$(PROJECT).bin \
     $(BUILD_DIR)/$(PROJECT).hex \
     $(BUILD_DIR)/$(PROJECT).lst

check-sdk:
	@test -f "$(DEVICE_DIR)/Include/py32f0xx.h" || { \
		echo "PY32 SDK not found at $(PY32_SDK)" >&2; \
		exit 1; \
	}
	@test -f "$(LL_DIR)/Inc/py32f0xx_ll_gpio.h" || { \
		echo "PY32 LL driver not found at $(LL_DIR)" >&2; \
		exit 1; \
	}

check-flash: check-sdk
	@command -v "$(PYOCD)" >/dev/null || { \
		echo "pyOCD not found: $(PYOCD)" >&2; \
		exit 1; \
	}
	@test -f "$(PYOCD_PACK)" || { \
		echo "Puya CMSIS-Pack not found at $(PYOCD_PACK)" >&2; \
		exit 1; \
	}

check-debug: check-flash
	@command -v "$(GDB)" >/dev/null || { \
		echo "Arm GDB not found: $(GDB)" >&2; \
		exit 1; \
	}

$(BUILD_DIR):
	@mkdir -p $@

$(BUILD_DIR)/demo.o: demo_py32f003.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/system_py32f0xx.o: $(DEVICE_DIR)/Source/system_py32f0xx.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/startup_py32f003.o: $(DEVICE_DIR)/Source/gcc/startup_py32f003.s | $(BUILD_DIR)
	$(CC) $(ASFLAGS) -c $< -o $@

$(BUILD_DIR)/$(PROJECT).elf: $(OBJECTS) $(LDSCRIPT)
	$(CC) $(LDFLAGS) $(OBJECTS) -o $@

$(BUILD_DIR)/$(PROJECT).bin: $(BUILD_DIR)/$(PROJECT).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD_DIR)/$(PROJECT).hex: $(BUILD_DIR)/$(PROJECT).elf
	$(OBJCOPY) -O ihex $< $@

$(BUILD_DIR)/$(PROJECT).lst: $(BUILD_DIR)/$(PROJECT).elf
	$(OBJDUMP) --source --disassemble $< > $@

flash: check-flash $(BUILD_DIR)/$(PROJECT).elf
	$(PYOCD) load "$(BUILD_DIR)/$(PROJECT).elf" \
		--target "$(PYOCD_TARGET)" \
		--pack "$(PYOCD_PACK)" \
		--frequency "$(PYOCD_FREQUENCY)" \
		--connect "$(PYOCD_CONNECT)" \
		--erase chip $(if $(strip $(PYOCD_UID)),--uid "$(PYOCD_UID)")

# Build debugging objects separately so debug and production objects never mix.
debug-build:
	$(MAKE) -f "$(lastword $(MAKEFILE_LIST))" \
		BUILD_DIR="$(DEBUG_BUILD_DIR)" DEBUG=1 all

# Keep this foreground server running in terminal 1 while using debug or
# debug-attach from terminal 2.
debug-server: check-flash debug-build
	$(PYOCD) gdbserver \
		--target "$(PYOCD_TARGET)" \
		--pack "$(PYOCD_PACK)" \
		--frequency "$(PYOCD_FREQUENCY)" \
		--connect "$(PYOCD_CONNECT)" \
		--port "$(GDB_PORT)" \
		$(if $(strip $(PYOCD_UID)),--uid "$(PYOCD_UID)")

# Load the exact debug ELF, reset the MCU, and stop at GDB_BREAK (main by
# default). This intentionally reprograms flash.
debug: check-debug debug-build
	$(GDB) "$(DEBUG_BUILD_DIR)/$(PROJECT).elf" \
		-ex "set mem inaccessible-by-default off" \
		-ex "target extended-remote $(GDB_HOST):$(GDB_PORT)" \
		-ex "monitor reset halt" \
		-ex "load" \
		-ex "monitor reset halt" \
		-ex "break $(GDB_BREAK)" \
		-ex "continue"

# Attach with symbols and halt without loading or resetting the target.
debug-attach: check-debug debug-build
	$(GDB) "$(DEBUG_BUILD_DIR)/$(PROJECT).elf" \
		-ex "set mem inaccessible-by-default off" \
		-ex "target extended-remote $(GDB_HOST):$(GDB_PORT)" \
		-ex "monitor halt"

clean:
	$(RM) -r -- $(BUILD_DIR) $(DEBUG_BUILD_DIR)
