#!/bin/sh
# Verilator lint of the machine (a4k_machine and below).
set -e
cd "$(dirname "$0")"
R=$(cd .. && pwd)
. ./sources.sh
PYTHONDONTWRITEBYTECODE=1 python3 $R/rtl/AP68040/tools/ucode.py > /dev/null
verilator --lint-only -Wall -Wno-fatal --timing \
	-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
	-Wno-UNDRIVEN -Wno-CASEINCOMPLETE -Wno-SYNCASYNCNET -Wno-VARHIDDEN -Wno-PINMISSING -Wno-GENUNNAMED \
	-Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-BLKSEQ -Wno-INITIALDLY -Wno-COMBDLY -Wno-LATCH -Wno-CASEOVERLAP \
	-Wno-IMPLICITSTATIC -Wno-SELRANGE -Wno-STMTDLY -Wno-ASCRANGE -Wno-PROCASSINIT \
	--top-module a4k_machine $MACHINE_INC $MACHINE_SRC "$@"
