# prebuilt — 為什麼這裡有一個 binary

`busybox` 是 rv32imac / ilp32 soft-float 的 static ELF，直接 check 進 repo。
會這樣做是因為**發行版的 riscv64 cross toolchain 編不出 rv32 的 userspace**。

Arch 的 `riscv64-linux-gnu-gcc` 依賴 `riscv64-linux-gnu-glibc`，而那個套件只有
`ld-linux-riscv64-lp64d.so.1`，整包 1559 個檔案裡沒有任何 `ilp32` 或 `rv32` 的
runtime。套件描述寫的「Cross compiler for 32-bit and 64-bit RISC-V」講的是
binutils 的 BFD 目標覆蓋，不是有 rv32 的 libc。實際去編會停在：

```
riscv64-linux-gnu-ld: cannot find crt1.o: No such file or directory
riscv64-linux-gnu-ld: cannot find -lc
```

kernel、OpenSBI、`a27_stub` 不受影響，它們全程 freestanding、不連 libc 也不連 libgcc
（kernel 的 `__ashldi3` 之類來自 `CONFIG_GENERIC_LIB_*`，OpenSBI 的 64-bit 除法來自
`lib/utils/libquad/`）。所以只有 userspace 這一塊需要 prebuilt。

## 檔案

| 檔案 | 大小 | sha256 |
|---|---|---|
| `busybox` | 1670248 | `12a7a01837e7e3ff5f6c8a663d810c674081e12a84413b9a7876568a4228f092` |

它是：

```
ELF 32-bit LSB executable, UCB RISC-V, RVC, soft-float ABI, statically linked
Tag_RISCV_arch: rv32i2p0_m2p0_a2p0_c2p0
```

ABI 必須跟 `boot/v821-min.dts` 宣告的 `riscv,isa-extensions = "i","m","a","c"` 一致。
換成 hard-float（ilp32d）的版本會在 glibc `__sigsetjmp` 的 `fsd` 指令上 SIGILL——
dts 沒有宣告 F/D，kernel 就不開 FPU，第一條浮點指令直接 illegal instruction。

## 要自己重編的話

需要一套帶 rv32 static libc 的 toolchain。兩條路：

**XuanTie（原本用的，實機驗過的就是這顆編的）**

```sh
# busybox 1.33.2，config 用 config/busybox-rv32.config
make CROSS_COMPILE=<xuantie>/bin/riscv64-unknown-linux-gnu- -j$(nproc)
```

**zig（一個套件就有 musl 原始碼，沒有 multilib 問題，還沒實機驗過）**

```sh
zig build-exe -target riscv32-linux-musl ...   # 還沒實際跑過 busybox 這一套
```

busybox 1.33.2 是 2021 年的東西，沒有 pin `-std`，用 gcc 15 編會撞上 gnu23 的預設
（`bool`/`true`/`false` 變成關鍵字），要在 `CONFIG_EXTRA_CFLAGS` 補 `-std=gnu11`。
