#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Same engine and guest loop in every arm: no old emitter fixtures and no
# diagnostic increments in timed code. Each executable alternates cache off/on.
make -j4 build/test_fastmem_bench
for split in 0 1; do
    for order in lut-first tlb-first; do
        if [ "$split" = 0 ]; then
            env -u HV_JIT_SPLIT HV_FASTMEM_ORDER="$order" build/test_fastmem_bench > "build/fastmem-order-$order-$split.log"
        else
            HV_JIT_SPLIT=1 HV_FASTMEM_ORDER="$order" build/test_fastmem_bench > "build/fastmem-order-$order-$split.log"
        fi
    done
done
python3 - <<'PY'
import re, statistics, json
from pathlib import Path
summary={'scope':'Cloud ARM64 host microbenchmark; not physical Duo/M4 FPS or watts','orders':{}}
for split in range(2):
 for order in ('lut-first','tlb-first'):
  values={}
  for mixed,enabled,ns in re.findall(r'mixed=(\d+) enabled=(\d+) ns_per_load=([\d.]+)',Path(f'build/fastmem-order-{order}-{split}.log').read_text()):
   values.setdefault((int(mixed),int(enabled)),[]).append(float(ns))
  assert all(len(v)==7 for v in values.values()) and len(values)==8
  summary['orders'][f'{order}-split{split}']={f'workload{m}-cache{e}':statistics.median(v) for (m,e),v in values.items()}
print(json.dumps(summary,indent=2))
Path('build/fastmem-native-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
PY
