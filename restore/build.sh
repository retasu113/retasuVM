#!/bin/bash
# Build the restore stack (idevicerestore + usbmuxd + libirecovery +
# libimobiledevice + libtatsu + libplist + libzip, all from Henge's vendored
# sources) linked against the socket-backed libusb shim (vusb_socket.c).
# Mirrors Henge's Makefile restore rules, adapted to Linux.
set -e
cd "$(dirname "$0")"
H=~/workspace/retasuvm/tools/henge/Henge-main/third_party
R=~/workspace/retasuvm/restore
B=$R/build
mkdir -p $B/obj/{plist,glue,muxd,tatsu,idev,irecv,idr,muxdaemon}
CFLAGS="-O2 -w -DHAVE_CONFIG_H -I$B/config -I$H"

# libplist (+ libcnary)
for f in base64 bplist bytearray common hashtable jplist jsmn oplist plist ptrarray time64 xplist out-default out-limd out-plutil; do
  gcc $CFLAGS -I$H/libplist/include -I$H/libplist/src -I$H/libplist/libcnary/include -DPACKAGE_VERSION='"2.2.0-henge"' -c $H/libplist/src/$f.c -o $B/obj/plist/$f.o
done
for f in node cnary node_list; do
  gcc $CFLAGS -I$H/libplist/libcnary/include -c $H/libplist/libcnary/$f.c -o $B/obj/plist/$f.o
done
ar rcs $B/libplist.a $B/obj/plist/*.o

# libimobiledevice-glue
for f in $H/libimobiledevice-glue/src/*.c; do
  gcc $CFLAGS -I$H/libplist/include -I$H/libimobiledevice-glue/include -DPACKAGE_NAME='"libimobiledevice-glue"' -DPACKAGE_VERSION='"1.3.1-henge"' -c $f -o $B/obj/glue/$(basename $f .c).o
done
ar rcs $B/libimobiledevice-glue.a $B/obj/glue/*.o

# libusbmuxd
gcc $CFLAGS -I$H/libplist/include -I$H/libimobiledevice-glue/include -I$H/libusbmuxd/include -DPACKAGE_VERSION='"2.0.2-henge"' -c $H/libusbmuxd/src/libusbmuxd.c -o $B/obj/muxd/libusbmuxd.o
ar rcs $B/libusbmuxd.a $B/obj/muxd/*.o

# libtatsu (vendored curl headers; links the system libcurl)
for f in tatsu tss; do
  gcc $CFLAGS -I$H/libplist/include -I$H/libimobiledevice-glue/include -I$H/libtatsu/include -I$H/curl_include -DPACKAGE_VERSION='"1.0.1-henge"' -c $H/libtatsu/src/$f.c -o $B/obj/tatsu/$f.o
done
ar rcs $B/libtatsu.a $B/obj/tatsu/*.o

# libimobiledevice
INC5="-I$H/libplist/include -I$H/libimobiledevice-glue/include -I$H/libusbmuxd/include -I$H/libimobiledevice -I$H/libimobiledevice/include"
for f in $H/libimobiledevice/src/*.c $H/libimobiledevice/common/*.c; do
  gcc $CFLAGS $INC5 -DPACKAGE_VERSION='"1.3.1-henge"' -c $f -o $B/obj/idev/$(basename $f .c)_$(basename $(dirname $f)).o
done
ar rcs $B/libimobiledevice.a $B/obj/idev/*.o

# libzip (cmake)
if [ ! -f $B/libzip-build/lib/libzip.a ]; then
  cmake -S $H/libzip -B $B/libzip-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=ON \
    -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DBUILD_OSSFUZZ=OFF > /dev/null
  cmake --build $B/libzip-build -j4 > /dev/null
fi

# libirecovery + idevicerestore + usbmuxd (Henge's Makefile rules)
INC6="$INC5 -I$H/libtatsu/include -I$H/curl_include -I$B/libzip-build -I$H/libzip/lib -I$H/libusb-1.0 -I$H/libirecovery/include"
# Patched copy of libirecovery: recovery packets 0x8000 -> 0x40000 for the
# emulated USB link (per-transfer guest cost dominates; see the patch script).
mkdir -p $B/src_patched
cp $H/libirecovery/src/libirecovery.c $B/src_patched/libirecovery.c
python3 $(dirname $0)/apply_libirecovery_patch.py $B/src_patched/libirecovery.c
gcc $CFLAGS $INC6 -DPACKAGE_VERSION='"1.3.1-henge"' -c $B/src_patched/libirecovery.c -o $B/obj/irecv/libirecovery.o
# Patched copies: device-event waits are 5-20 s upstream, far too short for an
# emulated guest (the ROM needs minutes of wall time to verify and boot iBSS).
# Raise every device_event_cond wait in dfu.c / idevicerestore.c to 900 s.
mkdir -p $B/src_patched
for f in dfu idevicerestore; do
  sed -E 's/(device_event_cond, &client->device_event_mutex, )[0-9]+/\1900000/' $H/idevicerestore/src/$f.c > $B/src_patched/$f.c
done
python3 $R/apply_localpolicy_patch.py $B/src_patched/idevicerestore.c
for f in $H/idevicerestore/src/*.c; do
  base=$(basename $f .c)
  src=$f
  [ -f $B/src_patched/$base.c ] && src=$B/src_patched/$base.c
  gcc $CFLAGS $INC6 -I$H/idevicerestore/src -DIDEVICERESTORE_NOMAIN -DPACKAGE_NAME='"idevicerestore"' -DPACKAGE_VERSION='"1.0.0-henge"' -c $src -o $B/obj/idr/$base.o
done
for f in $H/usbmuxd/src/*.c; do
  gcc $CFLAGS $INC6 -DPACKAGE_NAME='"usbmuxd"' -DPACKAGE_VERSION='"1.1.1-henge"' -Dmain=usbmuxd_main -Dlog_level=usbmuxd_log_level -c $f -o $B/obj/muxdaemon/$(basename $f .c).o
done

# our side: socket backend + Henge's shim/usb_host/install + driver main
for f in vusb_socket usb_host libusb_shim install main_restore; do
  gcc $CFLAGS $INC6 -I$R -c $R/$f.c -o $B/obj/$f.o
done

gcc -O2 -o $B/restore $B/obj/main_restore.o $B/obj/install.o $B/obj/libusb_shim.o $B/obj/usb_host.o $B/obj/vusb_socket.o \
  -Wl,--start-group $B/obj/idr/*.o $B/obj/irecv/*.o $B/obj/muxdaemon/*.o \
  $B/libimobiledevice.a $B/libtatsu.a $B/libusbmuxd.a $B/libimobiledevice-glue.a $B/libplist.a $B/libzip-build/lib/libzip.a \
  -Wl,--end-group -l:libcurl.so.4 -lssl -lcrypto -lz -lbz2 -lpthread -lm -ldl
echo "built $B/restore"
