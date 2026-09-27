#!/bin/sh
# ./build.sh path/to/TIDAL_decrypted.ipa  -> also writes ./TIDAL_RadiantTidal.ipa (needs cyan)
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make FINALPACKAGE=1
cp .theos/obj/RadiantTidal.dylib .
echo "==> $(pwd)/RadiantTidal.dylib"

if [ -n "$1" ]; then
	cyan -w -i "$1" -o TIDAL_RadiantTidal.ipa -f RadiantTidal.dylib --overwrite
	echo "==> $(pwd)/TIDAL_RadiantTidal.ipa"
fi
