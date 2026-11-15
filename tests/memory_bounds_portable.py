"""Compile the actual span helpers without the unrelated Darwin/ARM runtime.

Native CI also links test_memory_bounds.c against the full engine. This Linux
test extracts the two unchanged function bodies directly from machine.c.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "core/machine.c").read_text()

def function(signature):
    begin = source.index(signature)
    brace = source.index("{", begin)
    level = 1
    end = brace + 1
    while level:
        if source[end] == "{": level += 1
        if source[end] == "}": level -= 1
        end += 1
    return source[begin:end]

with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    helpers = folder / "span.c"
    helpers.write_text('#include "machine.h"\n' + function("HvRam *hv_ram_lookup(") + "\n" + function("void *hv_phys_ptr("))
    binary = folder / "test"
    subprocess.run(["cc", "-std=c11", "-fsanitize=address,undefined", "-g", "-O1",
                    "-I" + str(root / "core"), "-I" + str(root / "host"),
                    str(helpers), str(root / "tests/test_memory_bounds.c"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
