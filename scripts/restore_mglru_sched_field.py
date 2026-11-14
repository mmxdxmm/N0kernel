#!/usr/bin/env python3
"""Idempotently restore struct task_struct::in_lru_fault after a KSU overlay.

Why this exists
---------------
susfs-1.5.5.zip ships a COMPLETE include/linux/sched.h. build_n0kernel.sh
unpacks it with `unzip -o` when building the SukiSU-Ultra variant, which
silently overwrites the MGLRU field:

    #ifdef CONFIG_LRU_GEN
        unsigned in_lru_fault:1;
    #endif

mm_inline.h's lru_gen_in_fault() still references current->in_lru_fault under
the same CONFIG_LRU_GEN, so mm/page_alloc.c then fails to compile with
"no member named 'in_lru_fault' in 'struct task_struct'".

This script re-inserts the field into whatever sched.h is on disk, keeping
SUSFS's own ANDROID_KABI/KSU additions intact. It is a no-op when the field
is already present, and fails loudly if the insertion anchor is missing.
"""
import sys


BLOCK = (
    "#ifdef CONFIG_LRU_GEN\n"
    "\t/* whether the LRU algorithm may apply to this access */\n"
    "\tunsigned\t\t\tin_lru_fault:1;\n"
    "#endif\n"
)
ANCHOR = "#ifdef CONFIG_COMPAT_BRK"


def main(path):
    with open(path, "r", encoding="utf-8") as f:
        s = f.read()

    if "in_lru_fault" in s:
        print("[MGLRU] sched.h already has in_lru_fault; nothing to do")
        return 0

    if ANCHOR not in s:
        sys.stderr.write(
            "[MGLRU] ERROR: cannot find insertion anchor "
            "'#ifdef CONFIG_COMPAT_BRK' in %s\n" % path)
        return 1

    s = s.replace(ANCHOR, BLOCK + ANCHOR, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print("[MGLRU] restored in_lru_fault in %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]) if len(sys.argv) == 2 else 2)
