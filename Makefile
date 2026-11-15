# Light build: one clang call per file, no parallel jobs needed.
CC = clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost -Idevices
B = build

CORE = $(B)/fastmem_log.o $(B)/fastmem.o $(B)/classify.o $(B)/operands.o $(B)/translate.o $(B)/dispatch.o $(B)/mmu.o $(B)/memop.o \
       $(B)/exception.o $(B)/sysreg.o $(B)/machine.o
HOST = $(B)/jit_region.o $(B)/enter.o $(B)/disk.o $(B)/disk_resize.o $(B)/scheduling.o
DEV = $(B)/pvg_lite.o $(B)/pvg_metal.o $(B)/gicv3.o $(B)/timer.o $(B)/pl011.o $(B)/pl031.o $(B)/cfg.o $(B)/bdif.o $(B)/pcie.o \
      $(B)/virtio.o $(B)/virtio_blk.o $(B)/virtio_net.o $(B)/virtio_input.o $(B)/virtio_snd.o $(B)/virtio_usb.o $(B)/virtio_balloon.o $(B)/xhci.o $(B)/vmapple.o $(B)/aes.o $(B)/pl061.o $(B)/metallib.o
ENGINE = $(CORE) $(HOST)
METAL_LIBS = -framework Foundation -framework QuartzCore -framework Metal -weak_framework MetalFX -framework IOSurface -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers

TESTS = $(B)/test_classify $(B)/test_jit_region $(B)/test_operands $(B)/test_jit $(B)/test_mem \
        $(B)/test_mmu $(B)/test_inline_sysreg $(B)/test_exc $(B)/test_devices $(B)/test_fastmem $(B)/test_memory_bounds $(B)/test_idle_ticker $(B)/test_idle_integration $(B)/test_tail_recheck $(B)/test_audio_lifecycle $(B)/test_shutdown $(B)/test_usb_touchscreen

all: $(TESTS) $(B)/hengevm $(B)/hengevm-ref $(B)/hvsparse

# Mac-only test tool: the same machine with the CPU on Hypervisor.framework, for comparing runs.
$(B)/hengevm-ref: host/hvf_ref.c host/hvf_ref.entitlements $(ENGINE) $(DEV)
	$(CC) $(CFLAGS) host/hvf_ref.c $(ENGINE) $(DEV) -framework Hypervisor $(METAL_LIBS) -o $@
	codesign -s - -f --entitlements host/hvf_ref.entitlements $@

# Mac-only graphics device (ParavirtualizedGraphics.framework, as QEMU uses it).
# Built for an older deployment target: the framework's memory callbacks are
# marked obsolete in macOS 27 without a documented replacement.
$(B)/pvg_metal.o: devices/pvg_metal.m devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -c $< -o $@
$(B)/pvg_mac.o: devices/pvg_mac.m devices/*.h core/*.h host/*.h | $(B)
	$(CC) -fobjc-arc -O2 -g -Wall -mmacosx-version-min=15.2 -Icore -Ihost -Idevices -c $< -o $@

# User-mode NAT for the NIC: Homebrew's libslirp (brew install libslirp).
SLIRP_CFLAGS = $(shell pkg-config --cflags slirp)
SLIRP_LIBS = $(shell pkg-config --libs slirp)
$(B)/net_slirp.o: host/net_slirp.c host/*.h devices/*.h core/*.h | $(B)
	$(CC) $(CFLAGS) $(SLIRP_CFLAGS) -c $< -o $@
$(B)/dns_proxy.o: host/dns_proxy.c host/dns_proxy.h core/machine.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@

RB = $(B)/restore
RESTORE_PKGS = libplist-2.0 libusbmuxd-2.0 libimobiledevice-1.0 libimobiledevice-glue-1.0 libtatsu-1.0 libzip libcurl
RESTORE_CFLAGS = -O2 -w -DHAVE_CONFIG_H -Ithird_party/restore_config -Ithird_party -Ithird_party/libusb-1.0 \
                 -Ithird_party/libirecovery/include $(shell pkg-config --cflags $(RESTORE_PKGS) 2>/dev/null)
RESTORE_LIBS = $(shell pkg-config --libs $(RESTORE_PKGS) 2>/dev/null) -lz
IRECV_SRC = third_party/libirecovery/src/libirecovery.c
MUXD_SRC = $(wildcard third_party/usbmuxd/src/*.c)
IDR_SRC = $(wildcard third_party/idevicerestore/src/*.c)
RESTORE_OBJ = $(patsubst third_party/%.c,$(RB)/%.o,$(IRECV_SRC) $(MUXD_SRC) $(IDR_SRC))

# The helper that runs inside macOS on a virtual Mac (share.c serves it to the guest).
$(B)/henge-agent: tools/henge-agent.m
	@mkdir -p $(B)
	env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -Wall -Wextra -O2 -framework AppKit $< -o $@
	codesign -f -s - $@

# Guest-side USB-only native-touch companion; no restricted entitlement.
$(B)/henge-touch-agent: tools/henge-touch-agent.swift tools/native-touch/*.swift
	@mkdir -p $(B)
	env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun --sdk macosx swiftc -parse-as-library -target arm64-apple-macos15.0 -O tools/henge-touch-agent.swift tools/native-touch/*.swift -o $@
	codesign -f -s - $@

# Verify and deterministically package both signed guest companions.
.PHONY: native-touch-package-force
$(B)/henge-touch-agent.tar.gz: $(B)/henge-touch-agent $(B)/henge-agent tools/package_native_touch.py native-touch-package-force
	python3 tools/package_native_touch.py --binary $< --sharing-binary $(B)/henge-agent --output $@

$(B)/native_touch.o: host/native_touch.c host/native_touch.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@

# Compressed in the app: tools that sign an IPA would try to sign a bare Mach-O too.
$(B)/henge-agent.gz: $(B)/henge-agent
	gzip -9 -n -c $< > $@

$(B)/share.o: host/share.c host/share.h host/native_touch.h
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/hengevm: host/main.c $(ENGINE) $(DEV) $(B)/pvg_mac.o $(B)/net_slirp.o $(B)/dns_proxy.o $(B)/share.o $(B)/native_touch.o $(B)/audio_mac.o $(B)/vm.o $(B)/snapshot.o $(B)/usb_host.o $(B)/mac-restore/libhengerestore.a
	$(CC) $(CFLAGS) host/main.c $(ENGINE) $(DEV) $(B)/pvg_mac.o $(B)/net_slirp.o $(B)/dns_proxy.o $(B)/share.o $(B)/native_touch.o $(B)/audio_mac.o $(B)/vm.o $(B)/snapshot.o $(B)/usb_host.o $(B)/mac-restore/libhengerestore.a -lz -lcompression -framework Foundation -framework CFNetwork -framework Security -framework SystemConfiguration -framework IOKit $(SLIRP_LIBS) -framework AudioToolbox -framework ParavirtualizedGraphics -framework Metal -weak_framework MetalFX -framework IOSurface \
	    -framework Foundation -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -framework CoreFoundation \
	    -framework AppKit -framework QuartzCore -o $@

# mmu.c: no SIMD (hv_tlb_refill runs with the guest's SIMD registers live).
$(B)/fastmem.o: core/fastmem.c core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -mgeneral-regs-only -c $< -o $@
$(B)/mmu.o: core/mmu.c core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -mgeneral-regs-only -c $< -o $@
$(B)/%.o: core/%.c core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: host/%.c host/*.h core/*.h devices/*.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: host/%.S | $(B)
	$(CC) $(ASFLAGS) -c $< -o $@
$(B)/%.o: devices/%.c devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/test_classify: tests/test_classify.c tests/classify_cases.s $(B)/classify.o
	$(CC) $(CFLAGS) $^ -o $@
$(B)/test_jit_region: tests/test_jit_region.c $(B)/jit_region.o
	$(CC) $(CFLAGS) $^ -o $@
$(B)/test_operands: tests/test_operands.c tests/operand_cases.s $(B)/operands.o
	$(CC) $(CFLAGS) $^ -o $@
$(B)/test_mmu: tests/test_mmu.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_mmu.c $(ENGINE) -o $@

$(B)/test_shutdown: tests/test_shutdown.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@

# Native app lifecycle with real devices and networking; no restore assets.
$(B)/test_dns_lifecycle: tests/test_dns_lifecycle.c $(B)/dns_proxy.o
	$(CC) $(CFLAGS) $^ -o $@

$(B)/snapshot_test.o: host/snapshot.c | $(B)
	$(CC) $(CFLAGS) -DHV_SNAPSHOT_TESTING=1 -c $< -o $@

$(B)/vm_test.o: host/vm.c host/*.h devices/*.h core/*.h | $(B)
	$(CC) $(CFLAGS) -DHV_VM_TESTING=1 -c $< -o $@

$(B)/test_vm_lifecycle: tests/test_vm_lifecycle.c ios/Henge/Native/henge-vm.c $(ENGINE) $(DEV) $(B)/vm_test.o $(B)/snapshot_test.o $(B)/audio_mac.o $(B)/net_slirp.o $(B)/dns_proxy.o $(B)/share.o $(B)/native_touch.o $(B)/usb_host.o
	$(CC) $(CFLAGS) -DHV_VM_TESTING=1 -Iios/Henge/Native $^ $(SLIRP_LIBS) $(METAL_LIBS) -framework AudioToolbox -lcompression -o $@

test-vm-lifecycle: $(B)/test_vm_lifecycle
	$(B)/test_vm_lifecycle
.PHONY: test-vm-lifecycle

$(B)/archive_fixture.metallib: tests/archive_fixture.metal | $(B)
	xcrun -sdk macosx metal -c $< -o $(B)/archive_fixture.air
	xcrun -sdk macosx metallib $(B)/archive_fixture.air -o $@

$(B)/archive_%.metallib: tests/archive_fixture.metal | $(B)
	xcrun -sdk macosx metal -DHENGE_ARCHIVE_FUNC_$*=1 -c $< -o $(B)/archive_$*.air
	xcrun -sdk macosx metallib $(B)/archive_$*.air -o $@

$(B)/test_pvg_lifecycle: tests/test_pvg_lifecycle.m $(ENGINE) $(DEV) $(B)/archive_fixture.metallib $(foreach f,av af anr ak ak2,$(B)/archive_$(f).metallib)
	$(CC) $(CFLAGS) -fobjc-arc -DHENGE_TEST_ARCHIVE_FIXTURE='"$(B)/archive_fixture.metallib"' $(filter-out %.metallib,$^) $(METAL_LIBS) -o $@

$(B)/hvsparse: tools/hvsparse_main.c host/hvsparse.c host/hvsparse.h | $(B)
	$(CC) $(CFLAGS) tools/hvsparse_main.c host/hvsparse.c -o $@

# Block-level tests: test_X.c plus X_programs.S, run natively and through the JIT.
$(B)/test_devices: tests/test_devices.c tests/devices_programs.S tests/harness.S tests/harness.h $(ENGINE) $(DEV)
	$(CC) $(CFLAGS) -Itests tests/test_devices.c tests/devices_programs.S tests/harness.S $(ENGINE) $(DEV) $(METAL_LIBS) -o $@
$(B)/test_%: tests/test_%.c tests/%_programs.S tests/harness.S tests/harness.h $(ENGINE)
	$(CC) $(CFLAGS) -Itests tests/test_$*.c tests/$*_programs.S tests/harness.S $(ENGINE) -o $@

test: all
	@ulimit -s 65520; for t in $(TESTS); do echo "== $$t"; $$t || exit 1; done # a test keeps a whole HvCpu (2 MB of TLB and more) on its stack

$(B):
	mkdir -p $(B)

clean:
	rm -rf $(B)

.PHONY: all test clean

# Walker/cache policy tests; the main engine is ARM64/Darwin.
$(B)/test_fastmem: tests/test_fastmem.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_fastmem.c $(ENGINE) -o $@
test-fastmem: $(B)/test_fastmem
	$(B)/test_fastmem
.PHONY: test-fastmem

$(B)/test_memory_bounds: tests/test_memory_bounds.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_memory_bounds.c $(ENGINE) -o $@

$(B)/test_inline_sysreg: tests/test_inline_sysreg.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_inline_sysreg.c $(ENGINE) -o $@

$(B)/test_xhci_slots: tests/test_xhci_slots.c devices/xhci.c $(ENGINE) $(B)/pcie.o $(B)/gicv3.o
	$(CC) $(CFLAGS) -fsanitize=address,undefined tests/test_xhci_slots.c $(ENGINE) $(B)/pcie.o $(B)/gicv3.o -o $@

$(B)/test_stw_flush: tests/test_stw_flush.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_stw_flush.c $(ENGINE) -o $@

# ---- iOS: the engine as a static library for the Henge app (ios/) ----
# make ios-lib -> build/ios/libhengevm.a. Networking links the arm64 iOS builds
# of libslirp and glib from Husk's sysroot (scripts there make them); see ios/README.md.
IOS_SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
IOS_CC = xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot $(IOS_SDK)
# ios/deps/include/slirp first when it holds libslirp's headers (they are all the engine takes from there).
IOS_DEPS ?= $(if $(wildcard ios/deps/include/slirp/libslirp.h),$(CURDIR)/ios/deps,$(HOME)/Documents/Coding/Husk/build/ios-arm64/sysroot)
IOS_CFLAGS = -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost -Idevices -I$(IOS_DEPS)/include/slirp
IB = build/ios
IOS_SRC = $(wildcard core/*.c) host/prof_ios.c host/jit_region.c host/disk.c host/disk_resize.c host/scheduling.c host/vm.c host/snapshot.c host/net_slirp.c host/dns_proxy.c host/share.c host/native_touch.c host/audio_mac.c host/hvsparse.c host/usb_host.c \
          $(filter-out devices/pvg_mac.m,$(wildcard devices/*.c))
IOS_OBJ = $(patsubst %.c,$(IB)/%.o,$(IOS_SRC)) $(IB)/host/enter.o $(IB)/devices/pvg_metal.o

$(IB)/core/fastmem.o: core/fastmem.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -mgeneral-regs-only -c $< -o $@
$(IB)/core/mmu.o: core/mmu.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -mgeneral-regs-only -c $< -o $@
$(IB)/%.o: %.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -c $< -o $@
$(IB)/devices/pvg_metal.o: devices/pvg_metal.m devices/*.h core/*.h host/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -c $< -o $@
$(IB)/host/enter.o: host/enter.S
	@mkdir -p $(dir $@)
	$(IOS_CC) -c $< -o $@
$(IB)/libhengevm.a: $(IOS_OBJ)
	rm -f $@
	xcrun --sdk iphoneos libtool -static -o $@ $(IOS_OBJ)
# The translation layer (tl/) for the app's experimental Mac apps: its loader and disk-image reader, not the toy AppKit.
TL_SRC = tl/loader/tl_loader.c tl/loader/tl_bundle.m tl/loader/tl_stubs.m tl/loader/tl_tlv.S tl/dmg/udif.c tl/dmg/volume.c tl/dmg/hfsplus.c tl/dmg/apfs.c tl/dmg/appinfo.c
TL_IOS_OBJ = $(patsubst %,$(IB)/%.o,$(TL_SRC))
# Henge's AppKit, for Mac apps with windows, and the table of its C symbols (made from these objects).
TL_SHIM = $(wildcard tl/shim/appkit/*.m)
TL_SHIM_IOS_OBJ = $(patsubst %,$(IB)/%.o,$(TL_SHIM))
$(IB)/tl/%.o: tl/% tl/loader/*.h tl/dmg/*.h tl/shim/appkit/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) -O2 -g -Wall -Wno-unused-parameter -fblocks $(if $(filter %.m,$<),-fobjc-arc) -c $< -o $@
$(IB)/tl/shim/hk_symbols.c: $(TL_SHIM_IOS_OBJ) tl/shim/tools/hk_symbols.sh
	@mkdir -p $(dir $@)
	tl/shim/tools/hk_symbols.sh $@ $(TL_SHIM_IOS_OBJ)
$(IB)/tl/shim/hk_symbols.o: $(IB)/tl/shim/hk_symbols.c
	$(IOS_CC) -c $< -o $@
$(IB)/libhengetl.a: $(TL_IOS_OBJ) $(TL_SHIM_IOS_OBJ) $(IB)/tl/shim/hk_symbols.o
	rm -f $@
	xcrun --sdk iphoneos libtool -static -o $@ $(TL_IOS_OBJ) $(TL_SHIM_IOS_OBJ) $(IB)/tl/shim/hk_symbols.o
ios-lib: $(IB)/libhengevm.a $(IB)/libhengetl.a
.PHONY: ios-lib

# The app's glue to it (ios/Henge/Native/henge-tl.c) on the Mac: import a disk image, describe what it holds, run a program.
$(B)/test_tl_glue: tests/test_tl_glue.c ios/Henge/Native/henge-tl.c $(TL_SRC) host/jit_region.c | $(B)
	$(CC) $(CFLAGS) -fblocks -Iios/Henge/Native tests/test_tl_glue.c ios/Henge/Native/henge-tl.c $(filter-out %.m,$(TL_SRC)) host/jit_region.c \
	  -x objective-c -fobjc-arc tl/loader/tl_bundle.m tl/loader/tl_stubs.m -framework Foundation -lz -lbz2 -lcompression -o $@
# The glue for Mac apps with windows (ios/Henge/Native/henge-tl-app.m) on the Mac, against Henge's AppKit as tl/
# builds it: test_tl_app APP SNAPDIR [SECONDS] runs the app and draws its windows to PNG files.
$(B)/test_tl_app: tests/test_tl_app.m ios/Henge/Native/henge-tl-app.m ios/Henge/Native/henge-tl.c $(TL_SRC) host/jit_region.c tl/shim/appkit/*.m tl/shim/appkit/*.h | $(B)
	$(MAKE) -C tl build/tlios
	$(CC) $(CFLAGS) -fblocks -Iios/Henge/Native tests/test_tl_app.m -x objective-c -fobjc-arc ios/Henge/Native/henge-tl-app.m -x none \
	  ios/Henge/Native/henge-tl.c $(filter-out %.m,$(TL_SRC)) host/jit_region.c -x objective-c -fobjc-arc tl/loader/tl_bundle.m tl/loader/tl_stubs.m -x none \
	  tl/build/shim/*.o tl/build/shim/hk_symbols.c -framework Foundation -framework QuartzCore -framework Metal -framework CoreGraphics \
	  -framework CoreText -framework ImageIO -framework IOSurface -framework CoreVideo -framework UniformTypeIdentifiers \
	  -lz -lbz2 -lcompression -o $@
# Sample Mac programs for the app's Mac apps screen, as a disk image (read by the same import path as anyone's).
$(B)/tl-samples.dmg: tests/tl/exit3.c tl/tests/hello.c tl/tests/fnd.m tl/tests/swifty.swift tl/tests/cxx.cpp tl/tests/fw.m tl/tests/fwapp.m | $(B)
	env -u IPHONEOS_DEPLOYMENT_TARGET SDKROOT="$$(xcrun --sdk macosx --show-sdk-path)" make -C tl CC="xcrun --sdk macosx clang" build/hello build/fnd build/swifty build/cxx build/FW.app/Contents/MacOS/fwapp
	rm -rf $(B)/tl-samples $@ && mkdir -p $(B)/tl-samples
	cp tl/build/hello "$(B)/tl-samples/Hello (C)"
	cp tl/build/fnd "$(B)/tl-samples/Foundation sample"
	cp tl/build/swifty "$(B)/tl-samples/Swift sample"
	cp tl/build/cxx "$(B)/tl-samples/C++ sample"
	ditto tl/build/FW.app "$(B)/tl-samples/Framework sample.app"
	hdiutil create -quiet -srcfolder $(B)/tl-samples -volname "Henge Samples" -fs HFS+ -format UDZO $@
	xattr -c $@ # codesign refuses an app holding a file with Finder information

$(B)/tl-exit3: tests/tl/exit3.c | $(B)
	$(CC) -target arm64-apple-macos13 -O1 $< -o $@
test-tl-glue: $(B)/test_tl_glue $(B)/tl-exit3
	make -C tl all test-dmg >/dev/null
	$(B)/test_tl_glue
	$(B)/test_tl_glue exit3
.PHONY: test-tl-glue

# The restore stack, built from the same sources and with the same stand-ins as iOS.
$(B)/mac-restore/libhengerestore.a: tools/build_ios_restore.sh host/libusb_shim.c host/install.c host/curl_shim.m $(wildcard third_party/*/src/*.c) $(wildcard third_party/libirecovery/src/*.c)
	nice -n 10 tools/build_ios_restore.sh mac

# The installer: libirecovery, usbmuxd and idevicerestore (third_party, vendored
# sources) linked against host/libusb_shim.c, so they restore the virtual Mac
# through its USB port the way Virtualization.framework's installer does.
# Mac build: the libraries they need come from Homebrew (libimobiledevice,
# libtatsu, libplist, libzip).
$(RB)/libirecovery/%.o: third_party/libirecovery/%.c
	@mkdir -p $(dir $@)
	$(CC) $(RESTORE_CFLAGS) -DPACKAGE_VERSION='"1.3.1-henge"' -c $< -o $@
$(RB)/usbmuxd/%.o: third_party/usbmuxd/%.c
	@mkdir -p $(dir $@)
	$(CC) $(RESTORE_CFLAGS) -DPACKAGE_NAME='"usbmuxd"' -DPACKAGE_VERSION='"1.1.1-henge"' -Dmain=usbmuxd_main -Dlog_level=usbmuxd_log_level -c $< -o $@
$(RB)/idevicerestore/%.o: third_party/idevicerestore/%.c
	@mkdir -p $(dir $@)
	$(CC) $(RESTORE_CFLAGS) -Ithird_party/idevicerestore/src -DIDEVICERESTORE_NOMAIN -DPACKAGE_NAME='"idevicerestore"' -DPACKAGE_VERSION='"1.0.0-henge"' -c $< -o $@
$(B)/libusb_shim.o: host/libusb_shim.c host/*.h devices/*.h | $(B)
	$(CC) $(CFLAGS) -Ithird_party -c $< -o $@
$(B)/install.o: host/install.c host/*.h devices/*.h | $(B)
	$(CC) $(CFLAGS) $(RESTORE_CFLAGS) -c $< -o $@
restore-objs: $(RESTORE_OBJ)
.PHONY: restore-objs

$(B)/test_native_touch: tests/test_native_touch.c host/native_touch.c host/native_touch.h host/share.c host/share.h | $(B)
	$(CC) $(CFLAGS) tests/test_native_touch.c host/native_touch.c host/share.c -o $@

$(B)/test_native_touch_session: tests/test_native_touch_session.swift ios/Henge/NativeTouchSession.swift $(B)/native_touch.o
	xcrun --sdk macosx swiftc -parse-as-library -import-objc-header host/native_touch.h tests/test_native_touch_session.swift ios/Henge/NativeTouchSession.swift $(B)/native_touch.o -o $@

test-native-touch: $(B)/test_native_touch $(B)/test_native_touch_session
	./$(B)/test_native_touch
	./$(B)/test_native_touch_session
.PHONY: test-native-touch

$(B)/test_runner_control: tests/test_runner_control.c host/share.c host/share.h host/native_touch.c | $(B)
	$(CC) $(CFLAGS) tests/test_runner_control.c host/share.c host/native_touch.c -o $@
$(B)/test_runner_control_asan: tests/test_runner_control.c host/share.c host/share.h host/native_touch.c | $(B)
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined tests/test_runner_control.c host/share.c host/native_touch.c -o $@
test-runner: $(B)/test_runner_control $(B)/test_runner_control_asan $(B)/henge-agent
	./$(B)/test_runner_control
	./$(B)/test_runner_control_asan
.PHONY: test-runner

$(B)/test_guest_connection: tests/test_guest_connection.swift tools/native-touch/GuestConnection.swift | $(B)
	xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library $^ -o $@

test-guest-connection: $(B)/test_guest_connection
	python3 tests/test_guest_connection.py $<
.PHONY: test-guest-connection

# Session-owned display routing, independent of JIT, Metal and a connected monitor.
$(B)/test_display_targets: ios/Henge/DisplayTargetSelection.swift tests/test_display_targets.swift | $(B)
	xcrun --sdk macosx swiftc $^ -o $@

# The router's hand-off to the engine, with the engine call recorded instead of made.
$(B)/test_display_router: ios/Henge/DisplayRouter.swift ios/Henge/DisplayTargetSelection.swift tests/test_display_router.swift tests/display_engine_stub.h | $(B)
	xcrun --sdk macosx swiftc -import-objc-header tests/display_engine_stub.h $(filter %.swift,$^) -o $@

# Which external screen shows the Mac before iOS 27, for any order of session and plug events.
$(B)/test_external_screen_plan: ios/Henge/ExternalScreenPlan.swift tests/test_external_screen_plan.swift | $(B)
	xcrun --sdk macosx swiftc $^ -o $@

# The glue: fake screens and a real router, to check what each screen is told and what the engine draws.
$(B)/test_legacy_external_display: ios/Henge/LegacyExternalDisplay.swift ios/Henge/ExternalScreenPlan.swift ios/Henge/MacPresentation.swift ios/Henge/DisplayRouter.swift ios/Henge/DisplayTargetSelection.swift tests/test_legacy_external_display.swift tests/display_engine_stub.h | $(B)
	xcrun --sdk macosx swiftc -import-objc-header tests/display_engine_stub.h $(filter %.swift,$^) -o $@

# Info.plist must declare the external display scene role with ExternalDisplaySceneDelegate, or iOS 17-26 never offer the display.
$(B)/test_scene_manifest: tests/test_scene_manifest.swift | $(B)
	xcrun --sdk macosx swiftc -parse-as-library $^ -o $@

test-display-routing: $(B)/test_display_targets $(B)/test_display_router $(B)/test_external_screen_plan $(B)/test_legacy_external_display $(B)/test_scene_manifest
	$(B)/test_display_targets
	$(B)/test_display_router
	$(B)/test_external_screen_plan
	$(B)/test_legacy_external_display
	$(B)/test_scene_manifest ios/Henge/Info.plist ios/Henge/ExternalDisplaySceneDelegate.swift
.PHONY: test-display-routing

# What the JIT setup tells the user and when it retries by itself, for each kind of network path and helper error.
$(B)/test_jit_advice: ios/Henge/JIT/JITNetworkAdvice.swift tests/test_jit_advice.swift | $(B)
	xcrun --sdk macosx swiftc $^ -o $@

test-jit-advice: $(B)/test_jit_advice
	$(B)/test_jit_advice
.PHONY: test-jit-advice

$(B)/test_idle_integration: tests/test_idle_integration.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_idle_integration.c $(ENGINE) -o $@

$(B)/test_idle_ticker: tests/test_idle_ticker.c host/idle_ticker.h host/wake_epoch.h | $(B)
	$(CC) $(CFLAGS) -pthread tests/test_idle_ticker.c -o $@

$(B)/test_tail_recheck: tests/test_tail_recheck.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_tail_recheck.c $(ENGINE) -o $@

$(B)/test_tlb_preload: tests/test_tlb_preload.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_tlb_preload.c $(ENGINE) -o $@

$(B)/test_audio_lifecycle: tests/test_audio_lifecycle.c tests/audio_test_api.h host/audio_mac.c | $(B)
	$(CC) $(CFLAGS) -pthread tests/test_audio_lifecycle.c -o $@

$(B)/test_cpu_sync: tests/test_cpu_sync.c $(ENGINE)
	$(CC) $(CFLAGS) -pthread tests/test_cpu_sync.c $(ENGINE) -o $@

$(B)/test_timer_dispatch: tests/test_timer_dispatch.c $(ENGINE)
	$(CC) $(CFLAGS) $< $(ENGINE) -o $@

# Real disk worker/virtqueue concurrency with explicit RAM/PCI boundaries.
$(B)/test_blk_segments: tests/test_blk_segments.c devices/virtio_blk.c devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -ffunction-sections -fdata-sections -O1 -fsanitize=address,undefined tests/test_blk_segments.c -Wl,-dead_strip -o $@

$(B)/bench_disk_iov: tests/bench_disk_iov.c host/disk.c host/disk.h | $(B)
	$(CC) $(CFLAGS) tests/bench_disk_iov.c host/disk.c -o $@

$(B)/test_frame_metrics: tests/test_frame_metrics.c devices/frame_metrics.h | $(B)
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined tests/test_frame_metrics.c -o $@

$(B)/test_disk_iov: tests/test_disk_iov.c host/disk.c host/disk.h | $(B)
	$(CC) $(CFLAGS) -D_DARWIN_C_SOURCE -O1 -fsanitize=address,undefined tests/test_disk_iov.c -o $@

$(B)/test_blk_completion: tests/test_blk_completion.c devices/virtio_blk.c devices/virtio.c host/disk.c devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -D_DARWIN_C_SOURCE -D_DEFAULT_SOURCE -pthread -O1 -fsanitize=address,undefined tests/test_blk_completion.c devices/virtio_blk.c devices/virtio.c host/disk.c -o $@

$(B)/test_fastmem_bench: tests/test_fastmem_bench.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_fastmem_bench.c $(ENGINE) -o $@

# Guest USB touchscreen research: protocol checks need no macOS image.
$(B)/test_usb_touchscreen: tests/test_usb_touchscreen.c $(ENGINE) $(DEV)
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined $^ $(METAL_LIBS) -o $@

test-usb-touchscreen: $(B)/test_usb_touchscreen
	@mkdir -p $(B)/usb-touch-research
	./$(B)/test_usb_touchscreen
.PHONY: test-usb-touchscreen

$(B)/test_pvg_task_memory: tests/test_pvg_task_memory.c devices/pvg_lite.c $(ENGINE) $(filter-out $(B)/pvg_lite.o,$(DEV))
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined tests/test_pvg_task_memory.c $(ENGINE) $(filter-out $(B)/pvg_lite.o,$(DEV)) $(METAL_LIBS) -o $@

# Partial code-cache eviction against real multi-vCPU translated execution.
$(B)/test_jit_ring: tests/test_jit_ring.c $(ENGINE)
	$(CC) $(CFLAGS) -D_DARWIN_C_SOURCE -pthread $< $(ENGINE) -o $@

$(B)/bench_far_chain: tests/bench_far_chain.c $(ENGINE)
	$(CC) $(CFLAGS) $< $(ENGINE) -o $@
$(B)/test_pvg_linear_bounds: tests/test_pvg_linear_bounds.c devices/pvg_linear_bounds.h | $(B)
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined $< -o $@

$(B)/test_snapshot_pack: tests/test_snapshot_pack.c host/snapshot.c host/snapshot.h | $(B)
	$(CC) $(CFLAGS) -fblocks -ffunction-sections -fdata-sections -O1 -fsanitize=address,undefined tests/test_snapshot_pack.c -lcompression -Wl,-dead_strip -o $@

$(B)/bench_snapshot_admission: tests/bench_snapshot_admission.c host/snapshot.c host/snapshot.h | $(B)
	$(CC) $(CFLAGS) -fblocks -ffunction-sections -fdata-sections $< -lcompression -Wl,-dead_strip -o $@

$(B)/test_register_groups: tests/test_register_groups.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@

# Differential build: same production emitter, previous register-only policy.
$(B)/translate-register-reference.o: core/translate.c core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -DHV_GROUP_WRITEBACK=0 -c $< -o $@
ENGINE_REGISTER_REFERENCE = $(filter-out $(B)/translate.o,$(ENGINE)) $(B)/translate-register-reference.o
$(B)/test_mem_register_reference: tests/test_mem.c tests/mem_programs.S tests/harness.S $(ENGINE_REGISTER_REFERENCE)
	$(CC) $(CFLAGS) tests/test_mem.c tests/mem_programs.S tests/harness.S $(ENGINE_REGISTER_REFERENCE) -o $@
$(B)/bench_stack_groups: tests/bench_stack_groups.c tests/mem_programs.S tests/harness.S $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@
$(B)/bench_stack_groups_reference: tests/bench_stack_groups.c tests/mem_programs.S tests/harness.S $(ENGINE_REGISTER_REFERENCE)
	$(CC) $(CFLAGS) $^ -o $@

$(B)/test_exc_register_reference: tests/test_exc.c tests/exc_programs.S tests/harness.S $(ENGINE_REGISTER_REFERENCE)
	$(CC) $(CFLAGS) $^ -o $@

$(B)/test_net_batch: tests/test_net_batch.c devices/virtio_net.c devices/virtio.c devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined tests/test_net_batch.c devices/virtio_net.c devices/virtio.c -o $@

$(B)/bench_interleaved_groups: tests/bench_interleaved_groups.c tests/mem_programs.S tests/harness.S $(ENGINE)
	$(CC) $(CFLAGS) -Itests $^ -o $@

$(B)/test_ijc_eviction: tests/test_ijc_eviction.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@

$(B)/test_jit_retention: tests/test_jit_retention.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@

$(B)/bench_jit_retention: tests/bench_jit_retention.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@

$(B)/test_branch_sites: tests/test_branch_sites.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@

$(B)/bench_branch_sites: tests/bench_branch_sites.c $(ENGINE)
	$(CC) $(CFLAGS) $^ -o $@
