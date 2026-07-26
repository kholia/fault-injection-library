#!/usr/bin/env bash
#
# Control a Rigol DS1054Z over its SCPI/LXI TCP socket.
#
# Default probe arrangement for the SimpleGlitcher:
#   CH1 -> GLITCH (target supply, after the 10 ohm resistor)
#   CH2, CH3, CH4 -> disabled to retain the full sample rate
#   Probe ground -> board GND
#
# Override the connection without editing this file:
#   RIGOL_IP=192.168.1.33 RIGOL_PORT=5555 ./rigol-ds1054z.sh measure

set -euo pipefail

scope_ip="${RIGOL_IP:-192.168.1.33}"
scope_port="${RIGOL_PORT:-5555}"
net_timeout="${RIGOL_TIMEOUT:-2}"

usage() {
    cat <<'EOF'
Usage: rigol-ds1054z.sh COMMAND [ARGUMENT]

Commands:
  id                 Identify the connected oscilloscope.
  setup              Configure a 10 ns/div, normal-acquisition capture.
  setup-peak         Configure a 10 ns/div peak-detect capture.
  setup-wide         Configure the original 500 ns/div overview capture.
  arm                Arm another single capture without changing the setup.
  status             Print the current trigger state.
  settings           Print acquisition, timebase, and channel settings.
  measure            Report CH1 pulse measurements.
  levels             Run in AUTO briefly and report the present DC levels.
  screenshot [FILE]  Save the current display as a PNG.
  capture [SECONDS]  Arm, wait for a trigger, then print the measurements.
                     The default timeout is 30 seconds.
  raw SCPI...        Send one or more custom SCPI commands.
  help               Show this help.

Environment:
  RIGOL_IP            Scope address (default: 192.168.1.33)
  RIGOL_PORT          SCPI port (default: 5555)
  RIGOL_TIMEOUT       Network timeout in seconds (default: 2)

Trigger states commonly returned by the DS1054Z:
  WAIT  waiting for the GLITCH voltage to fall through 1.6 V
  TD    triggered and stopped; the capture is ready
  AUTO  running without a qualifying trigger
EOF
}

require_netcat() {
    if ! command -v nc >/dev/null 2>&1; then
        echo "Error: OpenBSD netcat ('nc') is required." >&2
        exit 1
    fi
}

# Send each argument as one SCPI command. Queries return semicolon-separated
# replies on the DS1054Z; write-only commands produce no output.
scpi() {
    printf '%s\n' "$@" | nc -w "$net_timeout" "$scope_ip" "$scope_port"
}

write_scpi() {
    scpi "$@" >/dev/null
}

print_measurements() {
    local reply
    local ch1_max ch1_min ch1_width

    reply="$(scpi \
        ':MEAS:ITEM? VMAX,CHAN1' \
        ':MEAS:ITEM? VMIN,CHAN1' \
        ':MEAS:ITEM? NWID,CHAN1')"

    IFS=';' read -r ch1_max ch1_min ch1_width <<<"$reply"

    printf 'CH1 maximum:            %s V\n' "${ch1_max:-n/a}"
    printf 'CH1 minimum:            %s V\n' "${ch1_min:-n/a}"
    printf 'CH1 negative width:     %s s\n' "${ch1_width:-n/a}"
}

setup_scope() {
    local acquisition="$1"
    local time_scale="$2"
    local profile="$3"

    write_scpi \
        ':STOP' \
        ':CHAN1:DISP 1' \
        ':CHAN1:COUP DC' \
        ':CHAN1:BWL OFF' \
        ':CHAN1:SCAL 1' \
        ':CHAN1:OFFS 0' \
        ':CHAN2:DISP 0' \
        ':CHAN3:DISP 0' \
        ':CHAN4:DISP 0' \
        ":ACQ:TYPE ${acquisition}" \
        ':ACQ:MDEP AUTO' \
        ":TIM:SCAL ${time_scale}" \
        ':TIM:OFFS 0' \
        ':TRIG:MODE EDGE' \
        ':TRIG:EDGE:SOUR CHAN1' \
        ':TRIG:EDGE:SLOP NEG' \
        ':TRIG:EDGE:LEV 1.6' \
        ':TRIG:SWE SING' \
        ':SING'

    echo "Scope configured for ${profile} and armed."
    echo "Trigger: CH1 falling edge at 1.6 V."
}

print_settings() {
    local reply
    local acquisition memory_depth sample_rate time_scale time_offset
    local ch1_enabled ch2_enabled ch3_enabled ch4_enabled trigger_source

    reply="$(scpi \
        ':ACQ:TYPE?' \
        ':ACQ:MDEP?' \
        ':ACQ:SRAT?' \
        ':TIM:SCAL?' \
        ':TIM:OFFS?' \
        ':CHAN1:DISP?' \
        ':CHAN2:DISP?' \
        ':CHAN3:DISP?' \
        ':CHAN4:DISP?' \
        ':TRIG:EDGE:SOUR?')"

    IFS=';' read -r \
        acquisition memory_depth sample_rate time_scale time_offset \
        ch1_enabled ch2_enabled ch3_enabled ch4_enabled trigger_source \
        <<<"$reply"

    printf 'Acquisition type:       %s\n' "${acquisition:-n/a}"
    printf 'Memory depth:           %s\n' "${memory_depth:-n/a}"
    printf 'Sample rate:            %s Sa/s\n' "${sample_rate:-n/a}"
    printf 'Horizontal scale:       %s s/div\n' "${time_scale:-n/a}"
    printf 'Horizontal offset:      %s s\n' "${time_offset:-n/a}"
    printf 'Channels 1/2/3/4:       %s / %s / %s / %s\n' \
        "${ch1_enabled:-n/a}" "${ch2_enabled:-n/a}" \
        "${ch3_enabled:-n/a}" "${ch4_enabled:-n/a}"
    printf 'Edge-trigger source:    %s\n' "${trigger_source:-n/a}"
}

show_levels() {
    local reply
    local ch1_avg ch1_max ch1_min ch2_avg ch2_max ch2_min

    write_scpi ':TRIG:SWE AUTO' ':RUN'
    sleep 0.5

    reply="$(scpi \
        ':MEAS:ITEM? VAVG,CHAN1' \
        ':MEAS:ITEM? VMAX,CHAN1' \
        ':MEAS:ITEM? VMIN,CHAN1' \
        ':MEAS:ITEM? VAVG,CHAN2' \
        ':MEAS:ITEM? VMAX,CHAN2' \
        ':MEAS:ITEM? VMIN,CHAN2')"

    IFS=';' read -r \
        ch1_avg ch1_max ch1_min ch2_avg ch2_max ch2_min <<<"$reply"

    printf 'CH1 average/max/min: %s / %s / %s V\n' \
        "${ch1_avg:-n/a}" "${ch1_max:-n/a}" "${ch1_min:-n/a}"
    printf 'CH2 average/max/min: %s / %s / %s V\n' \
        "${ch2_avg:-n/a}" "${ch2_max:-n/a}" "${ch2_min:-n/a}"
    echo "Scope remains in AUTO/RUN mode; use 'arm' for the next single capture."
}

save_screenshot() {
    local output_file="${1:-rigol-$(date +%Y%m%d-%H%M%S).png}"

    if [[ -e "$output_file" ]]; then
        echo "Error: refusing to overwrite '$output_file'." >&2
        exit 2
    fi

    # DS1054Z PNG data is prefixed by an IEEE 488.2 block header:
    # "#9" followed by a nine-digit payload length.
    printf '%s\n' ':DISP:DATA? ON,OFF,PNG' |
        nc -w 10 "$scope_ip" "$scope_port" |
        dd bs=1 skip=11 of="$output_file" status=none

    echo "Saved screenshot to $output_file"
}

capture_once() {
    local wait_seconds="${1:-30}"
    local start_seconds="$SECONDS"
    local state

    if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]] || ((wait_seconds < 1)); then
        echo "Error: capture timeout must be a positive integer." >&2
        exit 2
    fi

    write_scpi ':STOP' ':TRIG:SWE SING' ':SING'
    echo "Armed; waiting up to ${wait_seconds}s for CH1 to fall through 1.6 V..."

    while ((SECONDS - start_seconds < wait_seconds)); do
        state="$(scpi ':TRIG:STAT?' | tr -d '\r\n;')"
        if [[ "$state" == "TD" || "$state" == "STOP" ]]; then
            echo "Capture complete (trigger state: $state)."
            print_measurements
            return
        fi
        sleep 0.25
    done

    echo "Timed out waiting for a trigger. Last state: ${state:-unknown}" >&2
    exit 3
}

require_netcat

command="${1:-help}"
case "$command" in
    id)
        scpi '*IDN?'
        ;;
    setup)
        # At 10 ns/div, a 5 ns glitch occupies half a horizontal division.
        # Normal acquisition retains the highest real-time sample rate.
        setup_scope NORM 1e-8 '5 ns pulses (normal acquisition, 10 ns/div)'
        ;;
    setup-peak)
        # Peak detect can expose a narrow excursion that falls between display
        # samples, at the cost of a lower reported sample rate on the DS1054Z.
        setup_scope PEAK 1e-8 '5 ns pulses (peak detect, 10 ns/div)'
        ;;
    setup-wide)
        setup_scope NORM 5e-7 'overview captures (normal acquisition, 500 ns/div)'
        ;;
    arm)
        write_scpi ':STOP' ':TRIG:SWE SING' ':SING'
        echo "Armed for a single CH1 falling-edge capture at 1.6 V."
        ;;
    status)
        scpi ':TRIG:STAT?'
        ;;
    settings)
        print_settings
        ;;
    measure)
        print_measurements
        ;;
    levels)
        show_levels
        ;;
    screenshot)
        save_screenshot "${2:-}"
        ;;
    capture)
        capture_once "${2:-30}"
        ;;
    raw)
        shift
        if (($# == 0)); then
            echo "Error: raw requires at least one SCPI command." >&2
            exit 2
        fi
        scpi "$@"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "Error: unknown command '$command'." >&2
        usage >&2
        exit 2
        ;;
esac
