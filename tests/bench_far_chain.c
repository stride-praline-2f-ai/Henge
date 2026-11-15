#include "machine.h"
#include "translate.h"
#include "dispatch.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <unistd.h>

/* The real emitter and entry/exit assembly, with a target deliberately beyond
   A64 B's128MiB range. No guest kernel, display or power claim is involved. */
static HvMachine machines[2];
static HvCpu cpus[2];
static HvBlock blocks[2];
static unsigned words[2];
int main(void) {
    alarm(60);mach_timebase_info_data_t tb;assert(!mach_timebase_info(&tb));
    for(unsigned reference=0;reference<2;reference++) {
        HvMachine *m=&machines[reference];assert(!hv_machine_init(m,256u<<20));
        m->chain=1;m->chain_stub_reference=(int)reference;hv_cpu_reset(&cpus[reference],m);
        HvBlock *b=&blocks[reference];b->va=b->pa=0x100200;
        const uint32_t code[]={0x17ffffc0}; /* B to0x100100, same guest page */
        assert(!hv_translate_block(m,b,code,1));assert(m->nslots==1);
        words[reference]=hv_translate_pending_words();
        uint32_t *far=m->jit.base+(192u<<20)/4;
        assert(far-b->code>(1<<25));
        uint64_t entry=(uint64_t)(uintptr_t)b->code;
        const uint32_t target[]={0xf1000400,0x54000060,0x580000cf,0xd61f01e0,
                                0xa9000780,0xf9408b8f,0xd61f01e0,0xd503201f,
                                (uint32_t)entry,(uint32_t)(entry>>32)};
        hv_jit_write(&m->jit,far,target,sizeof target);hv_jit_finish(&m->jit,far,sizeof target/4);
        __atomic_store_n(&m->slots[0],(uint64_t)(uintptr_t)far,__ATOMIC_RELEASE);
    }
    for(unsigned round=0;round<7;round++)for(unsigned k=0;k<2;k++) {
        unsigned reference=k^(round&1);HvCpu *cpu=&cpus[reference];HvMachine *m=&machines[reference];
        cpu->x[0]=500000;cpu->x[1]=0x1234;cpu->x[30]=0x87654321;
        uint64_t begin=mach_absolute_time();hv_enter(cpu,blocks[reference].code);
        double ns=(double)(mach_absolute_time()-begin)*tb.numer/tb.denom;
        assert(!cpu->x[0]&&cpu->x[1]==0x1234&&cpu->x[30]==0x87654321);
        printf("far-chain-bench: round=%u inline=%u ns_per_iteration=%.3f guest_result=0 slots=%u emitted_words=%u\n",round,!reference,ns/500000,m->nslots,words[reference]);
    }
    hv_machine_free(&machines[0]);hv_machine_free(&machines[1]);
    puts("PASS native far chains: paired generated code beyond128MiB, identical guest registers and real host entry/exit");
    return 0;
}
