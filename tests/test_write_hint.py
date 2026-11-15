"""Execute the production write-hint function with counted TLB probes."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'core/mmu.c').read_text()
start=source.index('static void write_hint(');opening=source.index('{',start);depth=1;end=opening+1
while depth:
 depth+=(source[end]=='{')-(source[end]=='}');end+=1
function=source[start:end]
fixture=r'''
#include <stdint.h>
#include <assert.h>
#include <stdio.h>
#define HV_TLB_PAGE_BITS 14
#define HV_WHINT_MANY (1ull<<63)
typedef struct { int writable; } HvTlbEntry;
typedef struct { int index; HvTlbEntry tlb[32]; } HvCpu;
typedef struct { uint64_t *whint,npages; uint8_t *host; } HvRam;
static int probes;
static int maps_writable(const HvTlbEntry *e,const uint8_t *p){(void)p;probes++;return e->writable;}
'''+function+r'''
int main(void){
 uint64_t hint=1ull|(2ull<<16)|(3ull<<32);uint8_t page[16384];HvCpu c={0};HvRam r={&hint,1,page};
 c.tlb[0].writable=c.tlb[1].writable=c.tlb[2].writable=1;
 uint64_t before=hint;write_hint(&c,&r,0,0);assert(hint==before&&probes==0);
 write_hint(&c,&r,0,1);assert(hint==before&&probes==1);
 hint=0;probes=0;write_hint(&c,&r,0,3);assert(hint==4&&probes==0);
 hint=before;write_hint(&c,&r,0,3);assert(hint==HV_WHINT_MANY);
 hint=HV_WHINT_MANY;probes=0;write_hint(&c,&r,0,5);assert(hint==HV_WHINT_MANY&&probes==0);
 hint=before;c.tlb[1].writable=0;write_hint(&c,&r,0,4);assert(((hint>>16)&0xffff)==5);
 puts("PASS write hint: production duplicate-slot early return, occupied hints, stale replacement, overflow and no extra TLB probes");
}
'''
with tempfile.TemporaryDirectory(prefix='henge-hint-') as d:
 p=Path(d);(p/'test.c').write_text(fixture)
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-O1','-g','-fsanitize=address,undefined',str(p/'test.c'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
