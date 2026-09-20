# Exynos 9810 (star2lte) custom kernel research: the CS47L92/93 SPI probe race, and known-issue/testing methodology

**Method note:** everything in Part 1 sections 1.1–1.6 was verified by reading actual source: vanilla Linux **v4.9.337** (`drivers/base/dd.c`, `bus.c`, `core.c`, `spi.c`, `spi-s3c64xx.c`, pinctrl files) and the real Exynos 9810 kernel trees (sparse-cloned: [LineageOS/android_kernel_samsung_exynos9810](https://github.com/LineageOS/android_kernel_samsung_exynos9810) `lineage-20`, cross-checked byte-for-byte against [mrcxlinux/exynos9810-kernel-artplus](https://github.com/mrcxlinux/exynos9810-kernel-artplus) (`NEXT`) and [ExyHyperBrick/android_kernel_samsung_exynos9810](https://github.com/ExyHyperBrick/android_kernel_samsung_exynos9810) (`lineage-23.2`) — `dd.c`, `madera-core.c`, `madera-spi.c` and `spi-s3c64xx.c` are **identical** in all three). Star2lte facts come from the tree's own DT (`arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts`) and `arch/arm64/configs/exynos9810-star2lte_defconfig`. Items I could not verify are explicitly flagged in section 1.9.

---

## PART 1 — The SPI codec probe race

### 1.1 First, correct two premises — they change the whole investigation

**Premise 1: "the madera driver is silent even on success" — false for this tree.** `madera_dev_init()` (drivers/mfd/madera-core.c, line ~800 in the tree) prints on success:

```c
dev_info(dev, "%s silicon revision %d\n", name, madera->rev);
```

and prints a `dev_err` on **every** failure path ("Failed to request core supplies", "Failed to request DCVDD", "Failed to read ID register", "Unknown device ID", "Device ID 0x%x not a %s", "Failed to apply patch", "Failed to init 32k clock", "Failed to add subdevices", "Polling BOOT_DONE_STS failed", "Running without reset GPIO is not recommended"). There is no entry log, though — the first possible log is deep in the function, ~25–50 ms in (after `msleep(20)`, regulator enables and the first SPI register read).

**Consequence:** if a bad boot shows *zero* madera messages, then either (a) `madera_spi_probe` never ran, or (b) it **started and never returned** (hung before the first print). "Started and failed" is impossible: every exit path prints.

**Premise 2: "silicon ID says cs47l93 but child comes up as cs47l92-codec — is that normal?" — yes, fully normal in this BSP.** Receipts from `drivers/mfd/madera-core.c`:

- Silicon IDs: `#define CS47L92_SILICON_ID 0x6371` (plus 0x6360/0x6338/0x6364 for L35/L85/L90). **CS47L92 and CS47L93 share silicon ID 0x6371.**
- There is only **one** set of MFD cells for the L92/L93 family: `cs47l92_devs` with child `.name = "cs47l92-codec"` (used for `madera->type == CS47L92` **and** `CS47L93`, lines 776–789). There is no `cs47l93.c` ASoC codec in the tree (only `sound/soc/codecs/cs47l92.c`), and the defconfig enables `CONFIG_MFD_CS47L92=y` / `CONFIG_SND_SOC_CS47L92=y`.
- So: DT compatible `cirrus,cs47l93` → `madera->type = CS47L93` (via `madera_get_type_from_of()`) → hardware reads back ID 0x6371 → MFD child platform device is named **`cs47l92-codec`** by design. Nothing is wrong; do not "fix" the DT.

### 1.2 What the 4.9 attach machinery actually does (verified code)

Vanilla 4.9.337 `drivers/base/dd.c` ([elixir source](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/base/dd.c)):

- **SPI device creation** (drivers/spi/spi.c): `spi_register_master()` → `of_register_spi_devices()` → `of_register_spi_device()` sets `spi->dev.of_node = nc` and `spi->modalias = of_modalias_node()` ("cs47l93") **before** `spi_add_device()`, which does `spi_setup()` then `device_add()`. Every failure there prints (`chipselect %d already in use`, `can't setup %s`, `can't add %s`). So: sysfs present ⇒ `device_add()` succeeded ⇒ `bus_probe_device()` → `device_initial_probe()` → `__device_attach(allow_async=true)` ran.
- **`__device_attach_driver()`**: match → `driver_probe_device()` → `really_probe()`. SPI match (`spi_match_device()`) is OF-compatible first, then ACPI, then `id_table` vs `modalias`, then driver name — all **deterministic, per-boot-static** data. It cannot return `-EPROBE_DEFER` on the SPI bus.
- **Async attach exists in 4.9** (`__device_attach_async_helper`, two-pass `device_attach_data`), but it only triggers for drivers with `probe_type = PROBE_PREFER_ASYNCHRONOUS` or modules that requested async probing. **madera sets neither** (drivers/mfd/madera-spi.c: no `.probe_type`, `MFD_MADERA=y` built-in ⇒ `module_requested_async_probing()` irrelevant). Its probe is synchronous.
- **Silence semantics of `really_probe()`** — this is the crucial table:

| probe outcome | log output | devices_deferred |
|---|---|---|
| success | `pr_debug` "bound device" (compiled out) + madera's own `dev_info` | — |
| any hard error **except** `-ENODEV`/`-ENXIO` | `printk(KERN_WARNING "%s: probe of %s failed with error %d\n")` | cleared |
| **`-ENODEV` / `-ENXIO`** | **`pr_debug` only → silent** (and with the defconfig, compiled out entirely) | empty |
| `-EPROBE_DEFER` | `dev_dbg` only (compiled out) | device **listed** |
| `pinctrl_bind_pins()` fails `-EINVAL` | KERN_WARNING | empty |
| `pinctrl_bind_pins()` fails `-ENODEV`/`-ENOENT` | **tolerated → returns 0, probe continues** | empty |
| probe hangs | nothing, ever | empty |

- Your tree's `dd.c` is byte-identical to vanilla 4.9.337 except three trivial hunks (a `WARN_ON` instead of the newer `dev_crit` devres check, `wake_up` vs `wake_up_all`, and it **lacks** the 4.9.y additions that return early on match `-EPROBE_DEFER` — irrelevant for SPI).
- `dev->p->dead` / `device_del`-vs-probe races: **the `dead` flag does not exist in 4.9.337** (`grep dead core.c` is empty). That entire hypothesis family is eliminated for this kernel.
- The documented deferred-probe weakness in 4.9 (comment in `driver_deferred_probe_trigger()`, lines ~146–155 of dd.c): a device that defers *after* the last trigger event, with no later successful binds, stays in the **pending** list. But pending devices **are** what `/sys/kernel/debug/devices_deferred` lists — so "stuck deferral" cannot explain an *empty* deferred list.

### 1.3 What your own tree adds / changes (vendor quirks that matter here)

1. **`drivers/base/pinctrl.c` (Samsung-modified, does not exist upstream)** — `pinctrl_bind_pins()` was moved here from `drivers/pinctrl/devinfo.c` and its tail is load-bearing:

```c
	/* Return deferrals */
	if (ret == -EPROBE_DEFER)
		return ret;
	/* Return serious errors */
	if (ret == -EINVAL)
		return ret;
	/* We ignore errors like -ENOENT meaning no pinctrl state */
	return 0;
```

   This matters because your codec DT node carries `pinctrl-0 = <&cs47l93-gpio-defaults ...>` whose config nodes are **children of the codec node itself**. In 4.9 `drivers/pinctrl/devicetree.c::dt_to_map_one_config()` the provider lookup walks up the parents and hits the "Do not defer probing of hogs (circular loop)" special case — `if (np_pctldev == p->dev->of_node) return -ENODEV;` — because the intended provider is the codec node itself: `drivers/pinctrl/cirrus/pinctrl-madera.c` line 1014 does `pdev->dev.of_node = madera->dev->of_node;`. On the *first* attach that provider never exists yet (it is an MFD child created by `mfd_add_devices()` at the *end* of the same probe), so the first parse of the codec's own map **always** resolves via the tolerated `-ENODEV` path, and the codec-internal pin config is later applied as the madera-pinctrl device's own default/hog state. This is why the madera probe can ever succeed — and why vanilla-like pinctrl behavior matters if you backport.
2. **`madera_spi_driver` has `.suppress_bind_attrs = true`** (drivers/mfd/madera-spi.c) ⇒ `/sys/bus/spi/drivers/madera/` has **no `bind`/`unbind` files**, and 4.9's SPI bus has **no `driver_override`** (verified absent from the tree's `spi.c`; upstream SPI gained driver_override only in 5.x). You cannot manually rebind madera; you must re-create the device (see 1.7.4).
3. **`s3c64xx-spi` platform driver has no `suppress_bind_attrs`** (name is `"s3c64xx-spi"`) ⇒ controller unbind/bind works and is your re-probe lever.
4. The tree's `spi.c` is a slightly older 4.9 base: it **lacks** the stable addition `if (IS_ENABLED(CONFIG_SPI_DYNAMIC) && !device_is_registered(&master->dev))` in `spi_add_device`, and `core.c` lacks the "glue directory removal vs add" race fix that is in 4.9.337 vanilla (visible by diffing against [vanilla core.c](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/base/core.c)). Neither explains your bug, but they mark the tree as pre-.337 in these areas.
5. **Defconfig (exynos9810-star2lte_defconfig) reality:** `# CONFIG_DYNAMIC_DEBUG is not set`, `# CONFIG_DEBUG_DRIVER is not set`, `# CONFIG_FTRACE is not set`, `# CONFIG_KPROBES is not set` — **all pr_debug-based evidence is compiled out and there is no ftrace/kprobe on the current build.** But `CONFIG_DETECT_HUNG_TASK=y` with `CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=120` — D-state hangs *will* produce `INFO: task ... blocked for more than 120 seconds` ~2 min after they happen.
6. `spi@10470000` node: no `samsung,power-domain` property (so no genpd attach at boot), but `10470000.spi` **is listed in the `idle-ip` list** (runtime idle-IP gating, suspend-time, not boot-time). The node uses `dma-names = "tx","rx"` but **no `dma-mode` property** ⇒ `s3c64xx_spi_parse_dt()` sets `sci->dma_mode = CPU_MODE` ⇒ transfers run FIFO/PIO with the IRQ path; `transfer_one` uses `wait_for_completion_timeout()` (line ~658), so a wedged transfer **times out and errors** rather than hanging; the hang-able waits are elsewhere (see 1.5).

### 1.4 Ranked hypotheses for the probe race

Given 1.1–1.3, the observable state (device in sysfs with modalias+of_node, driver registered, controller bound, zero madera lines, empty devices_deferred, no `probe of spi2.0 failed` warnings, intermittent with identical Image) can only be produced by:

**H1 — probe started but never returned (silent hang inside `madera_dev_init`), HIGH likelihood.**
The entire window from `madera_spi_probe()` entry to the first print (~25–50 ms: reset-GPIO get, micbias DT parse, `devm_regulator_bulk_get(AVDD,DBVDD1)`, `regulator_get(DCVDD)`, `msleep(20)`, `regulator_bulk_enable`, `regulator_enable(DCVDD)`, release reset, first `regmap_read(MADERA_SOFTWARE_RESET)` over SPI) is 100 % silent. Concrete hang candidates in that window, in order:

- **`spi_sync()` waits on message completion without a timeout** in 4.9 (`__spi_sync` → `wait_for_completion`). The s3c64xx transfer-timeout only applies once the message reaches `transfer_one()`. If the pump path stalls earlier — `prepare_transfer_hardware` → `pm_runtime_get_sync(controller)` (controller autosuspends after just 100 ms, `SPI_AUTOSUSPEND_TIMEOUT=100`, tree line 1783) → clock enable on the audio-domain clock tree, or the queue thread wedged — the probing task sleeps in D-state holding `device_lock(spi2.0)`. **D-state ⇒ khungtaskd prints at 120 s; check for "blocked for more than 120 seconds" and `echo t > /proc/sysrq-trigger`.**
- **Regulator path blocking:** LDO34 `vdd_codec_1p2` (DCVDD, `regulator-enable-ramp-delay = 5000`) and LDO33 are on the **s2mpb02 PMIC** (see 1.5) behind an I2C bus; if a sibling thread holds the regulator core mutex while stuck on that bus, `regulator_bulk_enable()` blocks invisibly.
- `devm_gpiod_get_optional("reset")` / `gpiod_set_value_cansleep()` — gpiolib/pinctrl mutex contention (unlikely to hang, listed for completeness).

If the hang is a spin (R-state) instead of a sleep, khungtaskd stays silent and only a sysrq-t dump (or a one-line `pr_info` instrumentation, 1.7.5) catches it.

**H2 — initial probe deferred, dequeued for reprobe, and the reprobe hung (composite of deferral + H1), MEDIUM-HIGH.**
A first-pass `-EPROBE_DEFER` (s2mpb02 regulators or exynos pinctrl config nodes 0xd8/0xd9 not yet up — note the pinctrl deferral prints `dev_info "could not find pctldev for node ..., deferring probe"`, and regulator defers print madera `dev_err`s, so a *fully* silent boot slightly favors H1) puts spi2.0 on the deferred list; the next successful bind anywhere triggers `driver_deferred_probe_trigger()`; `deferred_probe_work_func()` **dequeues the device before probing it**, so a hang during the reprobe leaves `devices_deferred` **empty** + unbound + silent. This composite naturally explains the intermittency: it only bites when the initial probe defers (timing) and the reprobe lands in a bad window (controller autosuspended 100 ms earlier, PMIC bus busy, CPU frequency/scheduler differences from your custom tuning). It also explains "never on vendor-era builds": vendor initcall layout, extra Samsung glue drivers and stock CPU governors keep the timing in the good window.

**H3 — attach never happened at all, MEDIUM-LOW (cheap to rule out).**
The only silent attach-skip in this code is `bus_probe_device()` respecting `drivers_autoprobe == 0`. Check on a bad boot: `cat /sys/bus/spi/drivers_autoprobe` (must be 1) and confirm `/sys/bus/spi/devices/spi2.0/driver` is absent. Also re-check the *bad boot's* device state (do not assume good-boot values): `cat /sys/bus/spi/devices/spi2.0/modalias`, `readlink /sys/bus/spi/devices/spi2.0/of_node`, `cat /sys/bus/spi/devices/spi2.0/uevent`. Match data is static, so this should differ across boots only if a userspace/other-kernel-path actor changed it — but verifying costs 30 seconds.

**H4 — userspace interference, LOW.** No `driver_override` exists on 4.9 SPI; madera is built-in (no modprobe race); `suppress_bind_attrs` blocks manual unbind. Remaining vector: something writing `/sys/bus/spi/drivers_autoprobe` (H3 check covers it).

**H5 — bound-then-unbound, LOW.** `madera_dev_exit()` is silent, but nothing in-tree calls `spi_unregister_device` post-boot, and userspace cannot unbind (no unbind attr). Refute by the absence of the `driver` symlink.

Not possible (verified): match failure flipping per boot with identical DT; `dev->p->dead`; async probe drop (`async_schedule` runs the callback synchronously on allocation failure — work is never lost); `spi_add_device` partial-registration without prints.

### 1.5 Madera sequencing requirements and the star2lte supply map

From `madera_dev_init()` + the star2lte DT (phandles resolved):

- Supplies: `AVDD`, `DBVDD1`, `CPVDD1` ← **`vdd_pmic_codec_1p8` = s2mpb02 LDO33** (always-on, boot-on); `CPVDD2`, **`DCVDD`** ← **`vdd_codec_1p2` = s2mpb02 LDO34** (enable-ramp-delay 5 ms). Note: the PMIC behind the codec is **s2mpb02** (`s2mpb02_pmic@59`, compatible `"s2mpb02,s2mpb02mfd"`), not max77705 — max77705 appears in the DTS for other functions. If you guessed max77705 LDOs for the codec, that's the correction.
- Sequence enforced by the driver: assert /RESET (active low) → `msleep(20)` → bulk-enable AVDD/DBVDD1 → enable DCVDD → **release reset** (`usleep_range(1000,2000)`) → poll `MADERA_IRQ1_RAW_STATUS_1` `BOOT_DONE_STS1` (5 ms interval, **25 ms total timeout** → `regmap_read_poll_timeout`) → ack BOOT_DONE → read `MADERA_HARDWARE_REVISION` → apply `cs47l92_patch()` → init 32k clock from MCLK2 → runtime-PM enable (autosuspend 100 ms) → `mfd_add_devices()` (pinctrl, irq, micsupp, gpio, extcon, `cs47l92-codec`).
- Reset GPIO: `reset-gpios = <&gpg1 0 0>` (exynos pinctrl bank gpg1, pin 0) — resolved via `devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW)`; a missing/failed get prints `dev_err` (or defers silently, visible in devices_deferred).
- Practical implication: the codec's registers can only be read while DCVDD is enabled and reset released; any "works then dies at runtime" pattern also maps onto `madera_runtime_resume()` (re-assert reset, re-enable DCVDD, poll boot again, `regcache_sync`) — its failures print `"Failed to restore ... cache"` / `"Leaving sleep mode"` (`dev_info`) lines worth grepping.

### 1.6 Debugging playbook (what works on this build, what needs a rebuild)

**1.6.1 Zero-rebuild evidence gathering (do this first, on 2–3 bad boots):**

```sh
# device state on the BAD boot
ls -l /sys/bus/spi/devices/spi2.0/          # driver symlink present?
cat /sys/bus/spi/devices/spi2.0/modalias     # expect spi:cs47l93
cat /sys/bus/spi/devices/spi2.0/uevent
cat /sys/bus/spi/drivers_autoprobe           # expect 1

# whole-log greps (madera messages do NOT all contain "madera" — the dev prefix is "madera spi2.0:" but some are "spi spi2.0:")
dmesg | grep -iE "madera|cs47l|silicon revision|spi2|probe of|pctldev|blocked for more than"

# wait >120 s on the bad boot, then check for hung-task messages (D-state hang detector is ON, 120 s)
dmesg | grep -E "hung|blocked for more than"

# task dump: find who is inside madera / holding locks
echo t > /proc/sysrq-trigger && dmesg | tail -n 400 > /sdcard/sysrq-t.txt
# look for the deferred-probe worker / kworker inside device_attach->really_probe->madera_dev_init,
# and for "wait_for_completion"/mutex wait chains

# deferred list right after boot AND 5 min later
cat /sys/kernel/debug/devices_deferred       # mount -t debugfs none /sys/kernel/debug first if needed
```

If `echo t` shows the probe thread parked in `spi_sync`/`wait_for_completion`/`pm_runtime`/regulator paths → H1/H2 confirmed with the exact frame.

**1.6.2 Rebuild additions that unlock real tracing** (you are the kernel dev; this is the highest-leverage config change):

```
CONFIG_DYNAMIC_DEBUG=y
CONFIG_FTRACE=y (+ CONFIG_FUNCTION_TRACER, CONFIG_DYNAMIC_FTRACE, CONFIG_FUNCTION_GRAPH_TRACER, CONFIG_STACK_TRACER)
CONFIG_KPROBES=y (+ CONFIG_KPROBE_EVENTS, CONFIG_HAVE_KPROBES already set)
# optional: CONFIG_DEBUG_DRIVER=y, CONFIG_DEBUG_KOBJECT=y
```

**1.6.3 Dynamic debug syntax for 4.9** (`Documentation/admin-guide/dynamic-debug-howto.rst`):

```sh
mount -t debugfs none /sys/kernel/debug
echo -n 'file drivers/base/dd.c +p'        > /sys/kernel/debug/dynamic_debug/control   # attach/probe traces
echo -n 'file drivers/base/pinctrl.c +p'   > /sys/kernel/debug/dynamic_debug/control   # Samsung pinctrl_bind_pins
echo -n 'file drivers/pinctrl/devicetree.c +p' > /sys/kernel/debug/dynamic_debug/control
echo -n 'file drivers/spi/spi.c +p'        > /sys/kernel/debug/dynamic_debug/control
echo -n 'file drivers/spi/spi-s3c64xx.c +p' > /sys/kernel/debug/dynamic_debug/control
echo -n 'file drivers/mfd/madera-core.c +p' > /sys/kernel/debug/dynamic_debug/control
# alternates: 'func really_probe +p', 'func __device_attach_driver +p', 'func madera_dev_init +p'
# then re-probe (1.6.4) and read dmesg; pr_debugs will now show "matched device/probing driver/requests probe deferral"
```

**1.6.4 Forcing a re-probe at runtime (4.9-constrained):**

- madera driver itself: impossible directly (`suppress_bind_attrs=true`, no driver_override on 4.9 SPI).
- **Controller re-cycle (works, and re-creates spi2.0 fresh):**
  ```sh
  echo 10470000.spi > /sys/bus/platform/drivers/s3c64xx-spi/unbind
  echo 10470000.spi > /sys/bus/platform/drivers/s3c64xx-spi/bind
  ```
  This runs the whole chain again: controller probe → `spi_register_master` → `of_register_spi_devices` → `device_add` → `device_initial_probe`. With dynamic debug enabled this either binds or prints the exact failing step. If you can reproduce the bad state on demand this way, you have a fast iteration loop.
- Deferred kick: there is **no** manual kick in 4.9 (`devices_deferred` is read-only; re-triggering happens only via `driver_deferred_probe_trigger()` on any successful bind). A controller unbind/bind is the reliable substitute.
- `echo add > /sys/bus/spi/devices/spi2.0/uevent` only re-fires uevents — it does **not** reprobe. Don't be fooled by it.

**1.6.5 ftrace (after rebuild):**

```sh
cd /sys/kernel/debug/tracing
echo 1 > events/spi/enable              # spi_message_start/done, spi_transfer_start/stop (include/trace/events/spi.h exists in 4.9)
echo function_graph > current_tracer
echo 'madera_dev_init' > set_graph_function
echo 1 > tracing_on ... cat trace
# or: echo 'madera_* s3c64xx_spi_* really_probe driver_bound' > set_ftrace_filter; echo function > current_tracer
```

Note: 4.9 driver core has **no** bind/unbind tracepoints; function tracing on `really_probe`/`driver_bound` is the substitute.

**1.6.6 The pragmatic winner: a 5-line instrumentation patch.** Given the current build has no ftrace/dynamic-debug, temporarily add `pr_info` at: `madera_spi_probe()` entry, `madera_dev_init()` entry and after each stage (reset gpio / supplies / DCVDD / pre-regmap / post-regmap), plus in `deferred_probe_work_func()` around `bus_probe_device()`. This converts the silent window into a timeline in two boots and directly discriminates H1 vs H2 vs H3. Kernel cmdline `initcall_debug` (no config needed) additionally times every initcall — useful to compare vendor vs your build's ordering of `madera-spi` (drivers/mfd) vs `s3c64xx-spi` (drivers/spi) vs s2mpb02.

### 1.7 Known-bug context worth knowing (verified by observation, cited where possible)

- `really_probe`'s silent `-ENODEV`/`-ENXIO` handling: [drivers/base/dd.c @ v4.9.337](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/base/dd.c) (lines ~432–436).
- The pinctrl "hog" `-ENODEV` return: [drivers/pinctrl/devicetree.c](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/pinctrl/devicetree.c) (`dt_to_map_one_config`, "Do not defer probing of hogs (circular loop)"), originating from the "drivers/pinctrl: grab default handles from device core" patch series; related stable fix "pinctrl: msm: fix gpio-hog related boot issues" (4.17 stable, on mail-archive).
- The deferred-probe multi-thread race is documented in-code in `driver_deferred_probe_trigger()` (dd.c 4.9.337 lines ~146–156).
- The `core.c` glue-dir race fix present in 4.9.337 vanilla but **absent** from the Samsung tree (commit known upstream as "driver core: fix race between removing glue directory and adding a new device under it" — verify with `git log -S"glue_dir" drivers/base/core.c`).
- I could not find any upstream/Cirrus report of madera "sometimes never probes" on LKML/lore within this research; the madera family's known boot-fragility (boot-done polling timeout, DCVDD drop sequencing) is documented in the driver itself rather than in reports. Flagged as an uncertainty, not an exhaustive lore search.

### 1.8 Practical reproduction matrix for your next sessions

| Boot type | `silicon revision` line | `driver` symlink | devices_deferred | sysrq-t shows probe thread | conclusion |
|---|---|---|---|---|---|
| good | present | present | empty | n/a | H1/H2 window missed |
| bad, H1 | absent | absent | empty | parked in SPI/regulator wait | hang inside madera_dev_init |
| bad, H2 | absent | absent | empty (already dequeued) | parked in same | deferred→reprobe→hang |
| bad, H3 | absent | absent | empty | no probe thread at all | attach never ran (check drivers_autoprobe/modalias) |

---

## PART 2 — Exynos 9810 custom-kernel issues, testing, and root-causing

### 2.1 Known/typical issues on Exynos 9810 custom kernels/ROMs (S9 `starlte`, S9+ `star2lte`, Note9 `crownlte`)

Primary sources: the LineageOS 22/23/24 unofficial XDA threads for S9/S9+/Note9 (title pattern `[ROM][S9+/S9/Note9][UNOFFICIAL][LineageOS 23.2]`, XDA S9 Exynos ROMs section — the thread lists **BROKEN: Iris scanner, VoLTE; Audio: speaker "fix" = toggle volume once; high-sensitivity mode causes soft reboots**; later builds report USB issues). XDA deep links did not surface reliably through search — locate via `site:xdaforums.com LineageOS 23.2 Note9` (flagged uncertainty). Ecosystem anchors:

| Area | Typical issue on custom kernels/ROMs | Where documented |
|---|---|---|
| Audio | The exact race you are chasing (codec unbound at boot); speaker quirks requiring volume toggle; jack issues on microG ROMs | your build; XDA LOS 23.2 thread; [XDA audio-jack bug thread](https://xdaforums.com) (Jul 2018) |
| Sensors+audio together dying after boot | Userspace/Magisk class, not kernel: [Magisk #4911 "LineageOS 18.1 no sound and no sensors after booting with Magisk"](https://github.com/topjohnwu/Magisk/issues/4911) | GitHub |
| Camera | Intermittent open-fail after flash; standard remedy = flash latest stock firmware (modem/camera fw) before LOS | XDA LOS threads; [e.foundation star2lte thread](https://community.e.foundation/t/solved-boot-loop-on-galaxy-s9-star2lte-after-update-to/14086) |
| VoLTE | Broken on AOSP-based ROMs (IMS stack) | XDA LOS 23.2 thread |
| Iris scanner | Broken | XDA LOS 23.2 thread |
| GPS | Works, but slow first fix; needs AGPS/radio data refresh after flashing | XDA threads |
| NFC / tap-to-pay | Mixed; wallet/Play-Integrity dependent | XDA threads |
| Hotspot/USB | Occasional regressions on recent unofficial builds (starlte 2025-01-05 report) | XDA LOS 23.2 thread |
| Battery/perf | Historically "heavy lags after high uptime"/OOM regressions from MM cherry-picks — Apollo release notes reverts document these | [Apollo releases](https://github.com/ananjaser1211/Apollo/releases) |

Kernel trees you'll want for cross-referencing fixes: [LineageOS/android_kernel_samsung_exynos9810](https://github.com/LineageOS/android_kernel_samsung_exynos9810), [ananjaser1211/Apollo](https://github.com/ananjaser1211/Apollo) (OneUI 3–6 + LOS, most active), [ExyHyperBrick/android_kernel_samsung_exynos9810](https://github.com/ExyHyperBrick/android_kernel_samsung_exynos9810), [mrcxlinux/exynos9810-kernel-artplus](https://github.com/mrcxlinux/exynos9810-kernel-artplus), [exynos-linux-stable/starlte](https://github.com/exynos-linux-stable/starlte) ("upstreamed exynos9810 kernel" release notes), [Eend15/Unofficial-Un1ca-9810](https://github.com/Eend15/Unofficial-Un1ca-9810). DS-ACK itself is distributed as a boot image (`ds-ack.img`) referenced by ROM install instructions (e.g., CornROM S9 thread on XDA) rather than a findable GitHub repo — flagged uncertain; DS-ACK-class kernels are Apollo-derived per community tooling descriptions.

### 2.2 Subsystem smoke-test suite (what experienced device kernel devs run locally)

A practical bring-up checklist after each kernel flash (all runnable from adb root; each maps to one kernel subsystem):

```sh
# dmesg hygiene first
dmesg | grep -iE "error|fail|timeout|defunct" | grep -vE "expected|avc"   # baseline noise vs regressions

# Audio (your area)
cat /proc/asound/cards; cat /proc/asound/devices
dumpsys media.audio_flinger | head -40      # HAL attached? outputs?
dumpsys audio | grep -iE "mode|devices"
grep -iE "madera|cs47l|abox|silicon revision" /proc/klog 2>/dev/null || dmesg | grep -iE "madera|abox"
cat /sys/kernel/debug/regmap/?             # regmap debugfs dirs appear only when bound (CONFIG_REGULATOR/REGMAP_DEBUG_FS)

# Camera
ls -l /dev/video* /dev/media*              # exynos camera media-controller nodes present
dumpsys media.camera | grep -iE "Device [0-9]|Status"   # HAL state = AVAILABLE
logcat -d -s CameraService CamX 2>/dev/null | tail

# GPS/GNSS
dumpsys location | grep -iE "provider|state"
logcat -d -s GnssLocationProvider Gnss 2>/dev/null | tail
# on-device: open any maps app, time-to-first-fix < ~30 s outdoors

# Sensors
dumpsys sensorservice | sed -n '/Sensor List/,/Active/p' | head -40   # all expected sensors registered
cat /sys/bus/iio/devices/iio:device*/name 2>/dev/null                 # kernel-side IIO devices alive
# then: actual data test (accelerometer graph / heart-rate) — CTS-V covers this manually

# Touch/input
dumpsys input | grep -iE "Input Device" | head
getevent -pl | head -30

# Wi-Fi/hotspot
dumpsys wifi | grep -iE "mCurrentState|Wi-Fi is"
cmd wifi start-softapapf ... # or enable hotspot in UI; check ip addr on ap0

# Telephony/VoLTE
dumpsys telephony.registry | grep -iE "mCallState|mDataConnectionState"
dumpsys ims | head                        # IMS registration state (VoLTE prereq)

# USB/DeX
dumpsys usb | head -30                    # gadget state, roles
lsusb                                     # from a PC, device enumerated

# Power
dumpsys batterystats --charged | head -30
cat /sys/kernel/debug/wakeup_sources | head -20    # wakelock audit for battery drain
```

Formal harnesses worth using sparingly (they are heavy but catch what smoke tests miss): a **CTS subset** via `cts-tradefed run cts -m CtsCameraTestCases` / `CtsSensorTestCases` / `CtsLocationGnssTestCases` / `CtsNetTestCases` (module-level runs take minutes, not hours), the **CTS-V app** for manual sensor/GPS/audio verification, and **VTS** kernel-module tests if you run an AOSP-shaped system. For regression loops, the community pattern is a scripted boot-test: flash → boot → run the checklist → `dmesg`/logcat diff → repeat N times (your bug is ~50 % per boot, so **~6 boots give you >98 % confidence** of hitting it at least once; use this to A/B candidate fixes quickly).

### 2.3 Root-causing methodology links (device-driver class)

- **Dynamic debug** (syntax + wildcards, file/func/line/format): `Documentation/admin-guide/dynamic-debug-howto.rst` in-tree; [kernel.org doc](https://docs.kernel.org/admin-guide/dynamic-debug-howto.html).
- **ftrace**: `Documentation/trace/ftrace.rst`; [kernel.org ftrace doc](https://docs.kernel.org/trace/ftrace.html). For 4.9 use the in-tree copy (tracefs paths above).
- **Kprobes** for non-invasive entry/return probes: `Documentation/kprobes.txt` (4.9 name) / [kprobes doc](https://docs.kernel.org/trace/kprobes.html).
- **DT bindings as the spec** for missing regulators/GPIOs/pinctrl: read `Documentation/devicetree/bindings/` for every driver in the failing path (madera MFD/pinctrl bindings were converted to YAML after ~5.10; for the BSP use the driver source as ground truth, as done in 1.5). Cross-check what the binding *requires* vs what your DT supplies — the single most productive exercise for "device silently never probes" is enumerating every resource `probe()` requests and asking "what if this returns `-EPROBE_DEFER`/error right now?".
- **Bisecting vendor trees**: `git bisect start; git bisect good <vendor-tag>; git bisect bad HEAD; git bisect run ./boot-test.sh` where `boot-test.sh` flashes, reboots 4–6 times, and greps for the `silicon revision` line (exit 1 if absent). Because your failure is probabilistic, make the test multi-boot.
- **Comparing working vs broken dmesg systematically**: capture both, then `diff <(dmesg.good | sed 's/\[[ 0-9.]*\]//' | sort) <(dmesg.bad | sed 's/\[[ 0-9.]*\]//' | sort) | less` — sort-diffing strips the timing so only *content* differences remain; then diff unsorted with timestamps to compare ordering (`grep -E "initcall|probe"` on both, `initcall_debug` on). Intermittent-boot bugs are almost always visible as a *reordering*, not a missing line.
- **Cross-version source reading**: [elixir.bootlin.com](https://elixir.bootlin.com/linux/v4.9.337/source/) for diffing 4.9.337 vs 5.x/6.x behavior of dd.c/spi.c (e.g., what later kernels fixed); lore.kernel.org search for the driver name.

### 2.4 Uncertainty register (things I could not verify — treat accordingly)

1. XDA deep-thread URLs (LOS 23.2/24.0 unofficial thread, DS-ACK kernel thread): verified to exist via search snippets only; find via site search on xdaforums.com.
2. DS-ACK kernel source repository: no public GitHub repo found under that name; DS-ACK appears to ship as a boot image and to be Apollo-derived (per third-party tool descriptions).
3. Whether your particular build's `madera-core.c`/`dd.c` diverge from the three trees I diffed: all three were byte-identical in the critical files, but your tree may not be one of them — re-run the diffs (`diff drivers/base/dd.c` against vanilla) on your own tree.
4. H1's exact hang site (SPI wait vs regulator vs GPIO) is a hypothesis ranked by code plausibility, not by measurement — the sysrq-t dump in 1.6.1 is what converts it to fact.
5. Topic 2's issue list is dominated by XDA thread summaries rather than linked issue trackers (the 9810 community tracks bugs in threads/Telegram, not GitHub Issues — Apollo's and ExyHyperBrick's issue trackers are nearly empty).

### 2.5 Sources

- [Linux 4.9.337 drivers/base/dd.c](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/base/dd.c), [drivers/spi/spi.c](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/spi/spi.c), [drivers/base/core.c](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/base/core.c), [drivers/pinctrl/devicetree.c](https://elixir.bootlin.com/linux/v4.9.337/source/drivers/pinctrl/devicetree.c)
- [LineageOS/android_kernel_samsung_exynos9810](https://github.com/LineageOS/android_kernel_samsung_exynos9810) (lineage-20): `drivers/mfd/madera-{core,spi}.c`, `drivers/pinctrl/cirrus/pinctrl-madera.c`, `drivers/base/pinctrl.c`, `drivers/spi/spi-s3c64xx.c`, `arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts`, `arch/arm64/configs/exynos9810-star2lte_defconfig`
- [mrcxlinux/exynos9810-kernel-artplus](https://github.com/mrcxlinux/exynos9810-kernel-artplus), [ExyHyperBrick/android_kernel_samsung_exynos9810](https://github.com/ExyHyperBrick/android_kernel_samsung_exynos9810), [ananjaser1211/Apollo](https://github.com/ananjaser1211/Apollo) (+[releases](https://github.com/ananjaser1211/Apollo/releases)), [exynos-linux-stable/starlte](https://github.com/exynos-linux-stable/starlte), [Eend15/Unofficial-Un1ca-9810](https://github.com/Eend15/Unofficial-Un1ca-9810)
- [topjohnwu/Magisk #4911](https://github.com/topjohnwu/Magisk/issues/4911), [e.foundation star2lte thread](https://community.e.foundation/t/solved-boot-loop-on-galaxy-s9-star2lte-after-update-to/14086), XDA: `[ROM][S9+/S9/Note9][UNOFFICIAL][LineageOS 23.2]` and `[KERNEL][G960F/G965F/N960F][Android 15/16] DS-ACK` threads (site search for permalinks)
- [dynamic debug howto](https://docs.kernel.org/admin-guide/dynamic-debug-howto.html), [ftrace doc](https://docs.kernel.org/trace/ftrace.html), [kprobes doc](https://docs.kernel.org/trace/kprobes.html), [LineageOS star2lte wiki](https://wiki.lineageos.org/devices/star2lte/)

---

**Bottom line for the probe race:** with this code, a fully silent, permanently unbound spi2.0 with an empty deferred list cannot be produced by a completed-but-failed probe (all failures print; `-ENODEV`/`-ENXIO` are silent but madera prints its own errors before returning them; deferrals are listed). It is therefore almost certainly **H1/H2: the probe enters `madera_dev_init()` and never returns** — most plausibly asleep without timeout in the first SPI transaction path (`spi_sync` → controller runtime-resume after its 100 ms autosuspend) or in the s2mpb02 regulator path — with the deferral→reprobe composite (H2) explaining both the intermittency and the empty deferred list. Confirm with `echo t > /proc/sysrq-trigger` on a bad boot (and the 120 s hung-task message), or with a five-line `pr_info` instrumentation; and note `cs47l93`→`cs47l92-codec` is by-design in this BSP, the codec supplies are s2mpb02 LDO33/LDO34 (not max77705), and runtime re-probe must go through the s3c64xx controller unbind/bind because the madera driver suppresses bind attrs.