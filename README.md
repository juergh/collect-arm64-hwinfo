# Hardware Collection and Parsing for Linux Enablement

This directory contains Windows collectors and a Linux parser for bootstrapping support on new laptops, with a particular focus on Qualcomm Snapdragon X (ARM64) platforms:

1. **`collect-hwinfo.ps1`**: Extracts raw system hardware identifiers, PnP device inventory, display EDID, battery parameters, and raw ACPI tables. Collects no host name, system serial numbers or personal data (see Privacy Safeguards), so it is intended to be shared for kernel Devicetree and driver development.
2. **`parse-hwinfo.py`**: Parses a hardware archive on Linux, records facts with source provenance, runs `iasl` and `edid-decode`, and generates an intentionally incomplete Devicetree review template.
3. **`qcom-firmware-collect.ps1`**: Harvests proprietary Qualcomm DSP, GPU, video, Wi-Fi, and Bluetooth firmware binaries from the local Windows DriverStore. **Strictly for personal use** on this specific device (redistribution prohibited).

---

## 1. Hardware & ACPI Collector (`collect-hwinfo.ps1`)

Collects all non-proprietary hardware description data required to write and verify Linux Devicetrees. Requires **zero installations, zero downloads, and zero external software**.

### Quick Start
Run it from an elevated (Administrator) PowerShell:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\collect-hwinfo.ps1
```
An archive named `hwinfo-<Manufacturer>-<Model>-<Timestamp>.zip` is generated.

### Hardware Archive Contents
```text
hwinfo-<Manufacturer>-<Model>-<Timestamp>.zip
├── inventory.json         # Raw structured metadata from CIM/WMI/PnP
├── edid/
│   └── edid-<n>.bin       # Raw unmodified monitor EDID binaries
└── acpi/
    ├── registry/          # ACPI tables from Windows registry cache (includes DSDT)
    │   └── *.dat
    └── firmware-api/      # ACPI tables from Win32 firmware table API
        └── *.dat
```

### Privacy Safeguards
- **Excluded**: Hostname, BIOS/system/battery serial numbers, UUIDs.
- **Skipped devices**: Storage volumes, USB storage, paired Bluetooth devices, and USB devices Windows treats as removable are left out of the PnP inventory, because their instance IDs carry serial numbers and MAC addresses. Internal USB devices such as the camera are kept (classified via Windows removal policy; best effort).
- **Not scrubbed**: The raw EDID is saved unmodified and may contain the monitor's serial number.
- **Excluded License Keys**: `MSDM` (OEM Windows activation keys) and `SLIC` tables are strictly filtered out.
- **Mandatory Consent**: Displays an itemized manifest and halts for explicit `[y/N]` confirmation before saving any files.

---

## 2. Linux Hardware Parser (`parse-hwinfo.py`)

The parser accepts an unmodified `hwinfo-*.zip` archive or an extracted archive directory. It reads `inventory.json`, trims and decodes the EDID using `edid-decode`, reconciles the ACPI tables, and runs `iasl` locally to generate the ASL and hardware map in a temporary staging area. Missing information remains explicit as `TBD` or `FIXME` output.

### Linux Prerequisites

- **Python 3.9 or newer**.
- **`edid-decode`**: Required to extract preferred display timings from `edid/edid-0.bin`.
- **ACPICA `iasl`**: Required to decompile `DSDT.dat` into `.dsl` and `.map`.
- **`pci.ids` and `usb.ids`**: Optional offline databases. Canonical database names are preferred when a device-level match exists; otherwise the parser retains the Windows collector caption.

On Debian or Ubuntu, install the parser tools and ID databases with:
```bash
sudo apt install acpica-tools edid-decode pci.ids usb.ids
```

The parser searches common distribution locations including `/usr/share/hwdata/`, `/usr/share/misc/`, and `/var/lib/usbutils/` for the ID databases.

Install the Python command in an isolated environment with [uv](https://docs.astral.sh/uv/):
```bash
uv tool install .
parse-hwinfo --help
```

### Usage
```bash
# Print the Markdown report (default output)
./parse-hwinfo.py hwinfo-Vendor-Model-Timestamp.zip

# Write all five artifacts to a directory
./parse-hwinfo.py --all output/ hwinfo-Vendor-Model-Timestamp.zip

# Emit one artifact to standard output
./parse-hwinfo.py --json hwinfo-Vendor-Model-Timestamp.zip
./parse-hwinfo.py --missing hwinfo-Vendor-Model-Timestamp.zip
./parse-hwinfo.py --dts hwinfo-Vendor-Model-Timestamp.zip
./parse-hwinfo.py --hwids hwinfo-Vendor-Model-Timestamp.zip

# Write one selected artifact to a file
./parse-hwinfo.py --markdown -o report.md hwinfo-Vendor-Model-Timestamp.zip
```

### Outputs

`--all OUTPUT_DIRECTORY` writes:

| File | Purpose |
|---|---|
| `board-facts.json` | Machine-readable observed and inferred facts with source citations |
| `missing-data.json` | Categorized list of facts that cannot be established from the archive |
| `board.dts.in` | Intentionally non-compiling review template containing `TBD` and `FIXME` placeholders |
| `report.md` | Human-readable facts, synthesized topology, endpoint inventory, and lookup checklist |
| `hwids.txt` | stubble-compatible Computer Hardware IDs with field combination descriptions |

Facts use the following provenance states:

- `observed`: Read directly from an archive artifact or decoded hardware description.
- `runtime-observed`: Reported by the running Windows system, such as an enumerated PCI or USB endpoint.
- `inferred`: Derived from observed identifiers or an external reference database.
- `unknown`: Not established by the available data.

`board.dts.in` is a review aid, not generated production Devicetree source. Every placeholder must be resolved before it can compile or be submitted upstream.

---

## 3. Qualcomm Firmware Collector (`qcom-firmware-collect.ps1`)

Harvests vendor firmware binaries required by the Linux kernel (`/lib/firmware/`) to operate the Audio DSP (ADSP), Compute DSP (CDSP / NPU), Adreno GPU zap shader, video decoder (Iris), Wi-Fi calibration, and Bluetooth.

### Legal Notice & Redistribution Warning
> **IMPORTANT:** Firmware binaries extracted by this script are proprietary intellectual property of Qualcomm Technologies, Inc. and your hardware vendor.
>
> They are harvested **SOLELY FOR YOUR PERSONAL USE** to run Linux on this specific machine.
> **DO NOT redistribute, mirror, publish, or upload the firmware archive.**

### Usage
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\qcom-firmware-collect.ps1
```
The script prompts for acknowledgement of the legal warning, scans `C:\Windows\System32\DriverStore\FileRepository`, and packages matching firmware into:
```text
qcom-firmware-<Manufacturer>-<Model>-<Timestamp>.zip
```

---

## 4. Integration with Linux (`qcom-firmware-extract`)

Debian and Ubuntu provide a package called **`qcom-firmware-extract`** that packages Snapdragon firmware into a `.deb` package and updates `initramfs`.

Because `qcom-firmware-extract` locates files using recursive `find`, it can easily consume the `qcom-firmware/` directory extracted from our zip.

**Manual deployment on Linux:**
```bash
# 1. Transfer the zip to your Linux system and extract it:
unzip qcom-firmware-*.zip -d /tmp/fw-staging

# 2. Point qcom-firmware-extract directly to the extracted folder:
sudo qcom-firmware-extract -d /tmp/fw-staging/qcom-firmware
```

---

## Windows Collector Requirements

- **Operating System**: Windows 10 or Windows 11 (ARM64 recommended for firmware extraction; x86_64 supported for hardware data collection).
- **PowerShell**: 5.1 or newer (pre-installed on Windows 10 and 11).
- **Privileges**: Administrator required for `collect-hwinfo.ps1` (reads CIM/WMI/firmware interfaces).
