# Copyright (C) 2024 Dr. Matthias Kesenheimer - All Rights Reserved.
# You may use, distribute and modify this code under the terms of the GPL3 license.
#
# You should have received a copy of the GPL3 license with this file.
# If not, please write to: info@faultyhardware.de.

import ujson
from rp2 import PIO

# load config
with open("config.json", "r") as file:
    config = ujson.load(file)

if config["hardware_version"][0] == 0:
    # SimpleGlitcher v0 (RP2350 based)
    VTARGET_SWITCH = config.get("vtarget_switch", "TPS2051B")
    if VTARGET_SWITCH == "TPS2051B":
        VTARGET_ACTIVE_HIGH = True
    elif VTARGET_SWITCH == "TPS2041B":
        VTARGET_ACTIVE_HIGH = False
    else:
        raise Exception(f"VTARGET switch {VTARGET_SWITCH} not implemented.")
    RESET = 0
    # GPIO2 is not connected on the SimpleGlitcher and is used as the
    # PIO side-set pin expected by the common glitch state machines.
    GLITCH_EN = 2
    # Third, user-selectable glitch MOSFET ("UGLITCH" in the schematic).
    EXT_GLITCH = 3
    HP_GLITCH = 16
    LP_GLITCH = 17
    TRIGGER = 18
    # GPIO19 is unconnected and retained as the optional alternate input.
    ALT_TRIGGER = 19
    VTARGET_EN = 20
    VTARGET_OC = 21
    # Dummy values required when Statemachines.py defines the multiplexing
    # state machines. The SimpleGlitcher has no voltage multiplexer.
    MUX0_PIO_INIT = None
    MUX1_PIO_INIT = None
    MUX_PIO_INIT = 0b00

elif config["hardware_version"][0] == 1:
    VTARGET_ACTIVE_HIGH = False
    # Trigger 1 (without level shifter)
    ALT_TRIGGER = 18
    # Trigger 2 (with level shifter)
    TRIGGER = 15
    VTARGET_OC = 21
    VTARGET_EN = 20
    RESET = 0
    GLITCH_EN = 1
    HP_GLITCH = 16
    LP_GLITCH = 17
    EXT_GLITCH = 19
    # added as dummy variables to fix undefined variable error
    MUX0_PIO_INIT = None
    MUX1_PIO_INIT = None
    MUX_PIO_INIT = 0b00

elif config["hardware_version"][0] == 2 or config["hardware_version"][0] == 3:
    VTARGET_ACTIVE_HIGH = config["hardware_version"][0] == 3 or config["hardware_version"][1] >= 3
    TRIGGER = 14
    # alternative trigger on EXT1
    ALT_TRIGGER = 11
    VTARGET_EN = 22
    RESET = 2
    GLITCH_EN = 3
    HP_GLITCH = 12
    HP_GLITCH_LED = 8
    LP_GLITCH = 13
    LP_GLITCH_LED = 7
    EXT_GLITCH = 19
    MUX0 = 1
    MUX1 = 0
    EXT1 = 11
    EXT2 = 10

    if config["mux_vinit"] == "GND":
        MUX1_INIT = 1
        MUX0_INIT = 1
        MUX1_PIO_INIT = PIO.OUT_HIGH
        MUX0_PIO_INIT = PIO.OUT_HIGH
        MUX_PIO_INIT = 0b11

    elif config["mux_vinit"] == "VI1" or config["mux_vinit"] == "VCC":
        MUX1_INIT = 0
        MUX0_INIT = 0
        MUX1_PIO_INIT = PIO.OUT_LOW
        MUX0_PIO_INIT = PIO.OUT_LOW
        MUX_PIO_INIT = 0b00

    elif config["mux_vinit"] == "1.8":
        MUX1_INIT = 1
        MUX0_INIT = 0
        MUX1_PIO_INIT = PIO.OUT_HIGH
        MUX0_PIO_INIT = PIO.OUT_LOW
        MUX_PIO_INIT = 0b01

    else: # 3.3 or VI2
        MUX1_INIT = 0
        MUX0_INIT = 1
        MUX1_PIO_INIT = PIO.OUT_LOW
        MUX0_PIO_INIT = PIO.OUT_HIGH
        MUX_PIO_INIT = 0b10

# FastADC config
if config["hardware_version"][0] == 2:
    PADS_BANK0_BASE = 0x4001c000 # S. 301, rp2040-datahseet.pdf
    ADC_BASE = 0x4004c000 # S. 25, rp2040-datahseet.pdf

elif config["hardware_version"][0] == 0 or config["hardware_version"][0] == 3:
    PADS_BANK0_BASE = 0x40038000 # S. 786, rp2350-datahseet.pdf
    ADC_BASE = 0x400a0000 # S. 32, rp2350-datahseet.pdf
