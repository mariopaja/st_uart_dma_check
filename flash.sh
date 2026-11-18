#!/usr/bin/env bash
# Build, flash and run uart_dma_check (or any Zephyr image) on NUCLEO-U575ZI-Q / -F429ZI / -H563ZI.
# Run ./flash.sh -h for the options.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZEPHYR_DIR="${ZEPHYR_DIR:-$(cd "$APP_DIR/../zephyr" && pwd)}"
board="nucleo_u575zi_q"
variant="nopm"
build_dir=""
do_build=0
pristine=0
tool="cubeprog"
mode="POWERDOWN"
erase=0
reset_only=0
capture=50
port="/dev/ttyACM0"
src_dir="$APP_DIR"
dry_run=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Image:
  -B BOARD     nucleo_u575zi_q | nucleo_f429zi | nucleo_h563zi |
               nucleo_h745zi_q/stm32h745xx/m7 (no PM) | nucleo_c5a3zg (cubeprog only)
                                                                 [default: $board]
  -v VARIANT   nopm | pm (device PM: pm.conf + pm/<board>.overlay if present)
                                                                 [default: $variant]
  -d DIR       build directory                                   [default: <this app>/build_<board>[_pm]]
  -s DIR       application to build with -b                      [default: this app]
  -b           build before flashing
  -P           pristine build (with -b)

Flash:
  -t TOOL      cubeprog | west | openocd | pyocd                 [default: $tool]
                 cubeprog: STM32_Programmer_CLI on the hex, never rebuilds
                 west:     west flash --no-rebuild (stm32cubeprogrammer runner)
                 openocd:  west flash --no-rebuild -r openocd
                 pyocd:    west flash --no-rebuild -r pyocd, needs the target pack once:
                           pyocd pack install stm32u575zitx (stm32f429zitx, stm32h563zitx)
  -m MODE      cubeprog connect mode: POWERDOWN | UR | NORMAL | HOTPLUG
                 [default: $mode, the only one that connects after a PM image]
  -e           full chip erase before programming (cubeprog only)
  -r           only reset the board (cubeprog), no programming

Run:
  -c SECONDS   capture the console after flashing, 0 to skip     [default: $capture]
  -p PORT      serial port                                       [default: $port]

Other:
  -n           print the commands without running them
  -h           this help

Examples:
  $(basename "$0")                     flash ./build_nucleo_u575zi_q and capture the run
  $(basename "$0") -b -v pm            build and flash the device PM variant
  $(basename "$0") -B nucleo_f429zi -b build and flash on the F429
  $(basename "$0") -d build_base -c 0  flash another build dir, no capture
  $(basename "$0") -r                  reset and capture the run again
  $(basename "$0") -e -m UR            erase the chip, connect under reset
EOF
}

while getopts "B:v:d:s:bPt:m:erc:p:nh" opt; do
	case "$opt" in
	B) board="$OPTARG" ;;
	v) variant="$OPTARG" ;;
	d) build_dir="$OPTARG" ;;
	s) src_dir="$OPTARG" ;;
	b) do_build=1 ;;
	P) pristine=1 ;;
	t) tool="$OPTARG" ;;
	m) mode="$OPTARG" ;;
	e) erase=1 ;;
	r) reset_only=1 ;;
	c) capture="$OPTARG" ;;
	p) port="$OPTARG" ;;
	n) dry_run=1 ;;
	h) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

case "$board" in
nucleo_u575zi_q) pyocd_target="stm32u575zitx" ;;
nucleo_f429zi) pyocd_target="stm32f429zitx" ;;
nucleo_h563zi) pyocd_target="stm32h563zitx" ;;
nucleo_h745zi_q/stm32h745xx/m7) pyocd_target="stm32h745zitx" ;;
nucleo_c5a3zg) pyocd_target="" ;;
nucleo_h7s3l8) pyocd_target="stm32h7s3l8hx" ;;
nucleo_f767zi) pyocd_target="stm32f767zitx" ;;
nucleo_u3c5zi_q) pyocd_target="" ;;
*) echo "unknown board: $board" >&2; exit 2 ;;
esac
case "$variant" in
nopm) build_args=(-DCONFIG_PM=n) ;;
pm)
	build_args=(-DEXTRA_CONF_FILE=pm.conf)
	if [ -f "$APP_DIR/pm/$(echo "$board" | tr '/' '_').overlay" ]; then
		build_args+=("-DEXTRA_DTC_OVERLAY_FILE=pm/$(echo "$board" | tr '/' '_').overlay")
	fi
	;;
*) echo "unknown variant: $variant" >&2; exit 2 ;;
esac
case "$tool" in
cubeprog | west | openocd | pyocd) ;;
*) echo "unknown tool: $tool" >&2; exit 2 ;;
esac
if [ "$tool" = pyocd ] && [ -z "$pyocd_target" ]; then
	echo "no pyocd target for $board" >&2; exit 2
fi
case "$mode" in
POWERDOWN | UR | NORMAL | HOTPLUG) ;;
*) echo "unknown connect mode: $mode" >&2; exit 2 ;;
esac

if [ -z "$build_dir" ]; then
	build_dir="$APP_DIR/build_$(echo "$board" | tr '/' '_')"
	[ "$variant" = pm ] && build_dir="${build_dir}_pm"
fi
case "$build_dir" in
/*) ;;
*) build_dir="$PWD/$build_dir" ;;
esac

run() {
	echo "+ $*"
	if [ "$dry_run" -eq 0 ]; then
		"$@"
	fi
}

cubeprog() {
	run STM32_Programmer_CLI -c port=swd "mode=$mode" "$@"
}

# Build
if [ "$do_build" -eq 1 ] && [ "$reset_only" -eq 0 ]; then
	p=()
	[ "$pristine" -eq 1 ] && p=(-p)
	(cd "$ZEPHYR_DIR" && run west build "${p[@]}" -b "$board" "$src_dir" -d "$build_dir" \
		-- "${build_args[@]}")
fi

hex="$build_dir/zephyr/zephyr.hex"
if [ "$reset_only" -eq 0 ] && [ "$dry_run" -eq 0 ] && [ ! -f "$hex" ]; then
	echo "no image at $hex (use -b to build it)" >&2
	exit 1
fi
if [ "$reset_only" -eq 0 ] && [ -f "$build_dir/zephyr/include/generated/zephyr/version.h" ]; then
	echo "image: $(sed -n 's/^#define BUILD_VERSION //p' \
		"$build_dir/zephyr/include/generated/zephyr/version.h")"
fi

# Flash, leaving the target halted or running until the capture is listening
if [ "$reset_only" -eq 0 ]; then
	case "$tool" in
	cubeprog)
		[ "$erase" -eq 1 ] && cubeprog -e all
		cubeprog -d "$hex" -v
		;;
	west) (cd "$ZEPHYR_DIR" && run west flash -d "$build_dir" --no-rebuild) ;;
	openocd) (cd "$ZEPHYR_DIR" && run west flash -d "$build_dir" --no-rebuild -r openocd) ;;
	pyocd)
		(cd "$ZEPHYR_DIR" && run west flash -d "$build_dir" --no-rebuild -r pyocd) || {
			echo "pyocd flash failed; if the target is not recognized, run:" \
				"pyocd pack install $pyocd_target" >&2
			exit 1
		}
		;;
	esac
fi

# Capture: open the port first, then reset so the whole run is seen
if [ "$capture" != 0 ]; then
	if [ "$dry_run" -eq 1 ]; then
		echo "+ python3 $APP_DIR/run.py $capture $port"
		cubeprog -hardRst
	else
		python3 "$APP_DIR/run.py" "$capture" "$port" &
		cap_pid=$!
		sleep 1
		cubeprog -hardRst >/dev/null
		wait "$cap_pid"
	fi
elif [ "$reset_only" -eq 1 ] || [ "$tool" = cubeprog ]; then
	cubeprog -hardRst
fi
