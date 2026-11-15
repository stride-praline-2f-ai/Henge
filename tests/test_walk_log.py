"""Exercise production walk-log decisions, including conservative fallbacks.
Native MMU/JIT tests separately cover actual remote drops and instruction runs.
"""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[1];s=(root/'core/mmu.c').read_text()
a=s.index('static int walks_elsewhere(');b=s.index('{',a);e=b+1;depth=1
while depth:
    depth+=(s[e]=='{')-(s[e]=='}');e+=1
function=s[a:e]
defines='\n'.join(line for line in s.splitlines() if line.startswith(('#define HV_WALK_ANY ','#define WALK_LOG ','#define WALK_PAGE_BITS ')))
code=r'''
#include "machine.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int hv_knob[HV_K_COUNT];
static HvMachine m; static HvCpu c;
'''+defines+'\n'+function+r'''
int main(void) {
 c.m=&m;c.pc_state=&m.percpu[0];HvPerCpu *p=c.pc_state;
 const uint64_t P=0x100004000ull,Q=P+0x4000;
 hv_knob[HV_K_WALKLOG]=1;
 p->walk_page[0]=Q;p->walk_seq=1;
 assert(walks_elsewhere(&c,1,1,P,1));
 assert(!walks_elsewhere(&c,1,1,P,2)); // real overlap, not just equality
 p->walk_page[0]=P;assert(!walks_elsewhere(&c,1,1,P,1));
 p->walk_page[0]=HV_WALK_ANY;assert(!walks_elsewhere(&c,1,1,P,1));
 p->walk_page[0]=Q;p->walk_seq=2;
 assert(walks_elsewhere(&c,0,2,P,1)); // walk ran while the drop was in progress
 assert(walks_elsewhere(&c,0,2,0xab00000000000000ull|P,1));
 p->walk_page[0]=P;assert(!walks_elsewhere(&c,0,2,0xab00000000000000ull|P,1));
 for(int k=0;k<8;k++)p->walk_page[k]=Q;
 p->walk_seq=14;assert(walks_elsewhere(&c,0,14,P,1));
 p->walk_seq=16;assert(!walks_elsewhere(&c,0,16,P,1)); // overwritten/uncertain log
 p->walk_seq=18;assert(!walks_elsewhere(&c,0,2,P,1)); // later reuse after sampled end
 assert(!walks_elsewhere(&c,0,18,P,1));
 p->walk_seq=2;assert(!walks_elsewhere(&c,UINT32_MAX-3,2,P,1)); // sequence wrap is conservative
 hv_knob[HV_K_WALKLOG]=0;
 assert(!walks_elsewhere(&c,0,2,P,1));assert(walks_elsewhere(&c,2,2,P,1));
 puts("walk log: overlap, other page, tagged VA, process switch, intervening walks, reuse, overflow, wrap and disabled fallback passed");
}
'''
with tempfile.TemporaryDirectory(prefix='henge-walk-log-') as tmp:
    p=Path(tmp);(p/'check.c').write_text(code)
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-O1','-g','-fsanitize=address,undefined',
                    '-I'+str(root/'core'),'-I'+str(root/'host'),str(p/'check.c'),'-o',str(p/'check')],check=True)
    subprocess.run([str(p/'check')],check=True,timeout=10)
