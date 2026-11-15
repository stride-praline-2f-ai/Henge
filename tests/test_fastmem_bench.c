/* Real EL1 JIT reads through real 16KB page tables. Paired cache-off/on,
   warmed loops and identical sums; no claims about physical Duo watts/FPS. */
#include "machine.h"
#include "dispatch.h"
#include "fastmem.h"
#include "mmu.h"
#include "memop.h"
#include <mach/mach_time.h>
#include <pthread/qos.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PG 16384u
#define PA 0x80000000ull
static HvMachine m;
static HvCpu cpu;
static unsigned char *ram;
static unsigned next = 1;
static const uint64_t code_va = 0xfffffe0000100000ull;
static const uint64_t data_a = 0xfffffe0000200000ull, data_b = 0xfffffc0400204000ull;
static const uint64_t data_user = 0x200000;
static const uint64_t data_c = 0xfffffe0010200000ull; // same ordinary TLB slot, different cache slot
static uint64_t *tab(unsigned p) { return (uint64_t *)(ram + p * PG); }
static void map(uint64_t va, unsigned physical) {
    uint64_t *l2 = &tab(0)[(va >> 36) & 63];
    if (!*l2) *l2 = (PA + next++ * PG) | 3;
    uint64_t *l3 = &tab((unsigned)((*l2 & ~0x3fffull) - PA) / PG)[(va >> 25) & 2047];
    if (!*l3) *l3 = (PA + next++ * PG) | 3;
    tab((unsigned)((*l3 & ~0x3fffull) - PA) / PG)[(va >> 14) & 2047] = (PA + physical * PG) | 3 | (1u << 10);
}
static void run(unsigned mixed, unsigned count) {
    cpu.pc = code_va; cpu.x[0] = mixed == 3 ? data_user : data_a; cpu.x[4] = mixed && mixed != 3 ? data_a ^ (mixed == 2 ? data_c : data_b) : 0;
    cpu.x[2] = 0; cpu.x[3] = count;
    assert(hv_run(&cpu) == HV_EXIT_HALT);
    assert(cpu.x[2] == count && cpu.x[3] == 0);
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    assert(!pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0));
    assert(!hv_machine_init(&m, 4 << 20));
    ram = aligned_alloc(PG, 16 * PG); assert(ram); memset(ram, 0, 16 * PG);
    assert(!hv_machine_add_ram(&m, PA, 16 * PG, ram, 0));
    const uint32_t code[] = {0xf9400001, 0xca040000, 0x8b010042, 0xf1000463, 0x54ffff81};
    memcpy(ram + 10 * PG, code, sizeof code);
    *(uint64_t *)(ram + 11 * PG) = *(uint64_t *)(ram + 12 * PG) = *(uint64_t *)(ram + 13 * PG) = 1;
    map(code_va, 10); map(data_a, 11); map(data_b, 12); map(data_c, 13); map(data_user, 11);
    m.stop_pc = code_va + sizeof code;
    mach_timebase_info_data_t tb; assert(!mach_timebase_info(&tb));
    // More rounds alternate the order to limit shared-runner drift.
    for (unsigned round = 0; round < 7; round++) for (unsigned mixed = 0; mixed < 4; mixed++)
        for (unsigned k = 0; k < 2; k++) {
            unsigned enabled = k ^ (round & 1);
            m.fastmem_enabled = enabled; m.fastmem_diagnostics = 0;
            hv_flush_blocks(&m); hv_cpu_reset(&cpu, &m);
            cpu.sctlr_el1 |= 1; cpu.ttbr0_el1 = cpu.ttbr1_el1 = PA; cpu.mair_el1 = 0xff;
            cpu.tcr_el1 = 22ull | 2ull << 14 | 22ull << 16 | 1ull << 30;
            cpu.cpacr_el1 = 3u << 20; cpu.el = 1;
            // Both implementations see a kernel read before user pointers,
            // as in the real guest. Do not time the old cache with base zero.
            run(0, 1000);
            run(mixed, 1000);
            uint64_t begin = mach_absolute_time();
            unsigned count = mixed == 2 ? 20000000 : 50000000;
            run(mixed, count);
            double ns = (double)(mach_absolute_time() - begin) * tb.numer / tb.denom;
            printf("fastmem-bench: round=%u mixed=%u enabled=%u ns_per_load=%.3f result=%u\n", round, mixed, enabled, ns / count, count);
        }
    /* The isolated before/after builds execute this SAME complete helper.
       tests/helper-read-baseline.patch restores only the old helper's RAM
       resolution path in the isolated before fixture, never the app. */
    m.stats_interval = 0;
    run(0, 1000);
    for (unsigned round = 0; round < 3; round++) {
        unsigned count = 500000;
        uint64_t sum = 0, begin = mach_absolute_time();
        for (unsigned i = 0; i < count; i++) {
            uint64_t value;
            assert(!hv_vmem_xfer(&cpu, data_a, &value, sizeof value, 0, 1, 0));
            sum += value;
        }
        double ns = (double)(mach_absolute_time() - begin) * tb.numer / tb.denom;
        assert(sum == count);
        printf("helper-read-bench: round=%u ns_per_read=%.3f checksum=%llu\n",
               round, ns / count, (unsigned long long)sum);
    }
    /* Exercise the new coalesced path, not just an eight-byte helper read.
       Cross three internal 4KB boundaries within one validated 16KB page. */
    unsigned char span[12288];
    memset(ram + 11 * PG + 4090, 0x35, sizeof span);
    for (unsigned round = 0; round < 3; round++) {
        unsigned count = 20000;
        uint64_t sum = 0, begin = mach_absolute_time();
        for (unsigned i = 0; i < count; i++) {
            assert(!hv_vmem_xfer(&cpu, data_a + 4090, span, sizeof span, 0, 1, 0));
            sum += span[0] + span[sizeof span - 1];
        }
        double ns = (double)(mach_absolute_time() - begin) * tb.numer / tb.denom;
        assert(sum == (uint64_t)count * 0x35 * 2);
        printf("helper-span-bench: round=%u ns_per_read=%.3f checksum=%llu\n", round, ns / count, (unsigned long long)sum);
    }
    hv_machine_free(&m); free(ram);
    puts("PASS fastmem benchmark: real EL1/page-table/JIT path; all guest sums identical");
}
