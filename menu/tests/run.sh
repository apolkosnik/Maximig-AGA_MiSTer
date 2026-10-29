#!/bin/bash
# Native tests for the Maximig menu module: the module built with the host
# compiler, loaded by Main_MiSTer's real module host (mnu.cpp, mnu_path.cpp)
# on Main's test stubs (tests/mnu/stubs.cpp), driven by maximig_test.cpp.
#
#   menu/tests/run.sh                       Main at ../../MiSTer_Main/Main_MiSTer
#   MAIN=/path/to/Main_MiSTer run.sh
#   MNU_TEST_BUILD=/x run.sh                build somewhere else
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MENU=$(cd "$HERE/.." && pwd)
CORE=$(cd "$MENU/.." && pwd)
MAIN=${MAIN:-$(cd "$CORE/../MiSTer_Main/Main_MiSTer" 2>/dev/null && pwd)}
BUILD=${MNU_TEST_BUILD:-$HERE/build}
CXX=${CXX:-g++}

if [ ! -f "$MAIN/mnu_api.h" ] || [ ! -f "$MAIN/tests/mnu/stubs.cpp" ]; then
	echo "no Main_MiSTer with the module tests at '$MAIN' (set MAIN=)"
	exit 1
fi

# (cd.h, through minimig_config.h: a C-linkage typedef the host compiler warns about)
CXXFLAGS="-std=gnu++14 -O1 -g -Wall -Wextra -Wno-non-c-typedef-for-linkage -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE
          -I$MAIN -I$MAIN/lib/libchdr/include -I$MAIN/tests/mnu -I$CORE/hps"
MODFLAGS="-shared -fPIC -fvisibility=hidden -fno-gnu-unique -Wl,--no-undefined"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "== module"
$CXX $CXXFLAGS $MODFLAGS -o "$BUILD/maximig.so" "$MENU/maximig.cpp"
nm -D --defined-only "$BUILD/maximig.so" | awk '{print $3}' | grep -v '^_' > "$BUILD/maximig.syms" || true
if [ "$(cat "$BUILD/maximig.syms")" != "mnu_entry" ]; then
	echo "FAIL: maximig.so exports: $(tr '\n' ' ' < "$BUILD/maximig.syms")"
	exit 1
fi
echo "maximig.so exports only mnu_entry"

echo "== maximig_test"
$CXX $CXXFLAGS -o "$BUILD/maximig_test" "$HERE/maximig_test.cpp" "$MAIN/tests/mnu/stubs.cpp" "$MAIN/mnu.cpp" "$MAIN/mnu_path.cpp" -ldl
F="$BUILD/fixture"
mkdir -p "$F/_Computer" "$F/config"
cp "$BUILD/maximig.so" "$F/_Computer/Maximig_a_aa3000.mnu"
cp "$BUILD/maximig.so" "$F/_Computer/Maximig.mnu"
: > "$F/_Computer/Maximig_a_aa3000_20261029.rbf"
: > "$F/_Computer/Maximig_20261025.rbf"
"$BUILD/maximig_test" "$F"

echo "all Maximig menu module tests passed"
