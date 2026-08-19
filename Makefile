# V821 (RV32) mainline Linux — build DAG
#
#   make            # = make check: build whatever is stale, then run the host-side gates
#   make boot       # after check passes, boot over FEL (hold FEL, replug USB first)
#   make help       # list every target
#
# Why a DAG at all: typing the three commands by hand gets the order wrong exactly
# once (dtc before editing the .dts, or editing the dts and stopping after step 2)
# and an old dtb is packed silently. The board still boots, just with wrong config.

TOP   := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD ?= $(TOP)/build
include $(TOP)/pins.env

LINUX   ?= $(BUILD)/linux
OPENSBI ?= $(BUILD)/opensbi
KOUT    ?= $(BUILD)/kernel

# Do not name this O. Kernel kbuild takes O= as its output directory, but OpenSBI's
# Makefile:24 also has an ifdef O, and make promotes environment variables to make
# variables — so merely having O exported in the shell makes OpenSBI drop fw_payload
# into that directory, and "make succeeded but the flashed image is the old one".
unexport O

# Default to the distro cross toolchain (Arch: pacman -S riscv64-linux-gnu-gcc).
# For XuanTie: make CROSS=/abs/path/to/riscv64-unknown-linux-gnu-.
# A CROSS containing a slash is made absolute: make -C runs inside the kernel tree,
# so a relative path would resolve there instead, and kconfig's syncconfig dies up
# front with "C compiler not found".
CROSS ?= riscv64-linux-gnu-
ifneq ($(findstring /,$(CROSS)),)
CROSS := $(abspath $(dir $(CROSS)))/$(notdir $(CROSS))
endif

NPROC ?= $(shell nproc 2>/dev/null || echo 4)
KMAKE := $(MAKE) -C $(LINUX) O=$(KOUT) ARCH=riscv CROSS_COMPILE=$(CROSS)

# Byte reproducibility: two people building on different machines in different
# directories must get the same fw_payload.bin. Left alone there are two sources of
# variance — the build timestamp in the kernel banner, and the file mtimes in the
# initramfs cpio headers (whenever git checkout happened to run). This one variable
# covers both: the banner uses it directly, and usr/Makefile:67 passes it to
# gen_initramfs.sh as -d. For a real timestamp: make KBUILD_BUILD_TIMESTAMP="$(date)".
export KBUILD_BUILD_TIMESTAMP ?= 2026-08-13 00:00:00 UTC
export KBUILD_BUILD_USER      ?= v821
export KBUILD_BUILD_HOST      ?= v821-linux
# The #N in the banner comes from .version in objtree and increments on every link,
# so the same source gives different numbers in a tree that has been built before and
# in a freshly cloned one (init/Makefile:32).
export KBUILD_BUILD_VERSION   ?= 1

DTS   := $(TOP)/boot/v821-min.dts
DTB   := $(BUILD)/v821-min.dtb
IRFS  := $(BUILD)/initramfs.list
IMAGE := $(KOUT)/arch/riscv/boot/Image
STUB  := $(BUILD)/a27_stub.bin
FW    := $(OPENSBI)/build/platform/generic/firmware/fw_payload.bin
STAMP := $(BUILD)/.src-stamp

.PHONY: all help tools src dtb stub kernel fw verify check boot boot-nopll \
        config-diff patch-check menuconfig clean distclean

all: check  ## build up to the host-side gates (default)

help:  ## list targets
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t28

$(BUILD):
	@mkdir -p $@

# ---- toolchain and sources ----

tools:  ## check host tools, and that the cross toolchain really builds rv32
	@sh $(TOP)/scripts/check-tools.sh $(CROSS)

$(STAMP): $(TOP)/pins.env $(wildcard $(TOP)/patches/linux-*.patch) $(wildcard $(TOP)/patches/opensbi-*.patch) | $(BUILD)
	@BUILD=$(BUILD) sh $(TOP)/scripts/fetch.sh
	@touch $@

src: $(STAMP)  ## fetch linux and opensbi at the pinned commits and apply patches

# ---- device tree ----

# -p 0x4000 is not optional: OpenSBI fixes this FDT up in place (lla a1, fw_fdt_bin
# in fw_base.S), and the padding is the room fdt_open_into() needs to grow it.
$(DTB): $(DTS) | $(BUILD)
	dtc -O dtb -p 0x4000 -o $@ $<

dtb: $(DTB)  ## rebuild the device tree only

# ---- A27 entry stub ----

# -fno-pie -no-pie -Wl,--build-id=none are not optional: distro gcc is usually
# --enable-default-pie, and -Ttext= with default PIE emits R_RISCV_RELATIVE
# relocations nobody applies; the build-id note lands below 0x83f00000 and objcopy
# places it ahead of the code, so the first thing the A27 executes out of reset is a
# note header. Both failures are a completely silent board.
# -march needs _zicsr_zifencei for the same reason as OpenSBI below: the stub uses
# csrw/csrs/csrr and fence.i, which binutils 2.36 moved out of base I. With the
# string added, both toolchains emit bytes identical to the golden file — a different
# spelling, not different instructions.
$(BUILD)/a27_stub.elf: $(TOP)/boot/a27_stub.S | $(BUILD)
	$(CROSS)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -fno-pie -no-pie \
	    -Wl,--build-id=none -Ttext=0x83f00000 -o $@ $<

$(STUB): $(BUILD)/a27_stub.elf
	$(CROSS)objcopy -O binary $< $@
	@cmp $@ $(TOP)/boot/a27_stub.bin.golden \
	  && echo "  stub matches golden (134 bytes)" \
	  || { echo "!! stub differs from boot/a27_stub.bin.golden. The toolchain changed"; \
	       echo "!! codegen. Diff $(CROSS)objdump -d $< first, check for PIE/note."; exit 1; }

stub: $(STUB)  ## build the A27 entry stub and compare against golden

# ---- initramfs ----

$(IRFS): $(TOP)/initramfs/initramfs.list.in $(TOP)/initramfs/prebuilt/busybox $(TOP)/initramfs/init.sh | $(BUILD)
	sed 's|@TOP@|$(TOP)|g' $< > $@

# ---- kernel ----

# CONFIG_INITRAMFS_SOURCE is an absolute path, so it is not written into the
# checked-in defconfig; it is injected here instead. That keeps the defconfig
# machine independent.
$(KOUT)/.config: $(TOP)/config/v821_rv32_defconfig $(IRFS) $(STAMP)
	install -Dm644 $(TOP)/config/v821_rv32_defconfig $(LINUX)/arch/riscv/configs/v821_rv32_defconfig
	$(KMAKE) v821_rv32_defconfig
	$(LINUX)/scripts/config --file $@ --set-str INITRAMFS_SOURCE $(IRFS)
	$(KMAKE) olddefconfig

kernel: $(KOUT)/.config $(IRFS) $(TOP)/initramfs/prebuilt/busybox $(TOP)/initramfs/init.sh  ## build the kernel Image (initramfs built in)
	$(KMAKE) -j$(NPROC) Image

$(IMAGE): kernel

menuconfig: $(KOUT)/.config  ## change config (run make config-diff afterwards)
	$(KMAKE) menuconfig

# ---- OpenSBI ----

# CC_SUPPORT_VECTOR=n: the A27 has no V extension, so building it in is dead code.
# (The flag started as a workaround for XuanTie binutils 2.35 not assembling vector
#  instructions. binutils 2.38 no longer needs it, but keeping it makes the firmware
#  contents match the one verified on hardware.)
#
# The ISA string needs _zicsr_zifencei: binutils 2.36 moved fence.i and the CSR
# instructions out of base I into Zifencei / Zicsr, and fw_base.S:829 has a fence.i.
# OpenSBI detects this itself (Makefile:322), but only when PLATFORM_RISCV_ISA is not
# passed explicitly — and we pass it, so we spell it out. binutils 2.35 (the XuanTie
# set) accepts the same spelling, so one string works for both.
fw: $(DTB) kernel $(STAMP)  ## pack kernel and dtb into an OpenSBI fw_payload
	$(MAKE) -C $(OPENSBI) PLATFORM=generic CROSS_COMPILE=$(CROSS) \
	    PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32imafdc_zicsr_zifencei \
	    PLATFORM_RISCV_ABI=ilp32d \
	    FW_TEXT_START=0x80000000 FW_PIC=y CC_SUPPORT_VECTOR=n \
	    FW_FDT_PATH=$(DTB) FW_PAYLOAD_PATH=$(IMAGE) -j$(NPROC)

# ---- gates before touching the board ----

verify: fw  ## dig the embedded FDT back out of fw_payload and read it
	@sh $(TOP)/scripts/verify-fw.sh $(FW)

check: verify $(STUB)  ## verify + static scan (the last host-side gate)
	@sh $(TOP)/scripts/check-image.sh $(CROSS) $(KOUT) $(BUILD) $(FW)

# ---- on the board ----

boot: check  ## boot over FEL (hold FEL, replug USB, then run this)
	python3 $(TOP)/scripts/felcpux.py --fw=$(FW) --stub=$(STUB) --log=$(BUILD)/felcpux.log --secs=120

# Reproduce the slow state where the A27 hangs directly off HOSC at 40 MHz. Control
# data only; do not use it for normal boots.
boot-nopll: check  ## slow-state control run (A27 on HOSC, ~205 s to shell)
	python3 $(TOP)/scripts/felcpux.py --fw=$(FW) --stub=$(STUB) --log=$(BUILD)/felcpux-nopll.log \
	    --no-pll --secs=700

# ---- reproduction ----

config-diff: $(KOUT)/.config  ## regenerate config/v821_rv32_defconfig and config/config-diff.txt
	@sh $(TOP)/scripts/config-diff.sh $(LINUX) $(KOUT) $(BUILD) $(CROSS) $(TOP)

# use -e to prevent error when there is no -*.patch file
patch-check: $(STAMP)  ## confirm the patches still line up with the pinned commits
	@for p in $(TOP)/patches/linux-*.patch; do \
	    [ -e "$$p" ] || continue; \
	    git -C $(LINUX) apply --check -R $$p && echo "  ok  $$(basename $$p)" \
	      || { echo "  FAIL $$(basename $$p)"; exit 1; }; done
	@for p in $(TOP)/patches/opensbi-*.patch; do \
	    [ -e "$$p" ] || continue; \
	    git -C $(OPENSBI) apply --check -R $$p && echo "  ok  $$(basename $$p)" \
	      || { echo "  FAIL $$(basename $$p)"; exit 1; }; done

# ---- cleaning ----

clean:  ## remove build products, keep the fetched sources
	rm -rf $(KOUT) $(DTB) $(STUB) $(BUILD)/a27_stub.elf $(IRFS)
	rm -f $(OPENSBI)/build/platform/generic/firmware/fw_payload.*

distclean:  ## also remove the fetched linux and opensbi (the linux clone is ~4 GB)
	rm -rf $(BUILD)
