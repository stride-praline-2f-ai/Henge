/* Native A/B of the production generated lookup, not a power/FPS benchmark. */
#include "machine.h"
#include "dispatch.h"
#include <mach/mach_time.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HvMachine m;
static HvCpu cpu;
/* LDR; next page; wrap at end; sum; loop. No grouped accesses. */
static uint32_t code[4096] __attribute__((aligned(16384))) = {
    0xf9400001, 0x91401000, 0xeb04001f, 0x9a8020a0,
    0x8b010042, 0xf1000463, 0x54ffff41
};
static void run(unsigned char *data, unsigned pages, unsigned iterations) {
    cpu.pc = (uintptr_t)code;
    cpu.x[0] = cpu.x[5] = (uintptr_t)data;
    cpu.x[4] = (uintptr_t)data + (uint64_t)pages * 16384;
    cpu.x[2] = 0;
    cpu.x[3] = iterations;
    assert(hv_run(&cpu) == HV_EXIT_HALT);
    assert(cpu.x[2] == iterations && cpu.x[3] == 0);
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    assert(!hv_machine_init(&m, 4 << 20));
    unsigned char *data = aligned_alloc(16384, 64 << 20);
    assert(data);
    memset(data, 0, 64 << 20);
    for (unsigned i = 0; i < 4096; i++) *(uint64_t *)(data + i * 16384) = 1;
    assert(!hv_machine_add_ram(&m, (uintptr_t)code, sizeof code, code, 1));
    assert(!hv_machine_add_ram(&m, (uintptr_t)data, 64 << 20, data, 0));
    m.stop_pc = (uintptr_t)(code + 7);
    const unsigned sizes[] = {1, 256, 4096};
    mach_timebase_info_data_t tb;
    assert(!mach_timebase_info(&tb));
    for (unsigned round = 0; round < 5; round++) for (unsigned s = 0; s < 3; s++)
        for (unsigned k = 0; k < 2; k++) {
            unsigned enabled = k ^ (round & 1);
            m.tlb_preload = enabled;
            hv_flush_blocks(&m);
            hv_cpu_reset(&cpu, &m);
            cpu.cpacr_el1 = 3u << 20;
            cpu.el = 0;
            cpu.spsel = 0;
            run(data, sizes[s], sizes[s] * 2);
            uint64_t begin = mach_absolute_time();
            run(data, sizes[s], 500000);
            double ns = (double)(mach_absolute_time() - begin) * tb.numer / tb.denom;
            printf("tlb-preload-bench: round=%u pages=%u enabled=%u ns_per_load=%.3f result=500000\n",
                   round, sizes[s], enabled, ns / 500000);
        }
    hv_machine_free(&m);
    free(data);
    puts("PASS TLB preload: paired warmed memory walks, identical guest sums");
}
