#!/usr/bin/env bash
# Droidspaces build for crux-marisa A16 (4.14.357, Non-GKI, in-tree KernelSU)
# GitHub Actions ubuntu-22.04 + proton-clang
# Strategy: pure out-of-tree via O=out for ALL makes (never cd into out/ without O=,
# which would make srctree=".." and trip prepare3). Source tree is mrproper-cleaned first.
set -uo pipefail
WORKDIR="${WORKDIR:-$HOME/kernel-build}"
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFCONFIG="crux_defconfig"
FRAGMENT="$KERNEL_DIR/.ci/droidspaces.config"
CLANG_BIN="$WORKDIR/proton-clang/bin"
ARCH=arm64
JOBS="$(nproc)"
MK=(O=out ARCH=$ARCH
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld"
  AR="$CLANG_BIN/llvm-ar" NM="$CLANG_BIN/llvm-nm"
  OBJCOPY="$CLANG_BIN/llvm-objcopy" STRIP="$CLANG_BIN/llvm-strip"
  LLVM=1 LLVM_IAS=1 CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-)
cd "$KERNEL_DIR"
echo "::group::apply Droidspaces non-GKI kernel patches"
# Patch 01 (xt_qtaguid dev_get_stats) is N/A: this tree has no net/netfilter/xt_qtaguid.c
# (CONFIG_ANDROID_PARANOID_NETWORK absent). Only patch 02 applies.
PATCHDIR="$KERNEL_DIR/.ci/patches/non-GKI"
if [ -d "$PATCHDIR" ]; then
  for p in "$PATCHDIR"/*.patch; do
    [ -e "$p" ] || continue
    echo "--- applying $(basename "$p")"
    if patch -p1 --forward --dry-run < "$p" >/dev/null 2>&1; then
      patch -p1 --forward < "$p"
    elif patch -p1 --forward --dry-run -R < "$p" >/dev/null 2>&1; then
      echo "already applied, skipping"
    else
      echo "::error::patch $(basename "$p") failed to apply"; exit 1
    fi
  done
else
  echo "no patch dir, skipping"
fi
# Assertion: the cgroup NOPREFIX restore must be present in the compiled tree.
grep -q 'CGRP_ROOT_NOPREFIX) && !(cft->flags & CFTYPE_NO_PREFIX)' kernel/cgroup/cgroup.c \
  || { echo "::error::cgroup NOPREFIX patch missing"; exit 1; }
echo "patch verification OK"
echo "::endgroup::"
echo "::group::clean source tree"
make ARCH=$ARCH mrproper >/dev/null 2>&1 || true
rm -rf out .config .config.old
rm -f include/config/auto.conf
rm -rf include/config include/generated
mkdir -p out
echo "::endgroup::"
echo "::group::defconfig + fragment"
make "${MK[@]}" "$DEFCONFIG"
# In-place merge of the droidspaces fragment. kconfig's conf program keeps the
# FIRST occurrence of a duplicated symbol when reading a .config, so appending
# fragment lines to the end of out/.config is silently ignored by olddefconfig.
# Instead: for each fragment symbol already present as "# X is not set", flip it
# in place; append only symbols that are absent entirely.
echo "# --- droidspaces fragment (in-place merge) ---"
python3 - <<'PYMERGE'
import re
frag = open('.ci/droidspaces.config').read().splitlines()
wanted = {}
for line in frag:
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=([ym])$', line.strip())
    if m:
        wanted[m.group(1)] = m.group(2)
path = 'out/.config'
lines = open(path).read().splitlines()
seen = set()
out = []
for line in lines:
    m = re.match(r'^# (CONFIG_[A-Za-z0-9_]+) is not set$', line)
    if m and m.group(1) in wanted:
        out.append('%s=%s' % (m.group(1), wanted[m.group(1)]))
        seen.add(m.group(1))
        continue
    m2 = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=', line)
    if m2 and m2.group(1) in wanted:
        seen.add(m2.group(1))
        out.append('%s=%s' % (m2.group(1), wanted[m2.group(1)]))
        continue
    out.append(line)
missing = [k + '=' + v for k, v in sorted(wanted.items()) if k not in seen]
out.extend(missing)
open(path, 'w').write(chr(10).join(out) + chr(10))
print('fragment merged: flipped/kept %d, appended %d (%s)' % (len(seen), len(missing), [x.split('=')[0] for x in missing]))
PYMERGE
make "${MK[@]}" olddefconfig
# Post-olddefconfig verification: fail fast if any fragment symbol did not stick.
python3 - <<'PYVERIFY'
import re, sys
wanted = {}
for line in open('.ci/droidspaces.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=([ym])$', line.strip())
    if m:
        wanted[m.group(1)] = m.group(2)
cur = {}
for line in open('out/.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$', line.strip())
    if m:
        cur.setdefault(m.group(1), m.group(2))
bad = [(k, cur.get(k, 'ABSENT')) for k, v in wanted.items() if cur.get(k) != v]
if bad:
    print('FRAGMENT NOT APPLIED:', bad)
    sys.exit(1)
print('fragment fully applied (%d symbols)' % len(wanted))
PYVERIFY
RC=$?
if [ "$RC" != 0 ]; then echo "::error::fragment merge failed"; exit 1; fi
# Snapshot the verified config, then REGENERATE it from scratch via
# KCONFIG_ALLCONFIG so that no vendor pre-baked .config copy step can clobber
# our fragment later in the build. `make allnoconfig KCONFIG_ALLCONFIG=...`
# resolves ONLY against our file + Kconfig deps; it does not run any product-
# specific defconfig hook.
cp out/.config out/.config.merged
rm -rf include/config include/generated out/include/config out/include/generated
make "${MK[@]}" allnoconfig >/dev/null
make KCONFIG_ALLCONFIG="$PWD/out/.config.merged" "${MK[@]}" alldefconfig
# Restore full-fidelity merged config as authoritative input, then sync.
cp out/.config.merged out/.config
make "${MK[@]}" olddefconfig
# Second verification pass on the regenerated config.
python3 - <<'PYVERIFY2'
import re, sys
wanted = {}
for line in open('.ci/droidspaces.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=([ym])$', line.strip())
    if m:
        wanted[m.group(1)] = m.group(2)
cur = {}
for line in open('out/.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$', line.strip())
    if m:
        cur.setdefault(m.group(1), m.group(2))
bad = [(k, cur.get(k, 'ABSENT')) for k, v in wanted.items() if cur.get(k) != v]
if bad:
    print('REGEN FRAGMENT LOST:', bad)
    sys.exit(1)
print('regen verified (%d symbols)' % len(wanted))
PYVERIFY2
RC=$?
if [ "$RC" != 0 ]; then echo "::error::regenerated config lost fragment symbols"; exit 1; fi
echo "::endgroup::"
echo "::group::audit key configs"
FAIL=0
for c in CONFIG_PID_NS CONFIG_USER_NS CONFIG_NET_NS \
         CONFIG_OVERLAY_FS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS \
         CONFIG_NF_NAT CONFIG_QCOM_KGSL \
         CONFIG_SECCOMP_FILTER CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT \
         CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE \
         CONFIG_BRIDGE CONFIG_BRIDGE_NETFILTER CONFIG_NETFILTER_ADVANCED \
         CONFIG_SYSVIPC CONFIG_NAMESPACES CONFIG_FAIR_GROUP_SCHED \
         CONFIG_TMPFS_POSIX_ACL CONFIG_BLK_DEV_LOOP CONFIG_EXT4_FS CONFIG_FW_LOADER_USER_HELPER \
         CONFIG_NF_CT_NETLINK CONFIG_NF_NAT_REDIRECT CONFIG_NF_NAT_MASQUERADE_IPV4 \
         CONFIG_IP_ADVANCED_ROUTER CONFIG_IP_MULTIPLE_TABLES CONFIG_IPV6_MULTIPLE_TABLES \
         CONFIG_IP6_NF_FILTER CONFIG_IP6_NF_TARGET_REJECT \
         CONFIG_NETFILTER_XT_TARGET_TCPMSS CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
         CONFIG_IP_SET CONFIG_IP_SET_HASH_IP CONFIG_IP_SET_HASH_NET CONFIG_NETFILTER_XT_SET \
         CONFIG_NF_TABLES CONFIG_NF_TABLES_IPV4 CONFIG_NF_TABLES_IPV6 CONFIG_NFT_CHAIN_NAT_IPV4 \
         CONFIG_DUMMY CONFIG_VETH CONFIG_TUN; do
    if grep -qE "^$c=[ym]" out/.config; then
        grep -E "^$c=" out/.config
    else
        echo "MISSING: $c"; FAIL=1
    fi
done
grep -E '^CONFIG_KSU=[ym]' out/.config || { echo 'MISSING: CONFIG_KSU'; FAIL=1; }
if [ "$FAIL" = 1 ]; then echo "::error::required configs missing"; exit 1; fi
echo "::endgroup::"
# --- Fix vendor IKCONFIG hijack: kernel/Makefile embeds a stock defconfig
# file instead of the real .config (ifneq rules for other products win in O=out
# builds). Replace with standard upstream recipe depending on .config.
python3 - <<'PYMK'
mk="kernel/Makefile"
txt=open(mk).read()
lines=txt.split("\n")
out=[]; i=0; removed=0
while i < len(lines):
    l=lines[i]
    if l.startswith("$(obj)/config_data.gz: arch/arm64/configs/"):
        removed+=1; i+=1
        while i < len(lines) and lines[i].strip()!="endif":
            i+=1
        continue
    if l.startswith("# --- droidspaces:"):
        j=i
        while j < len(lines) and lines[j].strip()!="$(call if_changed,gzip)":
            j+=1
        i = j+1 if j < len(lines) else j
        continue
    out.append(l); i+=1
print("stock rules removed:", removed)
TAB=chr(9)
ti=[n for n,x in enumerate(out) if x.strip()=="targets += config_data.gz"][0]
block=[
 "# --- droidspaces: IKCONFIG spoof chain (build-time, no filechk) ---",
 "# MINIMAL spoof: only symbols that REALLY EXIST and whose value must differ.",
 "# Anything absent from the .config stays absent -- libvintf skips unknown keys,",
 "# and fabricating '# CONFIG_X is not set' lines makes it compare them (v15/v16",
 "# regression: PM_AUTOSLEEP reported n while matrix level 1/2 demands y).",
 "$(obj)/config_data: $(realpath $(obj))/../.config FORCE",
 TAB+"$(Q)sed \\",
 TAB+"  -e 's/^CONFIG_SYSVIPC=y$$/CONFIG_SYSVIPC=n/' \\",
 TAB+"  -e 's/^CONFIG_USB_RTL8152=y$$/# CONFIG_USB_RTL8152 is not set/' \\",
 TAB+"  $< > $@.tmp",
 TAB+"$(Q)grep -q '^CONFIG_SYSVIPC=n$$' $@.tmp || { rm -f $@.tmp; exit 1; }",
 TAB+"$(Q)grep -q '^# CONFIG_USB_RTL8152 is not set$$' $@.tmp || { rm -f $@.tmp; exit 1; }",
 TAB+"$(Q)grep -q '^CONFIG_PM_AUTOSLEEP=y$$' $@.tmp || { rm -f $@.tmp; exit 1; }",
 TAB+"$(Q)mv -f $@.tmp $@ && echo 'ikconfig-spoof ok (minimal: SYSVIPC + RTL8152 only)'",
 "",
 "$(obj)/config_data.gz: $(obj)/config_data FORCE",
 TAB+"$(call if_changed,gzip)",
]
out[ti+1:ti+1]=block
open(mk,"w").write("\n".join(out))
print("kernel/Makefile patched")
PYMK
echo "::group::build Image.gz-dtb"
# Debug: find which file carries the stock pre-baked config markers.
grep -l 'PRODUCT_CRUX is not set' arch/arm64/configs/* 2>/dev/null || true
md5sum out/.config
# Last-moment assertion: MACVLAN/IP6_NF must still be =y immediately before compile.
for c in CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE CONFIG_AUDIT; do
  grep -qE "^$c=y" out/.config || { echo "::error::$c lost just before build"; md5sum out/.config; exit 1; }
done
if grep -qE '^CONFIG_FHANDLE=y' out/.config; then echo "::error::CONFIG_FHANDLE must be off (FCM3)"; exit 1; fi
if [ -f include/config/auto.conf ]; then grep -E '^CONFIG_(MACVLAN|IP6_NF_NAT)=' include/config/auto.conf || echo 'WARN: not in auto.conf'; fi
make "${MK[@]}" -j"$JOBS" Image.gz-dtb 2>&1 | tee build.log
BUILD_RC=${PIPESTATUS[0]}
if [ "$BUILD_RC" != 0 ]; then echo "::error::kernel compile failed rc=$BUILD_RC"; grep -nE 'error:|Error|FAILED' build.log | tail -40 || true; exit 1; fi
# Post-build: verify the IKCFG blob embedded in the actual artifact.
python3 - <<'PYIKCFG'
import zlib, gzip, sys

raw = open('out/arch/arm64/boot/Image.gz-dtb','rb').read()
img = None
if raw[:2] == b'\\x1f\\x8b':
    img = gzip.decompress(raw)
else:
    try:
        img = zlib.decompressobj(-15).decompress(raw[10:])
    except Exception:
        img = zlib.decompress(raw[10:])
i = img.find(b'IKCFG_ST')
if i < 0:
    print('NO IKCFG in artifact'); sys.exit(1)
seg = img[i+8:]
e = seg.find(b'IKCFG_ED')
blob = seg[:e]
def try_decompress(b):
    cands = [b]
    if len(b) > 10: cands.append(b[10:])
    for data in cands:
        if data[:2] == b'\\x1f\\x8b':
            try: return gzip.decompress(data)
            except Exception: pass
        try: return zlib.decompressobj(-15).decompress(data)
        except Exception: pass
        try: return zlib.decompress(data)
        except Exception: pass
    return None
data = try_decompress(blob)
if data is None:
    data = try_decompress(b'\\x1f\\x8b\\x08\\x00\\x00\\x00\\x00\\x00\\x02\\xff' + blob)
if data is None:
    print('IKCFG DECOMPRESS FAILED, first bytes:', blob[:16].hex()); sys.exit(1)
cfg = data.decode(errors='replace')
ok = True
for k in ['CONFIG_MACVLAN','CONFIG_IP6_NF_TARGET_MASQUERADE','CONFIG_AUDIT']:
    hit = [l for l in cfg.splitlines() if l.startswith(k+'=')]
    good = any(h.endswith('=y') or h.endswith('=m') for h in hit)
    if not good:
        print('IKCFG BAD:', k, hit); ok = False
    else:
        print('IKCFG OK:', k, hit)
nat = [l for l in cfg.splitlines() if l.startswith('CONFIG_IP6_NF_NAT')]
if nat != ['CONFIG_IP6_NF_NAT=y']:
    print('IKCFG BAD: IP6_NF_NAT should be untouched (=y), got', nat); ok = False
else:
    print('IKCFG OK: IP6_NF_NAT left alone (=y)')

# --- MINIMAL spoof assertions ---
# Only two symbols are rewritten; everything else must stay exactly as compiled.
def expect(key, want):
    global ok
    lines = [l.strip() for l in cfg.splitlines() if l.strip().startswith(key + '=') or l.strip() == '# %s is not set' % key]
    if want == 'n':
        good = (lines == ['# %s is not set' % key]) or (lines == ['%s=n' % key])
    elif want == 'y':
        good = (lines == ['%s=y' % key])
    else:
        good = any(l.endswith(want) for l in lines)
    if not good:
        print('IKCFG BAD: %s want %s, got %s' % (key, want, lines)); ok = False
    else:
        print('IKCFG OK: %s -> %s' % (key, want))

expect('CONFIG_SYSVIPC', 'n')
expect('CONFIG_USB_RTL8152', 'n')
expect('CONFIG_PM_AUTOSLEEP', 'y')     # must stay y: matrix level 1/2 demand y

# symbols we deliberately do NOT fabricate: they must remain ABSENT
for k in ['CONFIG_DEVKMEM', 'CONFIG_INET_LRO', 'CONFIG_OABI_COMPAT',
          'CONFIG_DEBUG_RODATA', 'CONFIG_DEBUG_SET_MODULE_RONX',
          'CONFIG_NETFILTER_XT_MATCH_QTAGUID']:
    hit = [l.strip() for l in cfg.splitlines()
           if l.strip().startswith(k + '=') or l.strip() == '# %s is not set' % k]
    if hit:
        print('IKCFG BAD: %s must stay ABSENT, got %s' % (k, hit)); ok = False
    else:
        print('IKCFG OK: %s absent (not fabricated)' % k)
binder = [l for l in cfg.splitlines() if l.startswith('CONFIG_ANDROID_BINDER_DEVICES=')]
if binder:
    print('IKCFG INFO: ANDROID_BINDER_DEVICES =', binder[0])
else:
    print('IKCFG INFO: ANDROID_BINDER_DEVICES absent')

fh=[l for l in cfg.splitlines() if l.startswith('CONFIG_FHANDLE=')]
if fh:
    print('IKCFG BAD: CONFIG_FHANDLE should be off, got', fh); ok=False
else:
    print('IKCFG OK: CONFIG_FHANDLE off')
q2=[l for l in cfg.splitlines() if l.startswith('CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG')]
if q2 != ['CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG=y']:
    print('IKCFG BAD: QUOTA2_LOG must be =y, got', q2); ok=False
else:
    print('IKCFG OK: QUOTA2_LOG=y')
for k in ['CONFIG_ANDROID_LOW_MEMORY_KILLER','CONFIG_SECURITY_PERF_EVENTS_RESTRICT']:
    hit=[l for l in cfg.splitlines() if l.startswith(k+'=')]
    if hit != [k+'=y']:
        print('IKCFG BAD: %s must be =y, got' % k, hit); ok=False
    else:
        print('IKCFG OK: %s=y' % k)

# pstore/ramoops must be compiled in (v18) - the DTB now provides a valid region
for k in ['CONFIG_PSTORE','CONFIG_PSTORE_RAM','CONFIG_PSTORE_CONSOLE','CONFIG_PSTORE_PMSG']:
    hit=[l for l in cfg.splitlines() if l.startswith(k+'=')]
    if hit != [k+'=y']:
        print('IKCFG BAD: %s must be =y, got' % k, hit); ok=False
    else:
        print('IKCFG OK: %s=y' % k)
print('IKCFG total lines:', len(cfg.splitlines()))
sys.exit(0 if ok else 1)
PYIKCFG
IKRC=$?
if [ "$IKRC" != 0 ]; then echo "::error::embedded IKCFG does not match fragment"; exit 1; fi
echo "::endgroup::"
echo "::group::pack boot.img"
MKBOOTIMG="$HOME/kernel-build/mkbootimg/mkbootimg"
if [ ! -x "$MKBOOTIMG" ]; then echo "::error::mkbootimg binary not found at $MKBOOTIMG"; exit 1; fi
echo "using $MKBOOTIMG"
BOARD_CMDLINE="console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xa90000 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 loop.max_part=7 androidboot.usbcontroller=a600000.dwc3 buildvariant=user"
"$MKBOOTIMG" \
    --base 0x00000000 \
    --pagesize 4096 \
    --kernel out/arch/arm64/boot/Image.gz-dtb \
    --cmdline "$BOARD_CMDLINE" \
    --output out/boot.img
PACK_RC=$?
if [ "$PACK_RC" -ne 0 ] || [ ! -f out/boot.img ]; then
    echo "::error::boot.img packing failed (rc=$PACK_RC)"
    exit 1
fi
echo "::endgroup::"
ls -lh out/boot.img out/arch/arm64/boot/Image* 2>/dev/null || true