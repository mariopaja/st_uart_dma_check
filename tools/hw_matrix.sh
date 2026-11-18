#!/bin/bash
# Base-vs-PR hardware matrix for one board: {base,pr} x {app,sample,zt} x {nopm,pm}.
# Builds, flashes (STM32_Programmer_CLI, no rebuild), captures /dev/ttyACM0, prints one line each.
#
# Usage: tools/hw_matrix.sh BOARD [BASE_REF]   (BASE_REF default: main)
# Jumpers: app = dut pins (README table), zt = PD5-PD6 except F429 (PG14-PG9).
# Output: build_matrix/<board>/{*.log,summary.txt}
set -u
board=$1; ref=${2:-main}
A=$(cd "$(dirname "$0")/.." && pwd); W=/home/mario/zephyrproject; PRZ=$W/zephyr
T=$PRZ/tests/drivers/uart/uart_async_api; SMP=$PRZ/samples/drivers/uart/async_api
bb=${board//\//_}; O=$A/build_matrix/$bb; BZ=$A/build_matrix/zephyr_base
mkdir -p "$O"; cd "$W"  # west needs the workspace

# base tree: a worktree of the zephyr repo at $ref
if [ ! -d "$BZ" ]; then git -C "$PRZ" worktree add -f "$BZ" "$ref" >/dev/null || exit 1
else git -C "$BZ" checkout -q --detach "$ref" || exit 1; fi
MODS="$(west list -f '{abspath}' | grep -v /zephyr$ | paste -sd';')"

zov=$bb
types="app sample zt"; [ "$bb" = nucleo_h7s3l8 ] && types="app sample"  # ztest overflows its 64 KB internal flash
variants="nopm pm"; [[ $board == *h7* || $board == *f7* ]] && variants=nopm  # no PM on H7 / H7RS / F7

cube() { STM32_Programmer_CLI -c port=swd mode=POWERDOWN "$@"; }  # POWERDOWN reaches the U575 after PM images
# -halt after -w: POWERDOWN leaves the new image running, its output would precede the reset run

: > "$O/summary.txt"
for v in $variants; do for t in $types; do for tree in base pr; do
	n=${tree}_${t}_$v; d=$O/b_$n; a=()
	case $t in
	app) src=$A; [ $v = pm ] && { a+=(-DEXTRA_CONF_FILE=$A/pm.conf)
		[ -f $A/pm/$bb.overlay ] && a+=(-DEXTRA_DTC_OVERLAY_FILE=$A/pm/$bb.overlay); } ;;
	sample|zt) # sources are unchanged by the PR; the PR tree's overlays are used for both builds
		[ $t = sample ] && { src=$SMP; ov=$SMP/boards/$bb; a+=(-DCONFIG_LOG=n); } || { src=$T; ov=$T/boards/$zov; }
		a+=(-DDTC_OVERLAY_FILE=$ov.overlay); c=""
		[ -f $ov.conf ] && c=$ov.conf
		[ $v = pm ] && c="${c:+$c;}$A/pm.conf"
		[ -n "$c" ] && a+=("-DEXTRA_CONF_FILE=$c") ;;
	esac
	# the board's PM overlay (e.g. U575: STOP0/STOP1 only) applies to every PM build
	[ $v = pm ] && [ $t != app ] && [ -f $A/pm/$bb.overlay ] && a+=(-DEXTRA_DTC_OVERLAY_FILE=$A/pm/$bb.overlay)
	[ $tree = base ] && { Z=$BZ; a+=("-DZEPHYR_MODULES=$MODS"); } || Z=$PRZ
	if ! ZEPHYR_BASE=$Z west build -p -b "$board" -d "$d" "$src" -- "${a[@]}" > "$d.build.log" 2>&1; then
		echo "$n BUILD FAIL ($d.build.log)" | tee -a "$O/summary.txt"; continue; fi
	grep -q "$Z/drivers/serial/uart_stm32.c" "$d/build.ninja" || { echo "$n WRONG TREE" | tee -a "$O/summary.txt"; continue; }
	cube -w "$d/zephyr/zephyr.hex" -v -halt > "$d.flash.log" 2>&1 || { echo "$n FLASH FAIL" | tee -a "$O/summary.txt"; continue; }
	case $t in
	app) python3 "$A/run.py" 60 > "$O/$n.log" & ;;
	sample) python3 "$A/tools/sample_capture.py" 25 "$O/$n.log" > "$O/$n.res" & ;;
	zt) python3 "$A/tools/ztest_capture.py" 120 "$O/$n.log" > "$O/$n.res" & ;;
	esac
	sleep 1; cube -rst > /dev/null 2>&1; wait
	[ $t = app ] && res=$(grep -ao "uart dma check: [0-9]* failures.*" "$O/$n.log") || res=$(head -1 "$O/$n.res")
	echo "$n $(grep -aom1 'build v[^ ]*' "$O/$n.log" | cut -c7-): ${res:-NO OUTPUT}" | tee -a "$O/summary.txt"
done; done; done
