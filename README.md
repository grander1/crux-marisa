# crux-marisa — Xiaomi Mi 9 Pro 5G (crux) custom kernel for Droidspaces

**项目简介**：为小米 Mi 9 Pro 5G（代号 `crux`，骁龙 855，4.14 内核）定制的 A16 内核分支，目标是在解锁 bootloader 的实机上运行 **Droidspaces**（LXC 容器 Linux 发行版）。基于 CAF openela 4.14 源码树，集成 KernelSU 提权，通过 GitHub Actions 云端编译，产出可直接 fastboot 刷写的 `boot.img`。

## Features at a glance

- **Container-ready config** — namespaces (UTS/IPC/USER/PID/NET), cgroups v1 (device/pids/freezer/cpuacct/sched/cpuset/memcg/blk), overlayfs, fuse, veth/bridge/tun/macvlan, full iptables/nftables/nat stack, seccomp+eBPF, checkpoint/restore. See `.ci/droidspaces.config` (~62 symbols).
- **KernelSU** built in-tree (`CONFIG_KSU=y`) — no separate patching step.
- **Cloud CI** — `.github/workflows` + `.ci/build-kernel.sh`, proton-clang toolchain on ubuntu runners, artifact = flashable `boot.img`.
- **VINTF compliance work** — see "The boot dialog" below.
- **Real IKCONFIG exposure** — `/proc/config.gz` reflects the *actual* compiled config, not Xiaomi's pre-baked stock defconfig (see CI note).

## Quick start (flash)

1. Download the latest workflow artifact `crux-droidspaces-boot.zip` from the Actions page.
2. Unzip, grab `out/boot.img` — it is a self-contained Android boot image (header v0, 4 KiB pages, no ramdisk).
3. Reboot device to fastboot, then:
   ```bash
   fastboot flash boot out/boot.img
   fastboot reboot
   ```
   If the device shows the boot-time dialog once and still boots, that is expected (non-fatal; see below).
4. Root check: `su` via KernelSU manager app. Container runtime: see Droidspaces docs.

Backup your stock boot.img first (`fastboot fetch boot` or from the factory image) — rollback is `fastboot flash boot <stock>.img`.

## Known limitations (4.14-openela base)

- **CFS bandwidth (`CONFIG_CFS_BANDWIDTH`)**: cannot be enabled — the vendor
  `CONFIG_SCHED_WALT` Kconfig hard-mutually-excludes it. Enabling it would
  require dropping WALT and breaks Xiaomi sched-freq behavior. Consequence:
  `docker run --cpus` is silently ignored. Use cgroup v2 `cpuset`, or
  `nice`/`ionice` as alternatives.
- **New mount API (`fsopen`/`fsconfig`)**: architecturally absent on 4.14
  (introduced in 5.2). systemd inside containers falls back to legacy syscalls;
  no functional impact observed.
- **FCM3 VINTF kernel compliance**: the boot-time "device internal problem"
  dialog is triggered by `Build.isBuildConsistent()` failing libvintf kernel
  checks against `compatibility_matrix.3.xml`. Required and enforced by CI:
  `CONFIG_AUDIT=y` (also restores avc-denied logging), `CONFIG_FHANDLE=n`
  (note: FHANDLE is `default y` in kconfig, so it must be explicitly disabled
  in crux_defconfig; a fragment cannot express =n).
  Not applicable to this tree (structurally absent or stock-off): DEVKMEM
  (depends on !ARM64), SECURITY_PERF_EVENTS_RESTRICT (no such symbol),
  KPTI/SSBD/errata mitigations (stock ships them off).

## PSTORE / ramoops — enabled in v18 after fixing the DTB reservation

History: enabling `CONFIG_PSTORE_RAM` in v3 (Run #31) **bootlooped** crux, so the
feature was banned and the README claimed crash forensics was impossible here.
That diagnosis was incomplete — the config was never the problem, the reserved
memory layout was.

### Actual root cause (addresses verified in-tree)

```
sm8150.dtsi        ramoops@a1600000   size 0x800000  → 0xa1600000..0xa1e00000
sm8150-sdx50m.dtsi pil_buffer_p1      size 0x02c00000 → 0xa1000000..0xa3c00000
                                                         ^^^^^^^^^^^^^^^^^^^^
                                                      ramoops sits entirely
                                                      inside the PIL buffer
```

The crux overlay (`crux-sm8150-overlay.dts`) includes `sm8150-sdx50m.dtsi`, so
both nodes land in the same tree. The kernel rejects the overlap
(`OF: reserved mem: OVERLAP DETECTED!`), ramoops never registers, and every
`msm_watchdog: Dump setup failed` follows. Enabling PSTORE on top of that is
what hung early boot — pstore had no backing region.

### Fix

`crux-sm8150-overlay.dts` now redefines the node further up the memory map:

```
ramoops@a8800000  size 0x400000   (record/console/pmsg/ftrace 1 MiB each)
```

`0xa8800000` is the first address after the last reserved pool in this map
(`removed-dma-pool` ends exactly there). Region map for reference:

| Region | Range |
|---|---|
| `cont_splash_memory` | `0x9c000000`–`0x9e400000` |
| `pil_buffer_p2` | `0xa0000000`–`0xa1000000` |
| `pil_buffer_p1` | `0xa1000000`–`0xa3c00000` |
| `mhi_mem` | `0xa3c00000`–`0xa4c00000` |
| `removed-dma-pool` | `0xa4c00000`–`0xa8800000` |
| **`ramoops` (new)** | **`0xa8800000`–`0xa8c00000`** |

### Verify after flashing

```sh
ls /sys/fs/pstore/                              # must exist
grep pstore /proc/filesystems                   # nodev pstore
dmesg | grep -i ramoops                         # no OVERLAP DETECTED
dmesg | grep -i "watchdog.*dump"                # should no longer say "setup failed"
```

If the device does **not** boot, the RAM hole is the suspect (bootloader or
hypervisor may not leave `0xa8800000` free). Revert the five `CONFIG_PSTORE*`
lines in `.ci/droidspaces.config` first — the DTB node alone is harmless.

## The boot dialog ("device internal problem") — RESOLVED in v17

Root cause: framework-side VINTF kernel compatibility check
(ActivityManagerService.systemReady → `Build.isBuildConsistent()` → libvintf vs
the FCM matrices in `/system/etc/vintf/compatibility_matrix.*.xml`). The dialog
is non-fatal (shows once per boot) but indicates a real config mismatch.

### The rule that matters: ABSENT ≠ "is not set"

libvintf reads `/proc/config.gz` and behaves differently for the two cases:

| What the config says | What libvintf does |
|---|---|
| the symbol is **not present at all** | skips it — no check |
| `# CONFIG_X is not set` or `CONFIG_X=n` | parses value `n`, **compares** it |

This is the single most important fact about this mechanism. Fabricating
`# CONFIG_X is not set` lines for symbols the kernel does not have converts a
skipped check into a failing one.

### How v15/v16 got this wrong (and v13 was right)

v13 shipped with none of these symbols present and showed **no** dialog. In
v15/v16 an attempt to satisfy the matrices "thoroughly" appended eight fake
entries, which created new violations:

| Symbol | v13 (no dialog) | v16 (dialog) | Matrix actually wants |
|---|---|---|---|
| `CONFIG_PM_AUTOSLEEP` | absent | `=n` | level 1 & 2 want **y** → violated |
| `CONFIG_DEBUG_RODATA` | absent | `=y` | level 4 wants y — but absent was already fine |
| `CONFIG_DEBUG_SET_MODULE_RONX` | absent | `=y` | same |
| `CONFIG_DEVKMEM` / `INET_LRO` / `OABI_COMPAT` | absent | `is not set` | fabricated for no reason |
| `CONFIG_NETFILTER_XT_MATCH_QTAGUID` | absent | `is not set` | fabricated for no reason |
| `CONFIG_NETFILTER_XT_MATCH_PHYSDEV` | absent | `is not set` | **not in any matrix at all** |
| `CONFIG_IP6_NF_NAT` | `y` | spoofed `n` | **not in any matrix at all** |

`CONFIG_IP6_NF_NAT` and `NETFILTER_XT_MATCH_PHYSDEV` appear in **zero**
applicable matrix blocks — the v14/v15 spoofing of them solved nothing.

### Final approach: minimal spoof, two symbols only

Exactly two symbols really exist in `.config` and really need a different
reported value. Everything else is left untouched.

| Symbol | Kernel actually | Reported to VINTF | Why |
|---|---|---|---|
| `CONFIG_SYSVIPC` | `y` | `n` | every matrix level demands `n`; Droidspaces needs it really on |
| `CONFIG_USB_RTL8152` | `y` | `# ... is not set` | `compatibility_matrix.4.xml` demands `n` |

Both are rewritten in `config_data` before gzip — the kernel keeps the code,
only the *reported* config lies. The sed chain lives in `.ci/build-kernel.sh`
(PYMK block) and CI asserts the result plus the absence of every symbol that
must not be fabricated.

Result (Run #55 / v17): **no dialog, Docker networking works.** IKCFG is 6,301
lines, identical to v13 apart from those two entries.

### Don't trust the "stock" config blob

The IKCFG inside a stock crux `boot.img` is **not** a reliable benchmark: it is
Xiaomi's static `config_data.gz`, and the copy inspected during this
investigation contained `lz4k_oplus`, `VSERVICES_*` and `CONFIG_XIAOMI_SOLUTION`
together — impossible for a single real device kernel. Reasoning "stock is
absent there, so it's safe" against that file is unsound; v13's observed
behaviour is the better reference.

## CI note: kernel/Makefile IKCONFIG patch

Xiaomi's vendor `kernel/Makefile` contains three `ifneq ($(CONFIG_MACH_XIAOMI_*),y)`
rules that re-point `$(obj)/config_data.gz` at static files under
`arch/arm64/configs/*_stock_defconfig` instead of the real build `.config`.
This makes the embedded `IKCONFIG` blob (and `/proc/config.gz`) always show the
stock config, regardless of what was actually compiled in. `.ci/build-kernel.sh`
(PYMK block) removes those rules at build time and restores the standard upstream
dependency chain: real `.config` → `config_data` (two-symbol sed, see the dialog
section above) → `config_data.gz` → `configs.o`.

**Idempotency is enforced**: the PYMK block deletes any previously injected
`# --- droidspaces:` rule block (scanning forward to its `$(call if_changed,gzip)`
tail) before re-inserting, so repeated runs converge to exactly one block. An
earlier non-idempotent variant (`sed -i '$ a\...'` inside the rule) duplicated
injected lines on every make invocation and ballooned the IKCFG blob from 6,284
to 18,852 lines — do not reintroduce append-style injection.

Post-build the CI extracts the IKCFG blob from `Image.gz-dtb` and asserts:
MACVLAN/MASQUERADE/AUDIT =y, QUOTA2_LOG =y, LOW_MEMORY_KILLER =y,
PERF_EVENTS_RESTRICT =y, SYSVIPC reported `n` while really `y`, RTL8152 reported
`# ... is not set`, IP6_NF_NAT left untouched at `y`, FHANDLE absent, and the
six symbols that must never be fabricated are asserted ABSENT. Any mismatch
fails the run.

## Repacking onto a signed/footered boot partition (offline recipe)

CI emits a bare boot.img (header v0, ~20.7 MiB). Some devices/ROMs expect the
stock layout: header **v1**, `os_version` set, AVB footer + hash descriptor
(sha256 digest over `[0, original_image_size)`). To graft the new kernel onto the
stock image without touching anything else:

1. Copy stock header page verbatim; patch only `kernel_size` (u32 @ offset 8).
2. Layout: `header(4096) || Image.gz-dtb || zero-pad to 4096 boundary` = new `original_image_size`.
3. In the appended vbmeta (896 B), walk aux descriptors (aux starts at +256):
   for tag==2 (AvbHashDescriptor) update `image_size` (u64) and rewrite the
   32-byte digest with `sha256(salt || image[0:image_size])`. Keep salt, partition
   name, property descriptors (fingerprint/os_version/security_patch) untouched.
4. Update the 64-byte `AVBf` footer: `original_image_size` and `vbmeta_offset`
   both = new content size; `vbmeta_size` stays 896.
5. Zero-pad to the exact partition size (134,217,728 for crux boot).

Verified result: vbmeta diff confined to 35 bytes inside the aux block; all other
bytes identical to stock.

## Bootloop lessons (hard rules for this tree)

One config change was proven to bootloop on real crux hardware and stays banned;
a second one turned out to be a DTB problem rather than a config problem:

1. ~~**CONFIG_PSTORE / PSTORE_RAM** (v3, Run #31)~~ — **RESOLVED in v18.** The
   bootloop was caused by ramoops colliding with `pil_buffer_p1_region`, not by
   pstore itself. With the node moved to `0xa8800000` the feature is enabled
   again. See the PSTORE section above.
2. **CONFIG_SECURITY_YAMA=y** (v6/v7, Runs #35/#36): YAMA LSM registration breaks vendor
   sepolicy assumptions at boot (stock ships it "not set"). Binary-search evidence: v7
   restored SYSFS_SYSCALL=y but kept YAMA=y and still bootlooped; SYSFS_SYSCALL=n is
   therefore NOT the culprit (v8 with SYSFS_SYSCALL=y boots fine). **Still banned.**

General rules derived:

- Only ADD pure networking/module symbols that have no stock conflict.
- Never flip stock-y syscall-table/security symbols. FHANDLE=off is the single
  exception, forced by FCM3 VINTF, verified safe on v4+.
- **When a feature bootloops, check the DTS reservation before blaming the
  config.** PSTORE was banned for nine versions over a memory overlap that a
  5-line overlay patch fixed.
- **Never fabricate config entries for VINTF.** A symbol absent from the tree
  must stay absent — see the dialog section. This one cost v14 through v16.

## Repository layout

```
.ci/
  build-kernel.sh      # full pipeline: defconfig → fragment merge → regen → verify
                       #   → PYMK Makefile patch → compile → IKCFG assert → mkbootimg
  droidspaces.config   # container feature fragment (~62 symbols)
arch/arm64/configs/
  crux_defconfig       # vendor base defconfig (FHANDLE explicitly =n)
mm/Kconfig             # + ANDROID_LOW_MEMORY_KILLER stub
mm/lowmemorykiller_compat.c  # lmk_kill_possible() -> false
security/Kconfig.hardening   # + SECURITY_PERF_EVENTS_RESTRICT stub
KernelSU (in-tree)     # CONFIG_KSU=y
```

## Release state

**v17 — verified on device**: no "device internal problem" dialog, Docker
networking fully functional. Run #55, commit `c39571c36e11`.
IKCFG: 6,301 lines, two spoofed entries (`SYSVIPC`, `USB_RTL8152`), everything
else untouched.

**v18 — pending device verification**: adds pstore/ramoops crash forensics by
relocating the ramoops reservation out of the PIL buffer window. If it does not
boot, revert the five `CONFIG_PSTORE*` lines in `.ci/droidspaces.config`; nothing
else in v18 changes behaviour.

Two-symbol spoof reminder for future work: the *only* symbols whose reported
value may differ from the compiled value are `CONFIG_SYSVIPC` and
`CONFIG_USB_RTL8152`. Adding a third requires showing it exists in `.config`
**and** appears in an applicable `compatibility_matrix.*.xml` block with a
conflicting value. `CONFIG_IP6_NF_NAT` satisfies neither condition.
