# Leveling Up: Modern Kernel Build, Test, and Debug Practices for a 4.9 Non-GKI Android Kernel

**Audience:** Maintainer of a Samsung Galaxy S9+ (star2lte, Exynos 9810, kernel 4.9.337, Android 13) custom kernel with KernelSU-Next (and optionally SUSFS), who wants to adopt modern kernel engineering practices.

**Applicability legend used throughout:**

- **[4.9 OK]** — works as-is on your kernel/tree
- **[GKI-only]** — applies to android11-5.4+ / 5.10+ Generic Kernel Image kernels; useful to understand, not applicable to your build
- **[Both — differs]** — the concept applies everywhere, but the details differ between 4.9 non-GKI and modern GKI
- **[Uncertain]** — I could not verify this fully during research; treat with care

Facts about your exact device (star2lte, Exynos 9810) come from XDA/GitHub community sources and general knowledge — verify against your own tree before relying on them.

---

## 1. Building Kernels Properly

### 1.1 Kbuild/Kconfig internals: defconfig, olddefconfig, fragments **[4.9 OK]**

How the config machinery actually works:

- `make defconfig` (or `make star2lte_defconfig`) starts from a minimal file under `arch/arm64/configs/` and fills in **every other symbol with Kconfig defaults**. The file on disk is intentionally sparse.
- `make olddefconfig` takes an existing `.config` and resolves it against current Kconfig rules: new symbols get their default, symbols whose dependencies disappeared get **silently dropped**. It never prompts. `make oldconfig` prompts for each new symbol; `make menuconfig` is interactive. `make savedefconfig` writes a minimal diff-style defconfig — the canonical way to normalize a bloated `.config` back into a clean defconfig.
- **Fragments** are small config files containing only the options you care about (e.g. "everything for KernelSU + SUSFS", "everything for tuning"). They are merged onto a base config with `scripts/kconfig/merge_config.sh`:

  ```bash
  # -m = only merge, don't immediately build
  scripts/kconfig/merge_config.sh -m arch/arm64/configs/star2lte_defconfig \
      my-kernelsu.config my-susfs.config
  make O=out olddefconfig
  ```

  `merge_config.sh` concatenates base + fragments (later fragments win), runs the Kconfig resolution, and **prints warnings when a requested value was dropped or overridden** — read them, they are how you catch "my fragment asked for CONFIG_FOO=y but it silently vanished because its dependency was off."
- `scripts/config` is a non-interactive sed-for-configs tool, ideal for scripted config edits:

  ```bash
  scripts/config --file out/.config -e CONFIG_KSU -d CONFIG_DEBUG_INFO \
      --set-str CONFIG_LOCALVERSION "-Star2Lite-v1"
  make O=out olddefconfig
  ```

- **The gotcha that bites everyone:** after `olddefconfig`/`menuconfig`, Kconfig may *re-enable* things you disabled (default `y` symbols) or drop things whose deps are missing. Never assume your `.config` matches your intent — **verify**:

  ```bash
  grep -E 'CONFIG_(KSU|SUSFS|SND_SOC|MODVERSIONS)' out/.config
  # or diff against a known-good snapshot of out/.config
  ```

Key references:
- Kconfig language: https://docs.kernel.org/kbuild/kconfig-language.html
- `merge_config.sh`: `scripts/kconfig/merge_config.sh` in your tree; Kbuild integration in `scripts/kconfig/Makefile` (https://github.com/torvalds/linux/blob/master/scripts/kconfig/Makefile)
- A short tour of Kconfig/Kbuild internals: "Exploring the Linux kernel: The secrets of Kconfig/kbuild" — https://opensource.com/article/18/10/kbuild-and-kconfig (2018, but the mechanics are unchanged for 4.9)

### 1.2 `CONFIG_LOCALVERSION`, vermagic, and module compatibility **[Both — differs]**

- `uname -r` = `KERNELVERSION` + `CONFIG_LOCALVERSION` (+ `-dirty`/git suffix, see below). Set it per release so you can always tell which build is on the phone:

  ```text
  CONFIG_LOCALVERSION="-star2lte-ksu-susfs-r1"
  # CONFIG_LOCALVERSION_AUTO is not set
  ```
- With `CONFIG_LOCALVERSION_AUTO` unset (normal for Android trees), the `setlocalversion` script appends `+` when the git tree is **dirty**. That changes `UTS_RELEASE` and therefore **vermagic**, which breaks out-of-tree modules with "version magic mismatch". Commit or clean your tree, or pin `CONFIG_LOCALVERSION` explicitly. (See https://forums.developer.nvidia.com threads and kernel `scripts/setlocalversion`.)
- **vermagic** is the string baked into each module (`.modinfo` section: `vermagic=4.9.337-star2lte... SMP mod_unload aarch64`). `insmod`/`modprobe` refuse to load on mismatch. On your phone, check with:

  ```bash
  adb root && adb shell cat /proc/version            # running kernel release
  adb shell "strings /vendor/lib/modules/*.ko | grep vermagic"
  ```
- **`CONFIG_MODVERSIONS`** (Samsung kernels have it on) adds a second, stricter check: CRCs of exported symbols. If you change any struct/prototype that touches an exported symbol, CRCs change and vendor modules built against the old kernel fail with "disagrees about version of symbol". On a non-GKI device everything ships together in your flashable zip, so rebuild all modules in the same build; the failure mode matters when you reflash only the boot image and leave old modules in a partition.
- **Practical rule:** every release, record `uname -a`, `cat /proc/version`, and the module vermagics in your release notes. A one-line version string change (`LOCALVERSION`) is the cheapest "did I actually flash the new kernel?" check.

### 1.3 Incremental vs clean builds, IKCONFIG staleness **[4.9 OK — the fix for this arrived after 4.9]**

Kbuild uses `fixdep` to track per-file `CONFIG_*` dependencies, so incremental builds are *mostly* correct: flipping one option rebuilds only files that reference it. But there are real pitfalls:

- **`CONFIG_IKCONFIG` / `/proc/config.gz` staleness.** With `CONFIG_IKCONFIG_PROC`, the `.config` is gzipped into `kernel/config_data.gz` and embedded in the image. The 4.9-era make rule is **timestamp-based**; the content-compare fix ("update config_data.gz only when the content of .config is changed", Masahiro Yamada, LKML 2021 — https://lkml.iu.edu/hypermail/linux/kernel/2108.2/02775.html) landed *after* 4.9. If a copied/same-mtime `.config` slips through (common with `O=` builds and scripts that regenerate configs), the running kernel reports an **old config** in `/proc/config.gz`. This is exactly the class of "why does my device report a config I don't ship" bug. See also https://unix.stackexchange.com/questions/527026.
  - Mitigation: after any config change, `touch kernel/config_data` (or just `rm out/kernel/config_data.gz`), or `make clean` when in doubt; and **always verify after boot**: `adb shell "zcat /proc/config.gz | grep -E 'KSU|SUSFS'"`.
- **When to force a clean build:** after enabling/disabling whole-ABI-affecting options (`CONFIG_MODVERSIONS`, `CONFIG_KASAN`, `CONFIG_LTO*`, `CONFIG_CFI*`, toolchain switch GCC↔clang, `CONFIG_LOCALVERSION` change), after header/arch-wide changes, and whenever a bisect result looks non-deterministic. Incremental is fine for code edits and small option flips.
- **Verify the build actually is what you think:** `strings out/vmlinux | grep 'Linux version'` (shows release + build user/host/timestamp), and diff `out/.config` against your committed defconfig.

### 1.4 ccache for kernel builds **[4.9 OK]**

- Wrap the compiler: `make O=out CC="ccache clang" ...` (with clang; for gcc, `CC="ccache gcc"`). Expect several-fold speedups on rebuilds from cold trees (community benchmarks report up to ~6x: https://eorlov.org/post/speed-up-kernel-build/).
- Nick Desaulniers' (Google/clang-built-linux) writeup: https://nickdesaulniers.github.io/blog/2018/06/02/speeding-up-linux-kernel-builds-with-ccache/
- Pitfalls:
  - Kernel compiles use absolute paths extensively; configure ccache so cache hits survive moving the tree: `ccache config set hash_dir false` and `ccache config set base_dir /home/mehran` (see https://ccache.dev/documentation.html).
  - ccache keys on the **preprocessed source**; `CONFIG_*` changes naturally miss (correct behavior), but unrelated churn (paths, toolchain build id in debug info) can also cause misses. Check hit rates with `ccache -s` after a typical edit-rebuild cycle; a healthy kernel workflow shows high hits for recompiles of unchanged code.
  - Known false-positive/low-hit issues with kernel builds are documented (e.g. ccache issue #792 — https://github.com/ccache/ccache/issues/792). If hits look wrong, try `CCACHE_DEPEND=1`/direct mode off before concluding anything. **[Uncertain]** exact best settings vary by ccache version.

### 1.5 clang/LLVM vs GCC **[4.9 OK — with era-appropriate caveats]**

- AOSP has **required clang for Android kernels since Android 9 (P)** for 4.4+/4.9+ kernels — your kernel is *already* supposed to be clang-built. Reference: https://source.android.com/docs/core/architecture/kernel ("Building the kernel" section).
- Google ships prebuilt clang in AOSP: `prebuilts/clang/host/linux-x86` (https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/). Community convention: use an AOSP-provided clang (or a distro clang ≥ 9-era for 4.9) plus AOSP's GCC only for assembly/linking where the old tree needs it (some 4.9 trees need `CROSS_COMPILE=aarch64-linux-android-` for `ld`/`objcopy`; others are fine with LLVM binutils).
- Modern upstream usage is `make LLVM=1` (all-LLVM toolchain) — documented at https://docs.kernel.org/kbuild/llvm.html. That `LLVM=1` switch landed in **5.3**; on 4.9 you pass tools explicitly (`CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump`) or keep GNU binutils. **[Uncertain]** whether your tree's Makefile supports `LD=ld.lld` cleanly — many 4.9 Samsung trees do with small patches; test before committing to it.
- clang advantages you'll actually feel: better warnings (`-Wsometimes-uninitialized` etc.), LTO/CFI readiness, and matching what AOSP CI does. Downsides on 4.9: occasional new-clang regressions on old code — pin the clang version that works and record it in your build docs.

### 1.6 Reproducible + defconfig-verified builds **[Both]**

- Kill build-host noise so two builds of the same commit produce identical images:

  ```bash
  KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 2026" \
  KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=builder \
  make O=out ... LOCALVERSION=
  ```
  with `CONFIG_LOCALVERSION_AUTO=n` and a clean tree (no `-dirty`, no git-desc suffix). Verify with `strings vmlinux | grep 'Linux version'`.
- **Defconfig verification** belongs in CI (even a local script): after building, run `make O=out savedefconfig` and `diff out/defconfig arch/arm64/configs/star2lte_defconfig`. Any diff = someone hand-edited `.config` and your defconfig lies. This single check catches a huge class of "it works on my machine" config drift.
- For 4.9, `scripts/config` + `savedefconfig` + diff in a small `ci-check-config.sh` gets you 90% of what Google's `check_defconfig` does in AOSP's build system.

### 1.7 How AOSP/community projects structure fragment-based configs **[Both — differs]**

- **AOSP legacy (your era, 4.9/4.14 device kernels):** device kernels use AOSP's `build.config`/`build/build.sh` framework (https://source.android.com/docs/setup/build/building-kernels). Config customization happens via `POST_DEFCONFIG_CMDS` — a shell hook after `make defconfig` that typically edits the config with `scripts/config` and re-runs `olddefconfig`. Real examples live in `android.googlesource.com/kernel/common` (`build.config.aarch64`) and Pixel-era device kernels (e.g. `build.config.bluecross`):

  ```bash
  function update_defconfig() {
      scripts/config --file out/.config -e CONFIG_SOME_FEATURE
      make O=out olddefconfig
  }
  POST_DEFCONFIG_CMDS="update_defconfig"
  ```
  AOSP's own GKI builds also ship a `check_defconfig` step that fails the build if `.config` doesn't match the defconfig exactly (see https://android.googlesource.com/kernel/common/).
- **AOSP modern (GKI):** required/recommended Android options live in `gki_defconfig` (per-arch) — the old `android-base.config` / `android-recommended.config` fragments were consolidated. Fragment files historically lived in https://android.googlesource.com/kernel/configs/. GKI config policy: https://source.android.com/docs/core/architecture/kernel/gki-config. Newer GKI builds moved to Bazel ("Kleaf"); `build.sh` remains the 4.9-era flow. **[Uncertain]** exact Kleaf cutoff version per branch.
- **Your community lineage:** the Exynos 9810 world is a fork graph: Samsung's stock 4.9 drop → `exynos-linux-stable` (GitHub org, per-device branches like `crownlte`, tracking linux-stable merges) → DS-ACK and its derivatives (e.g. **CrownTrail**, explicitly "forked from DS-ACK" per its XDA thread: https://xdaforums.com/t/kernel-oneui-s9-s9-n9-ems-crowntrail-kernel-v1-6.4715417/), plus ROM-side orgs like **ExyHyperBrick** (https://github.com/ExyHyperBrick — SLSI/linaro hardware repos for LineageOS 9810 builds) and dedicated kernel repos such as https://github.com/mrcxlinux/exynos9810-kernel-artplus ("An upstreamed exynos9810 kernel for the Galaxy 9 series", ships KernelSU-Next v3.1.0-legacy + SUSFS patch integration scripts). **[Uncertain]** what "DS-ACK" literally stands for and which repo is canonical — the name is real (XDA confirms the lineage), but I found no authoritative description of its structure. When you adopt fragments, pick the AOSP `POST_DEFCONFIG_CMDS`-style flow and keep your defconfig `savedefconfig`-clean; that's the most portable "commercial practice" you can graft onto these trees.

**Recommended structure for your tree:**

```text
arch/arm64/configs/star2lte_defconfig      # savedefconfig-clean base
kconfig/ksu.config                          # CONFIG_KSU* options
kconfig/susfs.config                        # CONFIG_KSU_SUSFS* options
kconfig/tuning.config                       # governor/IO/thermal tweaks
build.sh                                    # merge_config.sh + olddefconfig + build + AnyKernel3 zip
ci/check-config.sh                          # savedefconfig diff + grep assertions
```

---

## 2. Testing and Validation

### 2.1 kselftest **[4.9 OK, with Android caveats]**

- kselftest is the in-tree userspace test suite (`tools/testing/selftests/`): https://docs.kernel.org/dev-tools/kselftest.html. Targets: `make TARGETS=timers kselftest`, `kselftest-install`, `kselftest-clean`. It has existed well before 4.9, so the suite in your tree is runnable.
- Cross-build for arm64 and push via adb:

  ```bash
  make -C tools/testing/selftests TARGETS=timers CC=clang \
       CROSS_COMPILE=aarch64-linux-android- ARCH=arm64 INSTALL_PATH=...
  adb push ... /data/local/tmp/kst/ && adb shell "run_kselftest.sh"
  ```
- **Reality check:** kselftest binaries assume glibc and a normal Linux userspace; Android's bionic breaks many of them. Practical approach: run a meaningful subset in a chroot/proot glibc rootfs on the rooted phone, or in a QEMU arm64 VM running your kernel image + a small distro. **[Uncertain]** which 4.9-era targets are worth the effort — `timers`, `vm` (some), `futex`, and `ptrace`-style ones are usually the highest value; treat it as opportunistic, not your main harness.

### 2.2 KUnit **[GKI-only as shipped; 4.9 = manual port or skip]**

- KUnit (in-kernel unit testing, `kunit.py` / kunit_tool) was **merged around Linux 5.2/5.3** (https://kunit.dev, https://docs.kernel.org/dev-tools/kunit/). There is **no `CONFIG_KUNIT` in 4.9** and no official backport; Android common kernels only carry KUnit from 4.14/4.19 onward. Backporting lib/kunit to 4.9 is possible (self-contained framework) but you also lose kunit_tool conveniences; effort/benefit is poor for a hobby device.
- **The 4.9-native equivalent:** the `lib/test_*.c` selftest modules (`CONFIG_TEST_STRING_HELPERS`, `CONFIG_TEST_USER_COPY`, `CONFIG_TEST_BPF`, `CONFIG_TEST_FIRMWARE`, ...). Build them in or as modules, then `insmod test_x.ko` — success/failure lands in dmesg. This is the era-appropriate "kernel test module" pattern and works fine on your device.
- For *new* code you write, mimic KUnit's structure with a small `#ifdef CONFIG_MY_FEATURE_TEST` module and module_param-driven cases; it costs little and pays off in regressions.

### 2.3 KernelCI / LAVA — the concept **[Concept; mostly out of reach for one phone]**

- KernelCI (https://docs.kernelci.org, https://kernelci.org) builds every kernel commit for arm/arm64 and boots/tests on **real hardware via LAVA** (Linaro Automated Validation Architecture): a scheduler (Maestro) submits jobs to LAVA labs, which power-cycle boards, deploy kernel+DT+rootfs (TFTP/fastboot), boot to shell, run tests, and publish results (https://bootlin.com/blog/tag/kernelci/).
- What transfers to you: the *idea* of an automated flash-boot-verify loop. LAVA supports **fastboot boot methods** — Samsung devices don't do `fastboot boot`, but they do Download mode (flash via Heimdall from a Linux host) and TWRP (flashable zips + `twrp install /path/zip` from adb in recovery). So a poor-man's-LAVA for star2lte is a shell script: build → make AnyKernel3 zip (https://github.com/osm0sis/AnyKernel3) → `adb reboot recovery` → `twrp install` (or `heimdall flash --KERNEL image`) → wait for boot → run smoke tests → verdict. **[Uncertain]** Heimdall support for S9+ varies by version; test before relying on it for unattended loops.

### 2.4 syzkaller basics **[4.9 OK — KCOV/KASAN exist on your tree]**

- syzkaller (https://github.com/google/syzkaller) is the coverage-guided syscall fuzzer behind syzbot. It needs the kernel built with `CONFIG_KCOV` (added in 4.6, so 4.9 has it) plus `CONFIG_KASAN` (arm64 KASAN support landed in the 4.4/4.6 era — **[Uncertain]** outline mode only on 4.9) and `CONFIG_DEBUG_INFO`.
- Android-on-device setup is documented upstream: "Linux host, Android device, arm32/64 kernel" — https://github.com/google/syzkaller/blob/master/docs/android_devices.md — syz-manager on the host drives the phone over adb, pushes `syz-executor`, generates/mutates syscall programs, and reports crashes found via KASAN/oopses. A practical walkthrough (Pixel 3a): https://blog.senyuuri.dev/ (search "Fuzzing a Pixel 3a Kernel with Syzkaller").
- Caveat for you: a KASAN kernel is slow and changes timing/behavior (SUSFS+KSU interaction untested under KASAN — **[Uncertain]** whether SUSFS patches survive KASAN builds cleanly). Treat syzkaller as a separate "lab" kernel config, never your daily-driver config.

### 2.5 adb-based smoke tests — your highest-ROI tool **[4.9 OK]**

A 20-line script run after every flash catches 95% of real regressions on a phone. Core checks:

```bash
#!/system/bin/sh
# adb smoke test — run from host: adb shell /data/local/tmp/smoke.sh
fail=0
chk() { # chk <desc> <cmd> <expect-substring>
  out=$(eval "$2" 2>&1); echo "--- $1: $out"
  echo "$out" | grep -qi "$3" || { echo "FAIL: $1"; fail=1; }
}
chk "kernel release"  "uname -r"            "star2lte"     # your LOCALVERSION
chk "vermagic"        "cat /proc/version"   "4.9.337"
chk "sound card AP"   "cat /proc/asound/cards" "AP"        # ASoC card must exist
chk "pcm devices"     "ls /proc/asound"     "pcm"
chk "modules loaded"  "wc -l < /proc/modules" ""            # count > 0: verify separately
chk "input/touch"     "cat /proc/bus/input/devices" "sec_touch"  # S9+ touch driver name
chk "wlan up"         "ip link"             "wlan0"
chk "SELinux"         "getenforce"          "Enforcing"
chk "KernelSU"        "su -c id"            "uid=0"
dmesg | grep -iE "asoc|snd_soc|probe.*(defer|-517)" | head -20
dmesg | grep -iE "panic|BUG|WARNING|Oops" | head -20
exit $fail
```

Device-specific notes:
- **Audio:** Android uses tinyalsa, not alsa-utils: `cat /proc/asound/cards`, `cat /proc/asound/pcm`, `tinymix` (mixer controls), `tinypcminfo` (PCM params), and userspace `dumpsys media.audio_flinger | head`. Reference for `/proc/asound` files: https://docs.kernel.org/sound/designs/procfile.html.
- **ASoC card missing = probe chain broke.** ASoC registers the card only when the **machine driver** has all three components (codec DAI, CPU DAI, platform) probed — see https://docs.kernel.org/sound/soc/machine.html. Typical silent killers: `EPROBE_DEFER` (-517) loops that never resolve, codec/CPU DAI name mismatch ("CODEC DAI ... not registered" in dmesg), clock/regulator/I2C failures, or the driver config dropped from `.config`.
- **The real case study (SUSFS build lost the "AP" card, touch worked):** the fact that touch (a simple input driver) worked while the audio card vanished is diagnostic gold — it means the kernel boots, the DT loads, and platform probes generally run; the failure is specific to the audio probe chain or its config. Work it like this:
  1. Confirm config first: `zcat /proc/config.gz | grep -E 'SND|SOC|9810|AOC|abox'` (Samsung Exynos audio is built from `sound/soc/samsung/...`, ABox/AOC-related configs) and diff against the last-good kernel's `/proc/config.gz` (pull it from the old boot via `zcat /proc/config.gz > good.config` *before* flashing). A config clobber during a SUSFS patch/merge is the #1 suspect.
  2. `dmesg | grep -iE "asoc|abox|aoc|snd"` — look for "ASoC: ... probe deferral", "-517", "codec DAI ... not registered", failed firmware loads (`request_firmware` for AOC/audio firmware), or devicetree probe errors.
  3. If dmesg is silent, the machine driver never ran: check the card's `compatible` in your DTB (`fdtdump` the built dtb vs the one in the boot image) and that `CONFIG_SND_SOC_SAMSUNG_*` (the 9810 machine driver) is `y`.
  4. Bisect the delta if the diff is large (see 2.6): first the config diff, then the patch stack.
  **[Uncertain]** root cause of your specific incident isn't in public records — the method above is how to close in on it.
- **Boot-time logcat greps** ("logcan" in your notes): right after boot, `adb shell logcat -d -b all > boot.log`, then grep for `E AudioFlinger|E AudioPolicy|E ServiceManager|E SurfaceFlinger|E SensorService` — framework errors are often the first *symptom* of a kernel subsystem that didn't come up. Compare against a saved good-boot log.
- **dmesg rotation pitfalls:** the kernel ring buffer is fixed-size (`CONFIG_LOG_BUF_SHIFT`) and **wraps** — early boot messages (where probe failures live) can be overwritten by the time you look. Pull dmesg immediately (`adb shell dmesg > d0.log`), avoid `dmesg -c` (destructive), and remember logcat buffers rotate too (`-d` to dump now). For pre-reboot evidence, use pstore (Section 3.5).
- Gate releases on the script: `adb shell /data/local/tmp/smoke.sh || echo "REGRESSION — do not ship"`. Add checks for anything you've ever broken (that's how you grow the suite).

### 2.6 Bisecting regressions **[4.9 OK]**

- **git bisect 101:** `git bisect start; git bisect bad HEAD; git bisect good v4.9.320; ...; git bisect reset`. Automate build-level regressions with `git bisect run` (exit 0 = good, 125 = skip, else bad): https://docs.kernel.org/admin-guide/quickly-bisect-commit.html and https://ldpreload.com/blog/git-bisect-run/. Nate Chancellor's (clang-built-linux) guide is excellent for vendor trees: https://nathanchance.dev/posts/working-with-git-bisect/.
- **Vendor-tree realities:**
  - Pin one config for the whole bisect: save `.config` from the good build, and in the bisect build script always `cp saved.config out/.config && make O=out olddefconfig` so mid-history defconfig churn can't flip your variables.
  - `git bisect skip` for commits that don't build; expect Samsung trees to have non-bisectable stretches.
  - For runtime regressions (like the sound card), you can't fully automate — flash-test-mark manually: `git bisect start`, then after each flash+smoke, `git bisect good|bad`. Keep a `bisect log` so you can pause/resume (`git bisect log > bisect.log.bak`, replay later).
  - Flashing per step: AnyKernel3 zip via TWRP CLI (`adb reboot recovery; adb shell twrp install /sdcard/kernel.zip`) or Heimdall from Download mode (https://gitlab.com/Heimdall — **[Uncertain]** S9+ support state; Odin on Windows is the fallback).
- **Config-feature bisection** (when the bug is config-dependent, not commit-dependent):
  1. Diff good vs bad `.config`: `zcat /proc/config.gz` from both, `diff good.config bad.config`.
  2. Binary-search the diff: apply half the delta to the good kernel, rebuild, retest. Usually one or two rounds isolate the single `CONFIG_*` (or a group) responsible. This is exactly how you'd distinguish "a commit broke audio" from "SUSFS merge clobbered an audio config".
  3. For defconfig history: `git log -p -- arch/arm64/configs/star2lte_defconfig` shows who/when each option changed.

---

## 3. Debugging Tooling

### 3.1 ftrace **[4.9 OK]**

- ftrace lives in tracefs: `/sys/kernel/tracing` on Android (debugfs `/sys/kernel/debug/tracing` on desktops; some devices mount it elsewhere — check `mount | grep tracefs`). AOSP's official page: https://source.android.com/docs/core/tests/debug/ftrace.
- Core flow:

  ```bash
  adb root
  adb shell "echo 16384 > /sys/kernel/tracing/buffer_size_kb"
  adb shell "echo 1 > /sys/kernel/tracing/events/sched/enable"   # event class
  adb shell "echo 1 > /sys/kernel/tracing/tracing_on"
  # ... reproduce ...
  adb shell "echo 0 > /sys/kernel/tracing/tracing_on; cat /sys/kernel/tracing/trace" > trace.txt
  ```
- Function tracer (needs `CONFIG_FUNCTION_TRACER` + `CONFIG_DYNAMIC_FTRACE`, usually already set on Samsung kernels — verify in `/proc/config.gz`):

  ```bash
  adb shell "echo do_ftrace_on > /sys/kernel/tracing/set_ftrace_filter"   # actually:
  adb shell "grep abox /sys/kernel/tracing/available_filter_functions"    # find functions
  adb shell "echo function > /sys/kernel/tracing/current_tracer"
  adb shell "echo func_stack_trace > /sys/kernel/tracing/trace_options"   # caller stacks — great for 'who calls this/why does this hang'
  ```
- `trace-cmd` (`trace-cmd record`/`report`) and KernelShark are the desktop frontends; Julia Evans' intro: https://jvns.ca/blog/2017/03/26/ftrace-trace-your-kernel-functions/.
- **Android layer:** `atrace` wraps ftrace + userspace markers; Perfetto (https://perfetto.dev) is its modern successor and reads ftrace directly (https://source.android.com/docs/core/tests/perfetto or https://perfetto.dev/docs/quickstart/android-tracing). Vendor tracepoints (e.g. Qualcomm kgsl; on Exynos, abox/audio events if the vendor added them) are enabled by writing the event dirs directly — atrace won't touch them.
- Canonical reading — Steven Rostedt's LWN series: "Debugging the kernel using Ftrace" https://lwn.net/Articles/365835/, "Secrets of the Ftrace function tracer" https://lwn.net/Articles/370423/, "Using the TRACE_EVENT() macro" https://lwn.net/Articles/379903/, "trace-cmd: A front-end for Ftrace" https://lwn.net/Articles/410200/.

### 3.2 perf / simpleperf on arm64 **[4.9 OK]**

- Kernel side needs `CONFIG_PERF_EVENTS` (+ arm64 PMU driver). Check `/proc/config.gz`.
- Userspace: **simpleperf** (AOSP's perf wrapper, ships in the NDK) is the practical choice on a phone — it speaks the same `perf_event_open` ABI and works with 4.9: https://android.googlesource.com/platform/system/extras/+/master/simpleperf/doc/README.md. `simpleperf list`, `simpleperf stat -e ...`, `simpleperf record -g -p <pid>`, `simpleperf report`.
- Upstream `perf` can also be cross-built from your tree (`make -C tools/perf`) but bionic/libc mismatches make simpleperf far less painful.
- Hardware PMU events on Exynos (Mongoose cores) are poorly documented compared to Qualcomm/Arm reference cores — **[Uncertain]** raw event numbers; derive from the Exynos 9810 TRM or start with generic cycles/instructions/cache-misses.
- Background reading: Brendan Gregg's perf pages https://www.brendangregg.com/perf.html (x86-flavored but concepts transfer).

### 3.3 kgdb/kdb **[4.9 OK in code; hard on this device]**

- Docs: https://docs.kernel.org/dev-tools/kgdb.html. Config: `CONFIG_KGDB`, `CONFIG_KGDB_SERIAL_CONSOLE`, `CONFIG_KDB_DEFAULT_ENABLE=0x1` (kdb on panic). kdb gives a built-in shell over the console (`sysrq g` to enter); kgdb attaches gdb from the host over the same serial line.
- The catch on a Galaxy S9+: **no exposed UART**. Options people have used on Android phones: USB gadget serial (configfs ACM function on the USB-C port, then `kgdboc=ttyGS0,115200`) — the Trend Micro writeup did this on a Nexus 6P: https://www.trendmicro.com/en_us/research/12/l/practical-android-debugging-via-kgdb.html, and a 2025 Pixel 8 walkthrough exists: https://xairy.io/articles/kgdb-pixel. **[Uncertain]** whether your Samsung port/USB gadget config lets you allocate an ACM function alongside adb — this is real work, treat kgdb on star2lte as an advanced project, and rely on ftrace/pstore first.

### 3.4 crash / ramdump analysis **[Both — the phone path is Samsung-specific]**

- The `crash` utility (https://github.com/crash-utility/crash) analyzes kdump/diskdump vmcores and **also raw ramdumps**: `crash vmlinux ramdump-file`. It needs `vmlinux` with `CONFIG_DEBUG_INFO` — keep every release's vmlinux archived.
- Phones rarely have working kdump (no kexec on Samsung kernels), but Samsung Exynos devices have a **full-RAM ramdump** path: on panic/crash the device reboots into Download mode and a host tool pulls the RAM image. Samsung's own flow (sec_debug/ramdump tools) is proprietary; community tooling varies — **[Uncertain]** which exact tool works for star2lte in 2026; search XDA for "S9 ramdump". If you obtain a dump, `crash --ramdump` (or `crash vmlinux <dump>`) opens it: then `bt`, `ps`, `log`, `files`, `mount`, `kmem -i` are all available — a superpower for post-mortems that ftrace can't give you.
- kdump/vmcore background: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/kernel_administration_guide/kernel_crash_dump_guide.

### 3.5 pstore / last_kmsg — crash evidence across reboots **[4.9 OK, Samsung specifics]**

- **Standard mechanism:** `CONFIG_PSTORE`, `CONFIG_PSTORE_RAM` (ramoops) — oops/panic logs and console output are written to a reserved RAM region and exposed after reboot under `/sys/fs/pstore/` as `console-ramoops-0`, `dmesg-ramoops-0`, `pmsg-0`. Docs: https://docs.kernel.org/admin-guide/ramoops.html. Check whether your tree's DT reserves the region and the config is on; on many devices pstore is silently missing (`/sys/fs/pstore` empty) — https://android.stackexchange.com/questions/215219 is a typical saga.
- **The old path:** `/proc/last_kmsg` (Android ram_console era). Many 4.9 vendor kernels still expose it or a compatibility symlink; if it exists on star2lte, it's the previous boot's console log.
- **Samsung specifics:** Samsung kernels carry `drivers/staging/samsung/sec_debug_last_kmsg.c` and copy kmsg into `/proc/sec_log` (the latter is the subject of Project Zero's CVE-2021-25369 writeup — https://googleprojectzero.github.io/0days-in-the-wild/1Day/CVE-2021-25369/ — worth reading for a tour of Samsung kernel internals). Exact last-kmsg paths vary (`/data/log/`, `/mnt/log/`, pstore) — **[Uncertain]** for your exact firmware; look for the sec_debug_last_kmsg driver in your tree's Makefiles to see where it writes.
- Workflow: after any crash/reboot, **immediately** `adb shell "ls -la /sys/fs/pstore/; cat /proc/last_kmsg > /data/local/tmp/last_kmsg.txt"` (root) and pull it. These are the only logs that survive a panic.

### 3.6 Dynamic debug (`CONFIG_DYNAMIC_DEBUG`) **[4.9 OK]**

- Docs: https://docs.kernel.org/admin-guide/dynamic-debug-howto.html. With `CONFIG_DYNAMIC_DEBUG=y` (check your kernel; Samsung usually enables it), every `pr_debug`/`dev_dbg` becomes toggleable at runtime:

  ```bash
  adb root
  adb shell "echo 'file sound/soc/samsung/* +p' > /sys/kernel/debug/dynamic_debug/control"
  adb shell "cat /sys/kernel/debug/dynamic_debug/control | grep snd"
  # module-wide:  echo 'module snd_soc_smdk_9810 +p'  (name as it appears in the control file)
  # kernel cmdline equivalent at boot: dyndbg="file sound/soc/samsung/* +p"
  ```
- Flags: `p` (print), `f`/`l`/`m` (add function/line/module info), `t` (thread id). This is the fastest way to get the Samsung audio/thermal/camera drivers to *talk* without a rebuild. Caveat: verbose `dev_dbg` only exists where the driver author wrote them; when they didn't, you add your own or use ftrace events.

### 3.7 Reading logcat and dmesg **together** **[4.9 OK]**

- Driver failures surface in dmesg (probe errors, oopses) and *echo* into logcat as service failures (AudioFlinger can't find the card → `E AudioFlinger`; sensor HAL misses an input device; radio crashes). Correlate with timestamps: `dmesg` uses kernel monotonic seconds; `logcat -v threadtime` prints wall clock — `dmesg` + `logcat` captured **at the same moment** is the winning habit:

  ```bash
  adb shell "dmesg > /data/local/tmp/dmesg.txt; logcat -d -b all -v threadtime > /data/local/tmp/logcat.txt"
  adb pull /data/local/tmp/ ; grep -iE "probe|defer|fail" dmesg.txt | head
  ```
- Remember the rotation traps from 2.5: both buffers wrap; early boot lines die first; `-d` dumps and exits; never `dmesg -c` casually.

---

## 4. Kernel Development Workflow

### 4.1 Patch hygiene and patch stacks **[4.9 OK]**

- **One commit = one patch = one concern.** Subject format `subsystem: what changed` (e.g. `drivers: thermal: fix ...`), body explains *why*, ends with `Signed-off-by:` (DCO — `git commit -s`).
- Build the habit of a **stack of clean commits** rather than one mega-commit:
  - `git rebase -i` to split/squash/reorder; `git commit --fixup=<sha>` + `rebase -i --autosquash` while iterating.
  - **Bisectable series:** every commit should build and boot. Verify cheaply: `git rebase -x "make O=out -j$(nproc) Image.gz" <base>` — a one-command proof that no commit is broken.
  - Tools: **StGit** (quilt-like push/pop on top of git — https://stacked-git.github.io/guides/tutorial), classic **quilt** (https://www.konsulko.com/tool-time-quilt/), or plain topic branches. For solo kernel maintenance, topic branches + `rebase -i` are enough.
- Even though you don't email patches, generate them for review/backup: `git format-patch --cover-letter -N vLast..HEAD` produces an mailable series you can archive, diff between releases, or apply onto other trees with `git am`. The Linux Foundation's free **LFD103** course teaches this workflow end-to-end: https://training.linuxfoundation.org/training/a-beginners-guide-to-linux-kernel-development/.
- Release discipline: tag each shipped build (`git tag ksusfs-r1`), keep `vmlinux` + `.config` + AnyKernel3 zip + smoke-test output per release in an archive dir. Retro-debugging without artifacts is misery.

### 4.2 Stable-tree patching on an EOL 4.9 — where post-EOL fixes come from **[4.9-specific reality]**

The facts: upstream Linux **4.9.y went EOL in January 2024 with 4.9.337 as the final release** (https://9to5linux.com/linux-kernel-4-9-reaches-end-of-life-after-6-years-of-support; branch status at https://endoflife.date/linux). You are on the terminal release — no more kernel.org fixes will ever appear for 4.9.y. Sources for fixes now:

- **Android common kernels (ACK):** `android.googlesource.com/kernel/common` branches (`android-4.9-o/-p/-q`, and plain `android-4.9-*`) exist and received Google's extended support, but ACK 4.9 is past its published EOL too — no further security updates (policy: https://source.android.com/docs/core/architecture/kernel/android-common). Still worth having as a remote: Google backported a decade of hardening into those branches that plain 4.9.337 lacks. Diff `android-4.9-q` against your tree to find security fixes worth cherry-picking.
- **Your device community trees:** `exynos-linux-stable` (GitHub org — per-device 4.9 branches with continued linux-stable-style merges), DS-ACK lineage kernels (CrownTrail etc., links in 1.7), and https://github.com/mrcxlinux/exynos9810-kernel-artplus. These communities backport post-EOL CVE fixes by hand — watch their commit feeds and cherry-pick (`git cherry-pick -x <sha>` keeps the upstream ID in your history, matching the `-stable` convention in https://docs.kernel.org/process/stable-kernel-rules.html).
- **LineageOS 4.9 device kernels** (lineage-20/21 devices still on 4.9) receive manually backported vendor security fixes — their org repos are another patch-mining source. **[Uncertain]** exact which 9810 repos are active right now.
- **SUSFS ecosystem:** SUSFS (https://gitlab.com/simonpunk/susfs4ksu — per-kernel-version branches) ships patches for 4.9 alongside KernelSU-Next integration (https://kernelsu-next.github.io lists Exynos 9810 unofficial support); its patches are version-specific and sometimes need hand-adjustment — treat every SUSFS rebase as a config+smoke-test event (Section 2.5), which is precisely how an "AP card disappears" regression slips in.
- **DIY triage:** track CVEs that touch your surface (USB, Wi-Fi driver, binder, filesystems) via the Ubuntu CVE tracker / NVD / syzbot (https://syzbot.org), find the upstream fix commit, and backport it. `git log --format='%H %s' v5.x..v5.y -- fs/` style queries plus `git cherry-pick -x` is the whole game. When cherry-picking across many versions, check that prerequisites came along (the stable rules' "dependency patch" note).
- Where fixes *should* go: if you fix a genuine bug, consider whether it's upstreamable (driver code that exists in newer kernels) — Section 5.3 tools make that path painless.

### 4.3 Coding style **[4.9 OK]**

- `Documentation/process/coding-style.rst` (https://docs.kernel.org/process/coding-style.html) — tabs, 80 cols, brace placement, function length, `goto` for cleanup, naming. Mostly unchanged since your tree, so the doc in-tree is fine.
- Style enforcement: `scripts/checkpatch.pl`. Run it per-patch: `./scripts/checkpatch.pl --strict 0001-*.patch` (or `-f file.c` for whole files). `--strict` enables the "should" checks. Fix everything except acknowledged false positives, and don't reformat untouched code wholesale (creates noise in blame).

### 4.4 Sparse, Smatch, Coccinelle, W=1 **[4.9 OK]**

- **Sparse** (type/lock/annotation checking — `__user`, `__iomem`, `__bitwise`): `make O=out C=1 CHECK="sparse"` (only rebuilt files) or `C=2` (all files). Docs: https://docs.kernel.org/dev-tools/sparse.html.
- **Smatch** (path-sensitive flow analysis built on Sparse; finds NULL derefs, double locks, use-after-free with low noise): build from https://repo.or.cz/smatch.git, then `make O=out C=1 CHECK="~/smatch/smatch -p=kernel"`; it maintains a kernel-specific checks database. Background: LWN "Smatch: pluggable static analysis for C" (2016).
- **Coccinelle** (semantic patch language SmPL — pattern matching + automatic fixes): `make coccicheck MODE=report M=drivers/xxx` — https://docs.kernel.org/dev-tools/coccinelle.html. Best for whole-tree API migrations and finding repetitive bug patterns.
- **Compiler warnings as CI:** `make O=out W=1` (and `W=2` for exploration) on your driver directories; a clean W=1 build of your touched files is a reasonable standing bar. Combined with clang (1.5) you get a second, differently-tuned warning set — clang+GCC dual-build is a cheap extra regression net.
- Comparative overview: https://thenewstack.io/checking-the-linux-kernel-with-static-analysis-tools/.

---

## 5. Learning Resources

### 5.1 Books **[Concepts OK everywhere]**

- **"Linux Device Drivers", 3rd ed. (LDD3)** — free at https://lwn.net/Kernel/LDD3/. Published 2005 (kernel 2.6.10): APIs are dated, but the driver-model concepts (probe, cdev, sysfs, interrupts, DMA) still explain *why*. Verify every API against the in-tree docs or a modern kernel before using.
- **"Linux Kernel Development", 3rd ed., Robert Love (2010)** — the best short conceptual tour of the core kernel (scheduler, VM, sync, syscalls). The official kernel docs list it as a foundational book (https://docs.kernel.org/process/howto.html). Ages well because it's concept-heavy.
- **"Understanding the Linux Kernel", Bovet & Cesati** — older, x86-centric, still useful for VM/IRQ internals.
- Modern replacement for LDD3-era practice: **"Linux Kernel Programming" (Kaiwan N Billimoria, Packt, ~5.4-based)** and **John Madieu's "Linux Device Driver Development" (2nd ed.)** — **[Uncertain]** exact editions/versions; check before buying.
- **The Linux Kernel Module Programming Guide** — modernized community edition: https://sysprog21.github.io/lkmpg/ (your first insmod-able module in an afternoon).
- About "Boerner's kernel newbies": I could **not** identify anyone named Boerner associated with kernelnewbies.org (its founder isn't documented on the site or in coverage I found) — **[Uncertain / likely a mis-attribution]**; the site itself is covered below.

### 5.2 Sites and article series

- **Kernel Newbies** — https://kernelnewbies.org/ — start here: `FirstKernelPatch`, `KernelHacking`, the per-release change summaries (`LinuxChanges`), IRC/mailing list. Still active and the best "how do I even" resource.
- **LWN.net** — the kernel press of record; the **Kernel Index** (https://lwn.net/Kernel/Index) catalogs everything. Directly useful for you:
  - ftrace series (Rostedt): 365835, 370423, 379903, 410200 (URLs in 3.1)
  - "How to participate in kernel development" series (Corbet, 2013) — process and etiquette
  - The yearly kernel statistics articles and theKernel release coverage — best way to track what's new since 4.9
  - Many are subscriber-only (worth it if you get serious; some free after a week)
- **kernel.org docs** — but note docs.kernel.org renders only *current* kernels: for 4.9 you mostly read `Documentation/` **in your own tree** (the 4.9-era txt files), which conveniently describes your code as it is.
- **Julia Evans, "ftrace: trace your kernel functions!"** — https://jvns.ca/blog/2017/03/26/ftrace-trace-your-kernel-functions/ — friendliest possible on-ramp.

### 5.3 Courses and video

- **LFD103 "A Beginner's Guide to Linux Kernel Development"** — free, self-paced (git workflow, building, patching, community process): https://training.linuxfoundation.org/training/a-beginners-guide-to-linux-kernel-development/
- **LFD420 "Linux Kernel Internals and Development"** — paid Linux Foundation course: https://training.linuxfoundation.org/training/linux-kernel-internals-and-development/
- **Conference talks on YouTube (all free):** Linux Plumbers Conference (LPC) — kernel debugging/testing and KUnit/Kselftest microconferences; Kernel Recipes (e.g. Greg KH's talks); FOSDEM kernel room. Search "LPC 2021 kselftest" / "Kernel Recipes Greg Kroah-Hartman".
- **"Learning kernel development on hard mode"** (offlinemark, 2024) — a realistic solo-learning log with streams: https://offlinemark.com/2024/10/02/learning-kernel-development-on-hard-mode/

### 5.4 Android-specific documentation **[mixed applicability]**

- **AOSP kernel docs hub:** https://source.android.com/docs/core/architecture/kernel — with subpages for building kernels, modules, boot-time optimization, eBPF, DMA-BUF heaps, and debugging. Index of major pages (verified): GKI project (`generic-kernel-image`), GKI dev (`gki-dev`), KMI stability (`stable-kmi`), ABI monitoring (`abi-monitor`), vendor module guidelines (`vendor-module-guidelines`), "Debugging with GKI" (`debugging-with-gki`), kernel test page (`test-kernel`), and the kernel FAQ.
- **ftrace on Android:** https://source.android.com/docs/core/tests/debug/ftrace (walked through in 3.1).
- **Kernel sanitizers (KASAN/UBSAN/CFI):** https://source.android.com/docs/security/test/kernelsanitizers — KASAN/UBSAN apply to 4.9; **CFI is clang-LTO-era and effectively GKI/modern-kernel territory**.
- **What transfers from GKI docs to your 4.9 non-GKI kernel:**
  - Transfers well: config-fragment discipline and `savedefconfig` verification (2.6/1.7), module-building hygiene, the debugging pages (ftrace/pstore/simpleperf usage is version-agnostic), boot-time optimization *techniques*.
  - Does **not** transfer: KMI/ABI monitoring (libabigail/stg symbol lists — GKI 5.4+), `gki_defconfig`/module-split architecture, Kleaf builds, vendor_boot/bootconfig plumbing, GKI release/respin process.
  - **[Uncertain]** precise GKI start version per Android release (android11-5.4 partial vs android12-5.10 full) — read the GKI page for the authoritative table.

---

## 6. A 30/60/90-Day Plan (concrete)

1. **Week 1–2 — Make the build trustworthy.** Set `CONFIG_LOCALVERSION`; script the build (`build.sh` with pinned clang + ccache + `O=out`); add `ci/check-config.sh` (savedefconfig diff + config assertions); tag a release and archive vmlinux+.config+zip.
2. **Week 3–4 — Make the device testable.** Write `/data/local/tmp/smoke.sh` (2.5) with the audio-card check as a hard gate; capture good-baseline artifacts (`/proc/config.gz`, `/proc/asound/cards`, dmesg, `logcat -d -b all`) into `baseline/`; wire flash→boot→smoke into one command (TWRP CLI or Heimdall).
3. **Month 2 — Debugging literacy.** Enable/verify DYNAMIC_DEBUG, pstore/ramoops, ftrace function tracer on-device; run one ftrace session on the audio probe path; practice one manual bisect on a known regression; add a config-diff bisection drill.
4. **Month 3 — Fix a real bug.** Mine `android-4.9-q` and `exynos-linux-stable` for a cherry-pickable security fix, apply with `-x`, verify with checkpatch + `W=1` + Sparse, ship as a clean patch stack (`format-patch`, bisectable via `rebase -x`), and re-run the full smoke suite. Optionally attempt a KASAN/KCOV lab build for syzkaller.

---

## 7. Source list (primary links)

- Kbuild/llvm: https://docs.kernel.org/kbuild/llvm.html ; Kconfig: https://docs.kernel.org/kbuild/kconfig-language.html ; merge_config: https://github.com/torvalds/linux/blob/master/scripts/kconfig/Makefile ; Kbuild/Kconfig tour: https://opensource.com/article/18/10/kbuild-and-kconfig
- IKCONFIG staleness: https://lkml.iu.edu/hypermail/linux/kernel/2108.2/02775.html ; https://unix.stackexchange.com/questions/527026
- ccache: https://nickdesaulniers.github.io/blog/2018/06/02/speeding-up-linux-kernel-builds-with-ccache/ ; https://ccache.dev ; https://eorlov.org/post/speed-up-kernel-build/ ; https://github.com/ccache/ccache/issues/792
- AOSP kernels (clang requirement, ACK EOL policy): https://source.android.com/docs/core/architecture/kernel ; https://source.android.com/docs/core/architecture/kernel/android-common ; GKI config: https://source.android.com/docs/core/architecture/kernel/gki-config ; kernel/configs: https://android.googlesource.com/kernel/configs/
- kselftest: https://docs.kernel.org/dev-tools/kselftest.html ; KUnit: https://kunit.dev ; https://docs.kernel.org/dev-tools/kunit/
- syzkaller: https://github.com/google/syzkaller ; Android device setup: https://github.com/google/syzkaller/blob/master/docs/android_devices.md
- KernelCI/LAVA: https://docs.kernelci.org ; https://bootlin.com/blog/tag/kernelci/
- ASoC: https://docs.kernel.org/sound/soc/machine.html ; /proc/asound: https://docs.kernel.org/sound/designs/procfile.html
- Bisect: https://docs.kernel.org/admin-guide/quickly-bisect-commit.html ; https://nathanchance.dev/posts/working-with-git-bisect/ ; https://ldpreload.com/blog/git-bisect-run/
- ftrace (AOSP): https://source.android.com/docs/core/tests/debug/ftrace ; LWN series: https://lwn.net/Articles/365835/ , https://lwn.net/Articles/370423/ , https://lwn.net/Articles/379903/ , https://lwn.net/Articles/410200/
- simpleperf: https://android.googlesource.com/platform/system/extras/+/master/simpleperf/doc/README.md
- kgdb: https://docs.kernel.org/dev-tools/kgdb.html ; https://www.trendmicro.com/en_us/research/12/l/practical-android-debugging-via-kgdb.html ; https://xairy.io/articles/kgdb-pixel
- crash: https://github.com/crash-utility/crash ; kdump guide: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/kernel_administration_guide/kernel_crash_dump_guide
- pstore/ramoops: https://docs.kernel.org/admin-guide/ramoops.html ; Samsung sec_log: https://googleprojectzero.github.io/0days-in-the-wild/1Day/CVE-2021-25369/
- dynamic debug: https://docs.kernel.org/admin-guide/dynamic-debug-howto.html
- Stable rules: https://docs.kernel.org/process/stable-kernel-rules.html ; 4.9 EOL: https://9to5linux.com/linux-kernel-4-9-reaches-end-of-life-after-6-years-of-support ; https://endoflife.date/linux
- Static analysis: https://docs.kernel.org/dev-tools/sparse.html ; https://docs.kernel.org/dev-tools/coccinelle.html ; https://thenewstack.io/checking-the-linux-kernel-with-static-analysis-tools/
- Patch stacks: https://stacked-git.github.io/guides/tutorial ; https://www.konsulko.com/tool-time-quilt/ ; LFD103: https://training.linuxfoundation.org/training/a-beginners-guide-to-linux-kernel-development/
- SUSFS/KSU: https://gitlab.com/simonpunk/susfs4ksu ; https://github.com/sidex15/susfs4ksu-module ; https://kernelsu-next.github.io
- Device lineage: https://github.com/mrcxlinux/exynos9810-kernel-artplus ; https://github.com/ExyHyperBrick ; CrownTrail XDA thread (forked from DS-ACK): https://xdaforums.com/ ; AnyKernel3: https://github.com/osm0sis/AnyKernel3 ; Heimdall: https://gitlab.com/Heimdall
- Books/learning: https://lwn.net/Kernel/LDD3 ; https://kernelnewbies.org ; https://lwn.net/Kernel/Index ; https://sysprog21.github.io/lkmpg/ ; https://offlinemark.com/2024/10/02/learning-kernel-development-on-hard-mode/ ; https://jvns.ca/blog/2017/03/26/ftrace-trace-your-kernel-functions/

---

### Honest uncertainty register

1. **"DS-ACK"** name/meaning and canonical repo — the project exists (CrownTrail XDA thread states its fork parent), but I found no authoritative description of its structure or config conventions.
2. **"Boerner's kernel newbies"** — no person by that name is associated with kernelnewbies.org in anything I could verify; likely a misremembered attribution.
3. **Your SUSFS "AP card" regression** root cause — not publicly documented; the doc gives the diagnostic method (config diff → ASoC probe chain → bisect), not a confirmed cause.
4. **4.9 clang details** — which exact AOSP clang versions and binutils split (lld vs GNU ld) work on your specific Samsung tree needs empirical testing; `LLVM=1` itself is a 5.3+ convenience.
5. **Samsung ramdump/sec_debug paths** on star2lte specifically (and current community ramdump tooling) vary by firmware; sec_debug_last_kmsg's output location must be read from your tree.
6. **KASAN arm64 on 4.9** (outline vs inline mode) and SUSFS-under-KASAN compatibility — unverified; syzkaller/KASAN should be a separate lab config.
7. **Heimdall S9+ support** state in 2026 — mixed reports across versions; keep Odin/TWRP as fallback.
8. Exact **Kleaf vs build.sh cutoffs** in AOSP branches — presented at the level I could confirm (build.sh for your era).