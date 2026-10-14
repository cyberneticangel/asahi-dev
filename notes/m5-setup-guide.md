# M5 Setup Guide (Step 0)

How to go from a stock-macOS M5 and a Linux box to a working m1n1 proxy shell, with the M5's ADT
and pmgr dumps saved in this repo. This expands §2 of [`m5-support.md`](m5-support.md).

> Personal notes. Commands assume you start at the repo root (`asahi-dev/`) unless a step says
> otherwise. Items marked **VERIFY** are guesses that nobody has confirmed on M5 yet.

**Setup at a glance**

```
 Linux box (proxy host)                         M5 (target)
 ┌──────────────────────────┐   USB-C cable   ┌──────────────────────────────┐
 │ nix devshell             │◄───────────────►│ container 1: your macOS      │
 │ m1n1/proxyclient         │  /dev/m1n1      │ container 2: macOS stub      │
 │ make → m1n1/build/*.bin  │                 │   └─ boot object = m1n1.bin  │
 └──────────────────────────┘                 └──────────────────────────────┘
```

---

## 0. What you need

- The M5, with a Time Machine backup made **before** you start partitioning.
- About 80 GB free on the M5 (a second macOS install, plus some headroom).
- A Linux box (x86_64 or aarch64) with Nix, on the same network as the M5.
- A **data** USB-C↔USB-C or USB-C↔A cable. Charge-only cables enumerate nothing.

---

## 1. Prepare the Linux host

```sh
# Nix with flakes enabled, then:
git clone <this repo> asahi-dev && cd asahi-dev
git clone --recursive https://github.com/AsahiLinux/m1n1.git
direnv allow            # or: nix develop
make -C m1n1 -j         # → m1n1/build/m1n1.bin and m1n1.macho
```

`m1n1/config.h` already has `#define TARGET T8142`, so the build prints early debug output on the
T8142 UART. Leave it on.

Give your user access to the USB serial ports:

```sh
sudo cp m1n1/udev/80-m1n1.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo usermod -aG dialout "$USER"   # "uucp" on Arch; log out and back in
```

**You should see:** `ls m1n1/build/m1n1.bin` exists, and
`python3 -c "import construct, serial"` prints nothing inside the devshell.

---

## 2. Make room on the M5 for a second macOS

m1n1 replaces the kernel of **one** macOS install in its boot policy. Use a separate install for
it so your main macOS keeps Full Security and never changes.

1. In macOS, open Disk Utility → select the internal disk (View → Show All Devices) →
   **Partition** → `+` → format **APFS**, about 70 GB. This must be a new *container*, not just a
   volume in the existing one.
2. Reboot into Recovery (hold the power button → Options). Choose **Reinstall macOS** and pick the
   new partition as the destination.
3. Boot the new install. Finish Setup Assistant and create an **admin user with a password**.
   1TR uses it to prove machine ownership.

**You should see:** both installs in the startup picker (hold power at boot).

> **VERIFY:** whether raw m1n1 boot on M5 needs a specific macOS version for the stub. Recovery
> installs the latest release of the major version it ships with. Write down the version you
> got (`sw_vers`).

---

## 3. Install m1n1 on the new install (from 1TR)

1TR is the "one true recovery". You enter it by holding the power button from a full shutdown, not
by any other recovery path.

1. In the new macOS: System Settings → General → Startup Disk → choose the **new** install.
   The helper below runs `bless --getboot` and so targets whichever disk is the default.
2. Shut down. Hold the power button until "Loading startup options…" appears → Options →
   select the new install if asked → log in → Utilities → **Terminal**.

**Option A: Asahi installer expert mode (try first).** Run `curl https://alx.sh | sh`, enable
expert mode, and pick the m1n1 tethered/proxy-only option.
> **VERIFY:** the installer may refuse the M5 as unsupported. If it does, use Option B.

**Option B: `kmutil` by hand, using m1n1's helper.**

On the Linux box:

```sh
cd m1n1 && ./tools/kmutil.py        # serves a script with build/m1n1.bin embedded on :8000
```

In the 1TR Terminal on the M5:

```sh
sh <(curl http://<linux-box-ip>:8000)   # not "curl | sh"; the script reads stdin
```

The script runs
`kmutil configure-boot -c m1n1.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v <vol>`.
Enter your password, accept the downgrade to **Permissive Security** for this install only, and
let it reboot.

**You should see:** the M5 boots into the m1n1 logo and text console instead of macOS. With no
payload appended, m1n1 stops in **proxy mode** and waits for the host.

---

## 4. Connect the proxy

1. Plug the cable into the M5's **DFU port** (on MacBooks, usually the rear-left USB-C). Plug the
   other end into the Linux box.
   > **VERIFY:** which port is the DFU port on your model. Try the others if nothing shows up.
2. On Linux:

   ```sh
   ls -l /dev/m1n1 /dev/m1n1-sec        # created by the udev rule (raw: /dev/ttyACM0, ttyACM1)
   export M1N1DEVICE=/dev/m1n1
   python3 m1n1/proxyclient/tools/shell.py
   ```

3. In the shell:

   ```python
   hex(u.mrs("MIDR_EL1"))   # part number bits [15:4]: expect 0x62 (E-core) or 0x63 (P-core)
   u.adt["/"].target_type, u.adt["/"].compatible
   ```

**You should see:** a `>>>` prompt with no timeouts, and a MIDR containing part `0x62` or
`0x63`. Write the `CPU part` line from the m1n1 console and the board ID into `m5-support.md` §3a
and §8.

---

## 5. Fast iteration loop

You never need 1TR again for m1n1 changes. Rebuild and chainload over USB:

```sh
make -C m1n1 -j && python3 m1n1/proxyclient/tools/chainload.py -r m1n1/build/m1n1.bin
```

**You should see:** the M5 console restart with your new build tag, and the proxy come back up.

---

## 6. Dump the ADT and pmgr

```sh
mkdir -p notes/adt
cd m1n1/proxyclient
B=m5-<board>-macos<ver>      # e.g. m5-j714-macos26.0
python3 -m m1n1.adt -r ../../notes/adt/$B.bin > ../../notes/adt/$B.txt
python3 tools/dump_pmgr.py > ../../notes/adt/$B-pmgr.txt
```

- `-r` writes the **raw ADT binary** to the path you give it and prints the decoded tree to
  stdout (`proxyclient/m1n1/adt.py:875-893`). Keep both: the `.bin` reloads with
  `python3 -m m1n1.adt <file>` without the hardware. It refuses to overwrite an existing file.
  The `.txt` may start with some proxy connection messages. Trim them off.

**You should see:** something for each compatible that §3b needs:

```sh
grep -nE 'compatible.*(mcc|apcie|nvme)' ../../notes/adt/$B.txt
```

---

## 7. Reference dumps (T8140 / T8132)

- Ask in `#asahi-dev` on OFTC for T8140 (A18 Pro) and T8132 (M4) ADT dumps.
- Until you have them, use the linux-asahi 7.4 device trees as a stand-in:
  `arch/arm64/boot/dts/apple/t8140*.dtsi` and `t8132*.dtsi` in `linux/`.

**You should see:** reference files saved in `notes/adt/` next to the M5 dump, ready to diff.

---

## Troubleshooting

| Symptom | Try |
|---|---|
| No `/dev/ttyACM*` | Use another port or a data cable. Watch `dmesg -w` while plugging in. |
| `Permission denied` on `/dev/m1n1` | Not in `dialout`/`uucp` yet: log out and back in. |
| kmutil: `not paired` | You're in the wrong recovery. Boot 1TR with the **new** install as the default. |
| m1n1 hangs before USB comes up | Use a physical debug UART (`docs/docs/hw/soc/serial-debug.md`), or try a `#define BRINGUP` build. |
| Proxy times out mid-command | `export M1N1TIMEOUT=10` and reconnect. Reboot the M5 if it doesn't recover. |
| Want it all gone | Delete the second container in Disk Utility. Your main macOS's security policy was never changed. |
