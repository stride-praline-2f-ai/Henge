"""Execute the production far-chain emitter: linked/empty slots and host exits.
Unicorn checks guest state and generated instruction count, not device FPS.
"""
import json
import pathlib
import struct
import subprocess
import tempfile
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as reg

ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = r'''
#include "translate_for_test.c"
#include <assert.h>
#include <stdio.h>
int hv_knob[HV_K_COUNT],hv_tlb_tmajor=1;
__thread HvCpu *hv_self;
void hv_mmu_walk(HvCpu *c,uint64_t va,HvAccess a,int el,HvWalk *w){(void)c;(void)va;(void)a;(void)el;w->fsc=1;}
HvRam *hv_ram_lookup(HvMachine *m,uint64_t pa){(void)m;(void)pa;return NULL;}
int main(int argc,char **argv){
    (void)argc;static HvMachine m;static uint64_t slots[4],xa[4],pa[4];
    static Emit literal;literal.w=literal.hot;
    put_lit(&literal,6,0x123456789abcdef0ull);put_lit(&literal,7,0x123456789abcdef0ull);
    assert(literal.npool==1&&literal.fix[0].idx==literal.fix[1].idx);
    put_helper(&literal,0x123456789abcdef0ull,0xd503201f,HV_OP_MEM);
    assert(literal.npool==3&&literal.fix[2].kind==FIX_ADR&&literal.fix[2].idx==1);
    literal.pool[2]^=1;assert(literal.pool[0]==0x123456789abcdef0ull);
    static uint32_t *sites[4],*conds[4];
    m.slots=slots;m.slot_site=sites;m.slot_cond=conds;m.slot_xa=xa;m.slot_xpa=pa;m.max_slots=4;
    m.jit.capacity=(256u<<20)/4;
    E.m=&m;E.flat=1;E.w=E.hot;E.page=0x100000;E.cur_pc=atoi(argv[1])?0x100000:0x100200;
    put_branch_exit(&E,0x100100,1);
    if(E.n&1)put(&E,0xd503201f);
    unsigned pool=E.n;
    for(unsigned i=0;i<E.nfix;i++){
        LitFix *f=&E.fix[i];assert(f->kind==FIX_LDR);
        E.hot[f->at]|=((pool+f->idx*2-f->at)&0x7ffff)<<5;
    }
    for(unsigned i=0;i<E.npool;i++){put(&E,(uint32_t)E.pool[i]);put(&E,(uint32_t)(E.pool[i]>>32));}
    printf("{\"slot\":%llu,\"words\":[",(unsigned long long)(uintptr_t)slots);
    for(unsigned i=0;i<E.n;i++)printf("%s%u",i?",":"",E.hot[i]);puts("]}");
}
'''

with tempfile.TemporaryDirectory() as temp:
    p = pathlib.Path(temp)
    source = (ROOT/'core/translate.c').read_text()
    probe = '__asm__ volatile("mrs %0, dczid_el0" : "=r"(dczid));'
    (p/'translate_for_test.c').write_text(source.replace(probe, 'dczid=0;'))
    (p/'driver.c').write_text(DRIVER)
    subprocess.run(['cc','-std=c11','-D_POSIX_C_SOURCE=200809L','-O2','-ffunction-sections','-fdata-sections',
                    '-I'+str(ROOT/'core'),'-I'+str(ROOT/'host'),'-I'+str(ROOT/'devices'),
                    str(p/'driver.c'),'-Wl,--gc-sections','-o',str(p/'emit')],check=True)
    count = 0
    for forward in (0,1):
        fixture=json.loads(subprocess.check_output([str(p/'emit'),str(forward)]))
        for linked in (0,1):
            for requested in (0,1):
                u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
                code,cpu,entry,exitpc=0x100000,0x2000000,0x20000000,0x700000
                for address,size in ((code,65536),(cpu,65536),(entry,4096),(exitpc,4096),(fixture['slot']&-4096,4096)):
                    u.mem_map(address,size)
                u.mem_write(code,struct.pack('<'+'I'*len(fixture['words']),*fixture['words']))
                u.mem_write(fixture['slot'],struct.pack('<Q',entry if linked else 0))
                # Use real struct offsets emitted into generated instructions.
                for offset,value in ((0x3c0,requested),(0x3c8,0),(0xf0,0xfeed),(0x110,exitpc)):
                    u.mem_write(cpu+offset,struct.pack('<Q',value))
                for i in range(31):u.reg_write(getattr(reg,f'UC_ARM64_REG_X{i}'),0x9000+i)
                u.reg_write(reg.UC_ARM64_REG_X28,cpu);u.reg_write(reg.UC_ARM64_REG_NZCV,0xa0000000)
                steps=[];stopped=[]
                def hook(emu,pc,size,unused):
                    steps.append(pc)
                    if pc in (entry,exitpc):stopped.append(pc);emu.emu_stop()
                u.hook_add(UC_HOOK_CODE,hook)
                u.emu_start(code,0xffffffffffffffff,count=100)
                hit=linked and (forward or not requested)
                assert stopped==[entry if hit else exitpc],(forward,linked,requested,stopped)
                assert u.reg_read(reg.UC_ARM64_REG_X30)==0x901e
                assert struct.unpack('<Q',u.mem_read(cpu+0xf0,8))[0]==0xfeed
                assert u.reg_read(reg.UC_ARM64_REG_NZCV)==0xa0000000
                if not hit:
                    assert struct.unpack('<Q',u.mem_read(cpu+0x100,8))[0]==0x100100
                    expected_slot=fixture['slot'] if not linked and (forward or not requested) else 0
                    assert struct.unpack('<Q',u.mem_read(cpu+0x3c8,8))[0]==expected_slot
                else:
                    assert len(steps)-1<=7
                    for i in range(31):
                        if i not in (6,7,15,28):assert u.reg_read(getattr(reg,f'UC_ARM64_REG_X{i}'))==0x9000+i
                count+=1
    print(f'PASS far-chain emitter: {count} linked/empty/exit-request/forward cases; <=7 host instructions including guard, guest LR/NZCV preserved')
