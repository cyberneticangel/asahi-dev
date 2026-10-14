# M5 (T8142) support — TODO notes

Target: **base M5, T8142 "Hidra"** (my machine). M4 (T8132) and A18 Pro (T8140) are reference
material, not targets: I can't test them.

Last checked: 2026-10-14 (against local `m1n1/` @ fbec52a8 and `docs/`).
Paths are relative to the repo root (`asahi-dev/`).

## 1. Status snapshot

| SoC | Codename | Chip | Where it stands |
|---|---|---|---|
| **M5** | **Hidra** | **T8142** | **All TBA. Nobody is on it.** |
| A18 Pro (MacBook Neo) | Tahiti | T8140 | linux-asahi 7.4: DT, AICv3, watchdog, I2C, GPIO, boot fb |
| M4 | Donan | T8132 | Same as T8140, plus KB backlight. NVMe + video decoder WIP |
| M5 Pro / Max | Sotra / Sotra C | T6050 / T6051 | All TBA (the docs list both as T6050, m1n1 splits them) |

Sources: `docs/docs/platform/feature-support/m5.md`, `m4.md`, `docs/docs/hw/soc/soc-codenames.md`.

**Why T8140 is the closest reference:** T8142 shares the A18 Pro's early UART base (`0x385200000`,
`m1n1/src/soc.h`), and the A18 Pro already has upstream-bound support in linux-asahi 7.4. Diff the
M5 ADT against T8140 first and T8132 second.

**Already handles T8142 in m1n1:** chip ID (`m1n1/src/soc.h`), MIDR parts 0x62/0x63
(`m1n1/src/midr.h`), early UART base, SMP start offset (`m1n1/src/smp.c:319`).

## 2. Step 0: set up

Step-by-step walkthrough (Linux host, stock-macOS M5): [`m5-setup-guide.md`](m5-setup-guide.md).

- [ ] Build m1n1 in the flake devshell (`make`). `#define TARGET T8142` is already set in
      `m1n1/config.h:23` for early-UART debug output.
- [ ] Get the proxyclient talking to the M5 (USB-C debug / dockchannel UART).
- [ ] Dump the ADT: `python -m m1n1.adt -r <out>.bin > <out>.txt` (`m1n1/proxyclient/m1n1/adt.py:875`).
      `-r` writes the raw binary to `<out>.bin`, and the decoded tree goes to stdout.
      Save as `notes/adt/m5-<model>-<macOS ver>.{bin,txt}`.
- [ ] Save `proxyclient/tools/dump_pmgr.py` output next to it.
- [ ] Get T8140 and T8132 ADT dumps to diff against (from the m1n1 / Asahi folks, or the
      linux-asahi 7.4 DTs as a proxy).

## 3. Small: m1n1 on M5 (first patches)

### 3a. Check what already works
- [ ] Boot and record the `CPU part: 0x.. rev: 0x..` line. Expect 0x62 (E) / 0x63 (P).
- [ ] Confirm that UART output appears at the `0x385200000` base.
- [ ] Bring up the secondary CPUs. The `CPU_START_OFF_T8112` path in `m1n1/src/smp.c:319` is an
      untested guess for T8142.

### 3b. Compatible-string checks (quick wins)
m1n1 chooses MCC/PCIe/NVMe code from ADT compatibles. T8142 isn't named anywhere, so the M5 may
fall through to "unsupported":
- [ ] **MCC.** `m1n1/src/mcc.c:566-586` and `:612-630` only know `mcc,t8132` / `mcc,t8140` / `mcc,t6041`.
      Find M5's `mcc` compatible in the ADT. If it's `mcc,t8142`, see whether it matches the
      `mcc_init_t8140` layout (`m1n1/src/mcc.c:480`) and add a case.
- [ ] **PCIe.** `m1n1/src/pcie.c:307` handles `apcie,t8132` / `apcie,t6040` only. Check M5's apcie compatible
      and reg layout against `regs_t8132` (`m1n1/src/pcie.c:204`).
- [ ] **NVMe.** `m1n1/src/nvme.c:318` picks M4+ mode from the `nvme-secure-bar` property, so it
      may already work on M5. Verify.

### 3c. CPU features / setup bits (shared with M4)
- [ ] **Chicken bits.** The M5 entries in `midr_parts[]` have a `NULL` init
      (`m1n1/src/chickens.c:162-163`). Compare with M3 (`m1n1/src/chickens/everest.c`, `sawtooth.c`)
      and decide whether `init_t8142_hidra` is needed (new `src/chickens/hidra.c`).
- [ ] **`features_m4`** (`m1n1/src/chickens.c:112`) is shared by M4, A18 Pro and M5. It sets only
      `fast_ipi` and `actlr_el2`. Test each M3 flag on M5 (`disable_dc_mva`, `acc_cfg`,
      `apple_sysregs_unlocked`, `uncore_version`, `nex_powergating`, `mmu_sprr`). If M5 needs
      something M4 doesn't, split out a `features_m5`. Struct: `m1n1/src/utils.h:499`.
- [ ] **Sleep mode.** `features_m4` uses `SLEEP_NONE` with "XXX probably new mode required". Work out the
      mechanism on M5 and add a `SLEEP_*` variant (`m1n1/src/utils.h:487`). This also blocks cpuidle/suspend later.

### 3d. Chip switches with no T8142 case
- [ ] `m1n1/src/cpufreq.c`: 7 `switch (chip_id)` sites (50, 84, 160, 191, 225, 359, 482).
      Get the cluster/pstate layout from the ADT.
- [ ] `m1n1/src/kboot_gpu.c` (78, 160, 209, 504)
- [ ] `m1n1/src/tunables_static.c:217`
- [ ] `m1n1/src/isp.c` (42, 84)

## 4. Medium: kernel / devicetree for T8142

- [ ] Write `t8142.dtsi` plus a MacBook Pro 14" (2025) or Air (2026) board `.dts`, based on the T8140 DT
      in linux-asahi 7.4. Get it to boot to a serial console with the boot framebuffer.
- [ ] Blocks that already have T8140/T8132 drivers. Check whether they work with a compatible fallback:
      AICv3, watchdog, I2C, GPIO.
- [ ] Next: UART, PMU, SPMI, RTC, then DART (most peripherals depend on it).
- [ ] PCIe, then WiFi/BT.
- [ ] NVMe (M4 work is WIP; follow it). Root filesystem on the internal disk.
- [ ] SMC basics (power button, battery info).

## 5. Large / long-term

- [ ] DCP (full display, brightness)
- [ ] USB2/3, Thunderbolt, ATC PHY, DP alt mode (m1n1 side: `m1n1/src/kboot_atc.c`)
- [ ] Keyboard and touchpad
- [ ] Audio: MCA, codecs, speakers
- [ ] GPU (kboot_gpu init plus driver)
- [ ] SEP / TouchID, webcam (ISP), ANE
- [ ] cpuidle and suspend (needs the §3c sleep-mode work)
- [ ] Installer entry

## 6. Hypervisor / RE tooling

- No pinned macOS target for M4+. XNU requires SPTM, and there are numerous bugs
  (`docs/docs/sw/m1n1-hypervisor.md:17`). Recent m1n1 commits (`hv: Handle nXS TLBI`,
  armv9.4-a msr/mrs) are related work.
- [ ] Find out what currently blocks booting XNU under the HV on M5 (SPTM / GXF / TXM).
- [ ] Until the HV works: RE from the ADT, register pokes through the proxy, and the macOS
      kernelcache/kexts read statically.

## 7. Giving back to M4

- Anything in `features_m4`, the chicken bits, or the sleep mode that I figure out on M5 likely applies to M4/A18 Pro too.
  Send it upstream marked "tested on T8142 only" and ask someone with an M4 to test it.

## 8. Open questions / links

- [ ] Check that nobody has started on T8142 before sending patches (the docs say TBA, but ask anyway).
- [ ] Which exact model (MBP 14" 2025 vs Air 2026)? Note the board ID from the ADT.
- [ ] Which upstream branches to track: m1n1 `main`, linux-asahi (the 7.4 T8140/T8132 DTs).
- [ ] Join `#asahi-dev` (OFTC) / Matrix.
