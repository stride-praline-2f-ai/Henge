"""Exercise the production fallback emitter's entry/rejoin graph and bounds.

The native memory differential suite separately executes the real generated A64.
Here each translated guest instruction occupies one tagged word, allowing exact
coverage of alternate suffix entries, different joins and truncated blocks.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / 'core/translate.c').read_text()
start = source.index('static int emit_group_copies(')
end = source.index('\nstatic int translate_emit(', start)
production = source[start:end]
fixture = r'''
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#define HV_MAX_BLOCK_INSNS 128
#define MAX_WORDS 512
#define WORDS_PER_INSN_MAX 1
#define MAX_LITS 128
#define MAX_OOL 128
#define B_OP 0x14000000u
typedef struct { uint16_t first,last,end; uint32_t copy_at; int live; } Group;
typedef struct {
    Group grp[8]; uint32_t ngrp,n,npool,nool,cur_i,after[128],words[MAX_WORDS];
    uint64_t cur_pc; int nogroup,u_prev,u_live; uint32_t *w;
} Emit;
static uint64_t origin=0x100000;
static unsigned translated;
static void put(Emit *e,uint32_t w) { assert(e->n<MAX_WORDS);e->w[e->n++]=w; }
static void patch_branch(uint32_t *w,int64_t off) { *w=B_OP|((uint32_t)off&0x3ffffff); }
static int translate_one(Emit *e,uint32_t insn,uint64_t pc) {
    assert(e->nogroup && !e->u_prev && !e->u_live);
    assert(pc==origin+4*e->cur_i && pc==e->cur_pc);
    translated++;put(e,insn);e->u_prev=e->u_live=7;return 0;
}
'''
checks = r'''
static uint32_t code[128];
static void init(Emit *e) {
    memset(e,0,sizeof *e);e->w=e->words;e->n=32;translated=0;
    for(unsigned i=0;i<128;i++) { code[i]=0x80000000u+i;e->after[i]=i+1; }
}
static void path(Emit *e,unsigned group,unsigned last) {
    unsigned at=e->grp[group].copy_at,guest=e->grp[group].first;
    while(at>=32 && at<e->n) {
        uint32_t w=e->words[at];
        if((w&0xfc000000)==B_OP) {
            int32_t off=(int32_t)(w<<6)>>6;at=(unsigned)((int)at+off);break;
        }
        assert(w==code[guest++]);at++;
    }
    assert(guest==last+1 && at==e->after[last]);
}
int main(void) {
    Emit e;init(&e);e.ngrp=3;
    e.grp[0]=(Group){.first=0,.end=5,.live=1};
    e.grp[1]=(Group){.first=2,.end=5,.live=1};
    e.grp[2]=(Group){.first=4,.end=5,.live=1};
    assert(!emit_group_copies(&e,code,origin,8));
    assert(translated==6 && e.n==39); // reference emits 12 instructions + three branches (15 words)
    assert(e.grp[0].copy_at==32 && e.grp[1].copy_at==34 && e.grp[2].copy_at==36);
    for(unsigned g=0;g<3;g++)path(&e,g,5);
    init(&e);e.ngrp=2;
    e.grp[0]=(Group){.first=0,.end=5,.live=1};
    e.grp[1]=(Group){.first=2,.end=4,.live=1};
    assert(!emit_group_copies(&e,code,origin,8));
    assert(translated==9 && e.grp[1].copy_at==39);path(&e,0,5);path(&e,1,4);
    init(&e);e.ngrp=3;
    e.grp[0]=(Group){.first=0,.end=9,.live=1};
    e.grp[1]=(Group){.first=2,.end=7,.live=1};
    e.grp[2]=(Group){.first=7,.end=9,.live=1}; // outside translated instructions: omitted
    assert(!emit_group_copies(&e,code,origin,5));
    assert(translated==5 && e.n==38);path(&e,0,4);path(&e,1,4);
    init(&e);e.ngrp=1;e.grp[0]=(Group){.first=0,.end=2,.live=1};e.n=MAX_WORDS-1;
    assert(emit_group_copies(&e,code,origin,4)==-1 && !translated);
    puts("Grouped fallback copies: shared suffixes 15 -> 7 fixture words, each entry/rejoin, distinct endpoints, truncation and overflow passed");
}
'''
build = root / 'build'
build.mkdir(exist_ok=True)
path = build / 'test_group_copy_sharing.c'
path.write_text(fixture + production + checks)
subprocess.run(['cc', '-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', str(path), '-o', str(build / 'test_group_copy_sharing')], check=True)
subprocess.run([str(build / 'test_group_copy_sharing')], check=True, timeout=15)
