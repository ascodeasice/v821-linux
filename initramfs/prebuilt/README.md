# prebuilt — why there is a binary in here

`busybox` is an rv32imac / ilp32 soft-float static ELF, checked straight into the repo.
It is here because **the distro riscv64 cross toolchain cannot build rv32 userspace**.

Arch's `riscv64-linux-gnu-gcc` depends on `riscv64-linux-gnu-glibc`, and that package
ships only `ld-linux-riscv64-lp64d.so.1` — none of its 1559 files is an `ilp32` or
`rv32` runtime. The package description's "Cross compiler for 32-bit and 64-bit RISC-V"
refers to binutils' BFD target coverage, not to having an rv32 libc. Actually trying it
stops at:

```
riscv64-linux-gnu-ld: cannot find crt1.o: No such file or directory
riscv64-linux-gnu-ld: cannot find -lc
```

The kernel, OpenSBI and `a27_stub` are unaffected: all three are freestanding
throughout and link neither libc nor libgcc (the kernel's `__ashldi3` and friends come
from `CONFIG_GENERIC_LIB_*`, OpenSBI's 64-bit division from `lib/utils/libquad/`). So
userspace is the only piece that needs a prebuilt.

## The file

| File | Size | sha256 |
|---|---|---|
| `busybox` | 1670248 | `12a7a01837e7e3ff5f6c8a663d810c674081e12a84413b9a7876568a4228f092` |

It is:

```
ELF 32-bit LSB executable, UCB RISC-V, RVC, soft-float ABI, statically linked
Tag_RISCV_arch: rv32i2p0_m2p0_a2p0_c2p0
```

The ABI has to match the `riscv,isa-extensions = "i","m","a","c"` declared in
`boot/v821-min.dts`. A hard-float (ilp32d) build SIGILLs on the `fsd` instruction in
glibc's `__sigsetjmp`: the dts does not declare F/D, so the kernel never enables the
FPU and the first floating-point instruction is an illegal instruction.

## Rebuilding it yourself

You need a toolchain with an rv32 static libc. Two options:

**XuanTie (what was originally used; the hardware-verified binary came from it)**

```sh
# busybox 1.33.2, configured from config/busybox-rv32.config
make CROSS_COMPILE=<xuantie>/bin/riscv64-unknown-linux-gnu- -j$(nproc)
```

**zig (one package brings its own musl source, no multilib problem; not yet verified
on hardware)**

```sh
zig cc -target riscv32-linux-musl -mcpu=generic_rv32+m+a+c -static -Os ...
```

busybox 1.33.2 is from 2021 and does not pin `-std`, so building it with gcc 15 runs
into the gnu23 default (`bool`/`true`/`false` become keywords); add `-std=gnu11` to
`CONFIG_EXTRA_CFLAGS`.
