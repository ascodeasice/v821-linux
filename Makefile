# V821 (RV32) mainline Linux — 建置 DAG
#
#   make            # = make check：需要什麼就編什麼，最後跑上板前的靜態關卡
#   make boot       # check 通過後進 FEL 開機（板子要先按 FEL 鈕重插 USB）
#   make help       # 列出所有 target
#
# 為什麼要有這個 DAG：手打三行指令時，順序錯一次（先 dtc 才改 .dts、或改完 dts
# 只跑到第 2 步）就會靜靜包到舊的 dtb，板子照常開機、只是跑錯設定。

TOP   := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD ?= $(TOP)/build
include $(TOP)/pins.env

LINUX   ?= $(BUILD)/linux
OPENSBI ?= $(BUILD)/opensbi
KOUT    ?= $(BUILD)/kernel

# 不要叫 O。kernel kbuild 用 O= 指定輸出目錄，但 OpenSBI 的 Makefile:24 也有
# ifdef O，而 make 會把環境變數當成 make 變數——所以 shell 裡只要 export 過 O，
# OpenSBI 就會把 fw_payload 蓋到那個目錄，於是「make 明明成功、燒上去的卻是舊的」。
unexport O

# 預設用發行版的 cross toolchain（Arch: pacman -S riscv64-linux-gnu-gcc）。
# 要換 XuanTie 就 make CROSS=/abs/path/to/riscv64-unknown-linux-gnu-。
# 帶路徑的 CROSS 一律轉絕對路徑：make -C 會切到 kernel tree 執行，相對路徑會被
# 解析到那邊去，kconfig 的 syncconfig 會在最前面就以 "C compiler not found" 死掉。
CROSS ?= riscv64-linux-gnu-
ifneq ($(findstring /,$(CROSS)),)
CROSS := $(abspath $(dir $(CROSS)))/$(notdir $(CROSS))
endif

NPROC ?= $(shell nproc 2>/dev/null || echo 4)
KMAKE := $(MAKE) -C $(LINUX) O=$(KOUT) ARCH=riscv CROSS_COMPILE=$(CROSS)

# 位元組可重現：兩個人在不同機器、不同目錄下編，要得到同一顆 fw_payload.bin。
# 不設的話有兩個變動來源——kernel banner 的建置時間，以及 initramfs cpio 標頭裡
# 的檔案 mtime（git checkout 出來的時間各人不同）。這個變數兩處都管：
# banner 直接用它，cpio 是 usr/Makefile:67 把它當 gen_initramfs.sh 的 -d 傳進去。
# 要看真實建置時間就 make KBUILD_BUILD_TIMESTAMP="$(date)"。
export KBUILD_BUILD_TIMESTAMP ?= 2026-08-13 00:00:00 UTC
export KBUILD_BUILD_USER      ?= v821
export KBUILD_BUILD_HOST      ?= v821-linux
# banner 的 #N 來自 objtree 的 .version，每 link 一次就加一，所以同一份原始碼在
# 「編過幾次的樹」與「剛 clone 的樹」會得到不同的數字（init/Makefile:32）。
export KBUILD_BUILD_VERSION   ?= 1

DTS   := $(TOP)/v821-min.dts
DTB   := $(BUILD)/v821-min.dtb
IRFS  := $(BUILD)/initramfs.list
IMAGE := $(KOUT)/arch/riscv/boot/Image
STUB  := $(BUILD)/a27_stub.bin
FW    := $(OPENSBI)/build/platform/generic/firmware/fw_payload.bin
STAMP := $(BUILD)/.src-stamp

.PHONY: all help tools src dtb stub kernel fw verify check boot boot-nopll \
        config-diff patch-check menuconfig clean distclean

all: check  ## 編到上板前的靜態關卡（預設）

help:  ## 列出 target
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t28

$(BUILD):
	@mkdir -p $@

# ---- 工具鏈與原始碼 ----

tools:  ## 檢查 host 工具與 cross toolchain 真的能編 rv32
	@sh $(TOP)/check-tools.sh $(CROSS)

$(STAMP): $(TOP)/pins.env $(wildcard $(TOP)/linux-*.patch) $(wildcard $(TOP)/opensbi-*.patch) | $(BUILD)
	@BUILD=$(BUILD) sh $(TOP)/fetch.sh
	@touch $@

src: $(STAMP)  ## 抓 linux 與 opensbi 到釘住的 commit 並套 patch

# ---- device tree ----

# -p 0x4000 不可省：OpenSBI 是原地 fixup 這顆 FDT（fw_base.S 的 lla a1, fw_fdt_bin），
# padding 就是 fdt_open_into() 撐大時要用的空間。
$(DTB): $(DTS) | $(BUILD)
	dtc -O dtb -p 0x4000 -o $@ $<

dtb: $(DTB)  ## 只重編 device tree

# ---- A27 entry stub ----

# -fno-pie -no-pie -Wl,--build-id=none 不可省：發行版 gcc 多半是 --enable-default-pie，
# 而 -Ttext= 配 default PIE 會產生沒人套用的 R_RISCV_RELATIVE relocation；
# build-id note 則會拿到 0x83f00000 以下的位址，objcopy 會把 note 排在 code 前面，
# A27 出 reset 後第一件事就是執行 note header。兩種都是板子全靜音、沒有任何訊息。
$(BUILD)/a27_stub.elf: $(TOP)/a27_stub.S | $(BUILD)
	$(CROSS)gcc -march=rv32imac -mabi=ilp32 -nostdlib -fno-pie -no-pie \
	    -Wl,--build-id=none -Ttext=0x83f00000 -o $@ $<

$(STUB): $(BUILD)/a27_stub.elf
	$(CROSS)objcopy -O binary $< $@
	@cmp $@ $(TOP)/a27_stub.bin.golden \
	  && echo "  stub 與 golden 相同（134 bytes）" \
	  || { echo "!! stub 與 a27_stub.bin.golden 不同。toolchain 換了 codegen，"; \
	       echo "!! 上板前先用 $(CROSS)objdump -d $< 對照，確認沒有多出 PIE/note。"; exit 1; }

stub: $(STUB)  ## 編 A27 entry stub 並與 golden 比對

# ---- initramfs ----

$(IRFS): $(TOP)/initramfs.list.in $(TOP)/prebuilt/busybox $(TOP)/prebuilt/cycfreq $(TOP)/init.sh | $(BUILD)
	sed 's|@TOP@|$(TOP)|g' $< > $@

# ---- kernel ----

# CONFIG_INITRAMFS_SOURCE 是絕對路徑，所以不寫進 checked-in 的 defconfig，
# 改成這裡注入。這樣 defconfig 本身跟機器無關。
$(KOUT)/.config: $(TOP)/v821_rv32_defconfig $(IRFS) $(STAMP)
	install -Dm644 $(TOP)/v821_rv32_defconfig $(LINUX)/arch/riscv/configs/v821_rv32_defconfig
	$(KMAKE) v821_rv32_defconfig
	$(LINUX)/scripts/config --file $@ --set-str INITRAMFS_SOURCE $(IRFS)
	$(KMAKE) olddefconfig

kernel: $(KOUT)/.config $(IRFS) $(TOP)/prebuilt/busybox $(TOP)/prebuilt/cycfreq $(TOP)/init.sh  ## 編 kernel Image（initramfs 內建）
	$(KMAKE) -j$(NPROC) Image

$(IMAGE): kernel

menuconfig: $(KOUT)/.config  ## 改 config（改完記得 make config-diff 更新 defconfig）
	$(KMAKE) menuconfig

# ---- OpenSBI ----

# CC_SUPPORT_VECTOR=n：A27 沒有 V extension，編進去只是死碼。
# （這個旗標最早是為了繞過 XuanTie binutils 2.35 組不出 vector 指令，
#   binutils 2.38 之後已經不需要，但保留它可以讓 firmware 內容跟實機驗過的那顆一致。）
fw: $(DTB) kernel $(STAMP)  ## 把 kernel 與 dtb 包進 OpenSBI fw_payload
	$(MAKE) -C $(OPENSBI) PLATFORM=generic CROSS_COMPILE=$(CROSS) \
	    PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32imafdc PLATFORM_RISCV_ABI=ilp32d \
	    FW_TEXT_START=0x80000000 FW_PIC=y CC_SUPPORT_VECTOR=n \
	    FW_FDT_PATH=$(DTB) FW_PAYLOAD_PATH=$(IMAGE) -j$(NPROC)

# ---- 上板前的關卡 ----

verify: fw  ## 把內嵌的 FDT 從 fw_payload 挖出來看
	@sh $(TOP)/verify-fw.sh $(FW)

check: verify $(STUB)  ## verify + 靜態掃描（最後一道 host 端關卡）
	@sh $(TOP)/check-image.sh $(CROSS) $(KOUT) $(BUILD) $(FW)

# ---- 上板 ----

boot: check  ## 進 FEL 開機（按 FEL 鈕重插 USB 之後再跑）
	python3 $(TOP)/felcpux.py --fw=$(FW) --stub=$(STUB) --log=$(BUILD)/felcpux.log --secs=120

# 重現「A27 直接掛在 HOSC 40 MHz」的慢速態。只用來取對照數據，平常不要用。
boot-nopll: check  ## 慢速態對照組（A27 掛 HOSC，開機要 ~205 秒）
	python3 $(TOP)/felcpux.py --fw=$(FW) --stub=$(STUB) --log=$(BUILD)/felcpux-nopll.log \
	    --no-pll --secs=700

# ---- 重現用 ----

config-diff: $(KOUT)/.config  ## 重產 v821_rv32_defconfig 與 config-diff.txt
	@sh $(TOP)/config-diff.sh $(LINUX) $(KOUT) $(BUILD) $(CROSS) $(TOP)

patch-check: $(STAMP)  ## 確認 patch 仍然對得上釘住的 commit
	@for p in $(TOP)/linux-*.patch; do \
	    git -C $(LINUX) apply --check -R $$p && echo "  ok  $$(basename $$p)" \
	      || { echo "  FAIL $$(basename $$p)"; exit 1; }; done
	@for p in $(TOP)/opensbi-*.patch; do \
	    git -C $(OPENSBI) apply --check -R $$p && echo "  ok  $$(basename $$p)" \
	      || { echo "  FAIL $$(basename $$p)"; exit 1; }; done

# ---- 清理 ----

clean:  ## 砍 build 產物，保留抓下來的原始碼
	rm -rf $(KOUT) $(DTB) $(STUB) $(BUILD)/a27_stub.elf $(IRFS)
	rm -f $(OPENSBI)/build/platform/generic/firmware/fw_payload.*

distclean:  ## 連抓下來的 linux 與 opensbi 一起砍（linux clone 大約 4 GB，重抓很久）
	rm -rf $(BUILD)
