/*
 * mainline/init/cycfreq.c — 直接量 A27 的 CPU 時脈。
 *
 * 為什麼需要它：mainline 的 v821-min.dts 沒有 clock provider（沒有 CCU 節點），
 * 所以 /sys/kernel/debug/clk/clk_summary 是空的，量不到 CPU 跑多快。shell 迴圈
 * 只能給「快慢比例」。這支程式給絕對值。
 *
 * 原理：用兩個計數器互相校準。
 *   - rdtime  = mtime，頻率已知且驗證過（DTB timebase-frequency 40 MHz，
 *               §21.3 用 sleep 5 量到 5.06s 證明準確）。
 *   - rdcycle = CPU cycle counter，跟著 CPU 時脈走。
 * 在固定的 mtime 區間內數 cycle，cycles / seconds 就是 CPU Hz。
 *
 * rdcycle 在 U-mode 需要 scounteren 的 CY bit。A27 對 SCOUNTEREN 的寫入會
 * uncatchable-fault，OpenSBI 那條路徑是被 skip 掉的（claude-report.md §21 之前），
 * 所以 rdcycle 有可能直接 SIGILL。攔下來、印出來，改用方法 B。
 *
 * 方法 B（不需要 rdcycle）：跑固定指令數的迴圈，用 rdtime 計時。每圈 2 條指令
 * （addi + bnez），A27L2 是 in-order，估 2 cycles/圈。這只有數量級精度，但足以
 * 分辨 24 MHz 與 960 MHz。
 *
 * Build（一定要 soft-float）：
 *   $CROSS-gcc -march=rv32imac -mabi=ilp32 -static -O2 -o cycfreq cycfreq.c
 *
 * 用 -march=rv32imafdc -mabi=ilp32d 編，會在板上死在 SIGILL：glibc 的 __sigsetjmp 用
 * `fsd` 存浮點暫存器，而我們的 DT 沒有 F/D（riscv,isa-extensions = i m a c …），kernel
 * 不開 FPU，第一個浮點指令就 illegal instruction。實測過，見 claude-report.md §30.10。
 */

#include <stdio.h>
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>

/* DTB 的 timebase-frequency。改 dts 的話這裡要跟著改。 */
#define TIMEBASE_HZ	40000000ULL
/* 量測窗：0.5 秒。慢速態（~24 MHz）也只要跑 0.5s，不拖長開機。 */
#define WINDOW_TICKS	(TIMEBASE_HZ / 2)
/* 方法 B 的迴圈圈數。40 MHz 下約 0.15s，960 MHz 下約 6ms。 */
#define LOOP_ITERS	1000000
/*
 * 每圈的 cycle 數。原本假設 2（addi + bnez），實測是 6.15：2026-08-13 在已知
 * 960MHz（暫存器 N=48/D=2、HOSC 40MHz）下量到 155.98e6 iters/s，960e6/155.98e6
 * = 6.15。同一支迴圈在 1600MHz 設定下量到 251.80e6 iters/s，1600e6/251.80e6
 * = 6.35，兩者一致 => taken branch 在 A27 上大約要 6 個 cycle。見 §30.10。
 */
#define CYCLES_PER_ITER_X100	615

static sigjmp_buf illjmp;
static void on_sigill(int sig) { (void)sig; siglongjmp(illjmp, 1); }

/* RV32 的 64-bit CSR 要讀 hi/lo/hi 三次防跨位進位。 */
#define DEFINE_RD64(name, lo, hi)					\
	static uint64_t name(void)					\
	{								\
		uint32_t h0, l, h1;					\
		do {							\
			asm volatile("csrr %0, " hi : "=r"(h0));	\
			asm volatile("csrr %0, " lo : "=r"(l));		\
			asm volatile("csrr %0, " hi : "=r"(h1));	\
		} while (h0 != h1);					\
		return ((uint64_t)h1 << 32) | l;			\
	}

DEFINE_RD64(rd_time,  "time",  "timeh")
DEFINE_RD64(rd_cycle, "cycle", "cycleh")

/* 固定指令數的迴圈。volatile asm，編譯器不會把它最佳化掉。 */
static void spin(unsigned long iters)
{
	asm volatile("1: addi %0, %0, -1\n"
		     "   bnez %0, 1b\n"
		     : "+r"(iters) :: "memory");
}

int main(int argc, char **argv)
{
	volatile uint64_t t0, t1, c0, c1;
	/* 圈數可由參數覆寫：切到很慢的時脈量測時要調小，否則要跑很久。 */
	unsigned long iters = LOOP_ITERS;

	if (argc > 1)
		iters = strtoul(argv[1], NULL, 0);

	signal(SIGILL, on_sigill);

	/* --- 方法 A：rdcycle 對 rdtime --- */
	if (sigsetjmp(illjmp, 1) == 0) {
		c0 = rd_cycle();
		t0 = rd_time();
		while (rd_time() - t0 < WINDOW_TICKS)
			;
		t1 = rd_time();
		c1 = rd_cycle();
		printf("CYCFREQ_A_HZ=%llu cycles=%llu ticks=%llu\n",
		       (unsigned long long)((c1 - c0) * TIMEBASE_HZ / (t1 - t0)),
		       (unsigned long long)(c1 - c0),
		       (unsigned long long)(t1 - t0));
	} else {
		printf("CYCFREQ_A_HZ=unavailable (SIGILL: rdcycle/rdtime 在 U-mode 被擋，"
		       "scounteren 沒開)\n");
	}

	/* --- 方法 B：固定指令數迴圈，只靠 rdtime --- */
	if (sigsetjmp(illjmp, 1) == 0) {
		t0 = rd_time();
		spin(iters);
		t1 = rd_time();
		printf("CYCFREQ_B_ITERS_PER_S=%llu iters=%lu ticks=%llu  => %llu Hz "
		       "(x%d.%02d cycles/iter, 校準值)\n",
		       (unsigned long long)((uint64_t)iters * TIMEBASE_HZ / (t1 - t0)),
		       iters,
		       (unsigned long long)(t1 - t0),
		       (unsigned long long)((uint64_t)iters * TIMEBASE_HZ /
					    (t1 - t0) * CYCLES_PER_ITER_X100 / 100),
		       CYCLES_PER_ITER_X100 / 100, CYCLES_PER_ITER_X100 % 100);
	} else {
		printf("CYCFREQ_B_HZ=unavailable (SIGILL)\n");
	}
	return 0;
}
