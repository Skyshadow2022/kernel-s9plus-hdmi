# out-golden-20260919-2314.tar.zst — the golden incremental lineage

The `out/` build directory that produced every sound-verified kernel since
20260919-2314. Split into 90MB parts (GitHub's 100MB per-file limit).

Reassemble: `cat out-golden-20260919-2314.tar.zst.part-* > out-golden-20260919-2314.tar.zst`
Verify against sha256.txt, then:
`tar --zstd -xf out-golden-20260919-2314.tar.zst -C /home/mehran/kernel-s9plus/`

RULE: after any build, re-archive out/ and refresh these parts. NEVER make clean.
(The 20260921+ fixed builds no longer depend on the lineage for SOUND — the
madera reset-polarity fix is source-level — but the archive preserves the
known-good layout for bisects and comparison builds.)
