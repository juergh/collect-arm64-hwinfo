# Live Hardware Debugging with WinDbg

`collect-hwinfo.ps1` captures static WMI/CIM/PnP/ACPI/EDID snapshots. Some
facts can only be obtained by reading hardware registers in real time and
watching them change while a device is toggled — this requires an
interactive WinDbg kernel-debugging session on the target machine.

This document covers:
- Proving which GPIO is PERST#/CLKREQ#/WAKE#/power-enable for a given PCIe
  or USB device, by watching TLMM registers change live during a
  disable/enable cycle (not just a static snapshot).
- Confirming which kernel-mode drivers own a block of GPIO hardware.
- Decompiling and searching the raw ACPI DSDT blob that `collect-hwinfo.ps1`
  already saves, to find debug strings and GPIO cross-references embedded
  in the firmware's own ACPI bytecode.

## Prerequisites

- Administrator access on the target Windows ARM64 machine.
- "WinDbg Preview" installed from the Microsoft Store (provides the
  `kdARM64.exe` App Execution Alias used below).
- ACPICA `iasl` on a Linux machine, to decompile ACPI tables already saved
  by `collect-hwinfo.ps1`.

## 1. Enable kernel debugging (one-time, requires reboot)

As Administrator:
```powershell
bcdedit /set debug on
shutdown /r /t 0
```

This persists across reboots. **Disable it when done** (also requires a
reboot):
```powershell
bcdedit /set debug off
shutdown /r /t 0
```

## 2. Attach a local kernel debugger session

The plain `kd.exe` binary under `WindowsApps` is ACL-locked and won't run
directly. Use the `kdARM64.exe` App Execution Alias instead, with `-kl` to
attach to the *local* running kernel (no second machine needed):

```powershell
kdARM64.exe -kl -c "<windbg commands separated by ;>; q"
```

The trailing `q` quits the debugger so the one-liner returns control to the
shell. Chain multiple read commands with `;`.

**Caution:** a malformed command can leave `kd`/`kdARM64` waiting for input.
If a process hangs, kill it with Task Manager or `taskkill /IM kd.exe /F`.

## 3. Read a GPIO's TLMM registers directly

On Qualcomm X1E/X1P SoCs, the TLMM (pin controller) is memory-mapped at base
`0x0f100000`, with each GPIO occupying a `0x1000` (4KB)-aligned block:

```
GPIO_N_address = 0x0f100000 + (N * 0x1000)
```

Each GPIO has two relevant 32-bit registers:
- **Offset +0x0 (CFG/CTL register):** bit 9 = Output Enable (`1`=output,
  `0`=input); bits 2-5 = pin mux/function select.
- **Offset +0x4 (IN/OUT register):** bit 0 = current input value on the
  pin; bit 1 = value being driven out (meaningful only when OE=1).

Read 4 consecutive 32-bit words (covers both registers plus 2 extra) for
GPIO 143 as an example:

```powershell
kdARM64.exe -kl -c "!dd 0x0f18f000 L4; q"
```

(`0x0f18f000` = `0x0f100000 + 143*0x1000`). The output's first word is CFG,
second is IN/OUT.

**Interpreting it:**
- `CFG=0x200, IO=0x3` -> OE=1 (output), mux=0 (plain GPIO), driven high.
- `CFG=0x1, IO=0x0` -> OE=0 (input), reading low.
- `CFG=0x7, IO=0x1` -> OE=1, mux=1 (a non-GPIO function like a PCIe clock
  pin), inactive/high.

## 4. Prove a GPIO's *role* by toggling the device live

A single register read only tells you a *static* value — it doesn't prove
the pin is actually PERST#/CLKREQ#/WAKE# for a given device. To get real
proof, disable and re-enable the PCI device while re-reading the same
registers:

```powershell
# 1. Find the exact instance ID
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match "VEN_xxxx&DEV_yyyy" } |
    Select-Object InstanceId, Status

# 2. Baseline read (device running) -- see section 3

# 3. Disable it and read again
Disable-PnpDevice -InstanceId "<instance id>" -Confirm:$false
Start-Sleep -Milliseconds 500
Get-PnpDevice -InstanceId "<instance id>" | Select-Object Status, ProblemCode
# ... re-run the !dd read from section 3 ...

# 4. Re-enable it and read again
Enable-PnpDevice -InstanceId "<instance id>" -Confirm:$false
Start-Sleep -Milliseconds 1000
Get-PnpDevice -InstanceId "<instance id>" | Select-Object Status, ProblemCode
# ... re-run the !dd read from section 3 ...
```

**Note:** `Enable-PnpDevice` can fail with "device is not connected" if the
underlying PCI function was actually removed from the bus (common for PCIe
root ports). If that happens, follow up with:

```powershell
pnputil /scan-devices
```

to force a bus rescan, then re-check `Get-PnpDevice`.

A pin whose IN/OUT value changes between the "disabled" and "enabled"
reads, in a direction that correlates with the device's `Status`, is
empirically confirmed as that device's control signal (PERST#, CLKREQ#,
power-enable, etc.) — not just a guess based on reference-board pin
numbering.

## 5. Confirm which kernel driver owns the GPIO hardware

```powershell
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match "qcgpio|qcpmic" } |
    Select-Object Name, State, StartMode
```

`qcgpio` owns the TLMM GPIOs read in section 3; `qcpmic` owns PMIC-side
GPIOs (a separate register space, not covered here).

## 6. Decompile the ACPI DSDT that `collect-hwinfo.ps1` already saved

`collect-hwinfo.ps1` dumps raw ACPI tables as `.dat` files under
`hwinfo/acpi/registry/` and `hwinfo/acpi/firmware-api/`. These are AML
bytecode blobs, not human-readable. On a Linux machine:

```bash
sudo apt install acpica-tools   # or your distro's equivalent

iasl -d DSDT-0.dat
# produces dsdt.dsl -- human-readable ASL source
```

Then search it for:
- Specific device HIDs (e.g. `grep -n 'Device (WWAN)' dsdt.dsl`)
- GPIO pin numbers referenced by ACPI methods (`GpioIo`/`GpioInt` resource
  templates list pin numbers in hex)
- Debug strings embedded by the vendor (e.g. `grep -n 'Debug = ' dsdt.dsl`
  often reveals plain-English hints like `"SOC EM GPIO 221"` that directly
  name a GPIO's purpose)
- `PowerResource`/`_PS0`/`_PS3`/`_CRS` blocks to check whether ACPI exposes
  any regulator/rail sequencing for a device (frequently these are empty
  stubs, proving the real sequencing lives in opaque firmware, not AML)

This is how a WWAN modem's sideband control signals and their exact
PMIC/TLMM pin numbers can be found — spelled out in named ACPI
`Field`/`OperationRegion` declarations, not guessed.

## Optional: the `gpiokd.dll` WinDbg extension

`gpiokd.dll` is a WinDbg extension with GPIO-aware commands
(`!gpiokd.gpioext`, `!gpiokd.bankinfo`, `!gpiokd.pintable`,
`!gpiokd.pininfo`, `!gpiokd.clientlist`, `!gpiokd.pinisrvec`). In testing,
`!gpiokd.clientlist` failed with missing `msgpioclx!GpioHubList` symbols —
not fatal, since the direct physical memory reads in section 3 work without
it and don't require this extension at all.
