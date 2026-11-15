"""Real reserve/chunk functions: concurrent bounds, overflow and tail recovery."""
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[1]
def fn(file,needle):
 s=(r/file).read_text();a=s.index(needle);i=s.index('{',a)+1;level=1
 while level:
  if s[i]=='{':level+=1
  if s[i]=='}':level-=1
  i+=1
 return s[a:i]
s=r'''
#include "jit_region.h"
#include <pthread.h>
#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
typedef struct HvMachine {HvJitRegion jit;uint64_t jit_gen;int jit_tail_enabled;struct {uint64_t jit_tail_allocations;} stats;} HvMachine;
#define JIT_CHUNK_WORDS 256
static __thread struct {HvMachine *m;uint64_t gen;uint32_t *hot,*cold;uint32_t seg,epoch;} chunk;
'''+fn('host/jit_region.c','static size_t region_cap(')+'\n'+fn('host/jit_region.c','uint32_t *hv_jit_reserve(')+'\n'+fn('host/jit_region.c','void hv_jit_reset(')+'\n'+fn('host/jit_region.c','void hv_jit_ring(')+'\n'+fn('host/jit_region.c','uint32_t hv_jit_evict_next(')+'\n'+fn('host/jit_region.c','size_t hv_jit_extent(')+'\n'+fn('core/translate.c','static int chunk_take(')+r'''
static HvJitRegion shared;
static unsigned seen[16384];
static void *allocate(void *arg){(void)arg;
 for(;;){uint32_t *p=hv_jit_reserve(&shared,7);if(!p)break;size_t at=p-shared.base;assert(!(at&1)&&at+8<=shared.capacity);
  for(size_t j=0;j<8;j++)assert(__atomic_fetch_add(&seen[at+j],1,__ATOMIC_RELAXED)==0);
 }return NULL;
}
int main(void){
 shared.base=calloc(16384,4);assert(shared.base);shared.capacity=16384;
 pthread_t threads[12];for(int i=0;i<12;i++)assert(!pthread_create(&threads[i],NULL,allocate,NULL));
 for(int i=0;i<12;i++)pthread_join(threads[i],NULL);
 assert(shared.used==16384);
 for(int i=0;i<16384;i++)assert(seen[i]==1);
 assert(!hv_jit_reserve(&shared,SIZE_MAX)&&shared.used==16384);
 shared.used=0;shared.limit=10;assert(hv_jit_reserve(&shared,9)==shared.base&&shared.used==10);
 assert(!hv_jit_reserve(&shared,2)&&shared.used==10);
 HvMachine m={.jit={.base=shared.base,.capacity=300},.jit_gen=1,.jit_tail_enabled=1};uint32_t *hot,*cold;
 assert(!chunk_take(&m,200,32,&hot,&cold)&&m.jit.used==256);
 assert(!chunk_take(&m,16,16,&hot,&cold)&&m.jit.used==288);
 assert(m.stats.jit_tail_allocations==1&&hot==m.jit.base+256&&cold==m.jit.base+272);
 assert(chunk_take(&m,32,32,&hot,&cold)==-1&&m.jit.used==288);
 m.jit_gen++;m.jit.used=0;assert(!chunk_take(&m,8,8,&hot,&cold)&&hot==m.jit.base);
 // A limited comparison cache must work even with final-tail recovery off.
 // Odd limits leave their final word unused to preserve 8-byte placement.
 m.jit_gen++;m.jit.used=0;m.jit.limit=65;m.jit_tail_enabled=0;
 assert(!chunk_take(&m,20,12,&hot,&cold)&&m.jit.used==64);
 assert(hot==m.jit.base&&cold==m.jit.base+52);
 assert(!chunk_take(&m,16,16,&hot,&cold)&&m.jit.used==64);
 assert(chunk_take(&m,1,1,&hot,&cold)==-1&&m.jit.used==64);
 m.jit_gen++;m.jit.used=0;m.jit.limit=0;
 assert(!chunk_take(&m,8,8,&hot,&cold)&&m.jit.used==256);
 m.jit_gen++;m.jit.used=0;m.jit.limit=500;
 assert(!chunk_take(&m,8,8,&hot,&cold)&&m.jit.used==256);
 shared.limit=0;hv_jit_ring(&shared,2);assert(shared.nseg==2 && shared.seg_words==8192);
 assert(hv_jit_reserve(&shared,8192)==shared.base);
 assert(hv_jit_reserve(&shared,8192)==shared.base+8192);
 assert(!hv_jit_reserve(&shared,2) && shared.used==16384);
 unsigned epoch=shared.seg_epoch[0];assert(hv_jit_evict_next(&shared)==0 && shared.seg_epoch[0]==epoch+1);
 assert(hv_jit_extent(&shared)==16384 && hv_jit_reserve(&shared,8)==shared.base);
 assert(!hv_jit_reserve(&shared,8193) && shared.too_big && shared.used==8);
 assert(hv_jit_reserve(&shared,0)==shared.base+8);
 free(shared.base);puts("JIT allocation: 12 concurrent allocators, no overlaps, bounds, overflow, failed reserve preserves space, tail recovery, effective/odd cache limits and generation reset passed");
}
'''
b=r/'build';b.mkdir(exist_ok=True);p=b/'test_jit_allocation.c';p.write_text(s)
subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-pthread','-I'+str(r/'host'),str(p),'-o',str(b/'test_jit_allocation')],check=True)
subprocess.run([str(b/'test_jit_allocation')],check=True,timeout=15)
