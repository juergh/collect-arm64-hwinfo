<#
.SYNOPSIS
    Hardware and ACPI data collector for Linux enablement.
    Collects raw hardware inventory, display EDID and raw ACPI tables without
    installing third-party software.

.DESCRIPTION
    Extracts raw hardware identification data required to build and verify
    Linux support (especially Devicetree models on ARM platforms and drivers):
      - System and processor identity from SMBIOS/CIM
      - Present Plug-and-Play hardware IDs, compatible IDs and active driver info
      - PCI topology and raw location paths
      - Display EDID from the Windows registry
      - Safe battery parameters and raw capacities
      - Raw ACPI tables from both the registry cache and the firmware API

    The archive contains a structured inventory.json and raw binary files
    (EDID and ACPI tables). Interpretation, decoding and formatting are left
    to parse-hwinfo.

.NOTES
    Must be run from an elevated (Administrator) PowerShell session.

.PARAMETER OutputDir
    Directory where output files and the final zip archive will be stored.
    Defaults to the current working directory.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\collect-hwinfo.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDir = (Get-Location).Path
)

$ErrorActionPreference = "Continue"

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "              Hardware & ACPI Data Collector for Linux Enablement               " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 0. Administrator Check
# -----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host @"

[ERROR] This script must be run as Administrator.

Without administrator rights Windows denies access to the hardware management
interfaces (WMI/CIM) this script reads: system/BIOS identity, Plug and Play
hardware IDs, display EDID and battery data. Running anyway would produce an
archive missing critical enablement data.

The script only READS hardware information and writes files into the output
directory. It does not change system settings or install anything. You can read
the full script before running it.

To fix this, right-click PowerShell (or Terminal), choose "Run as
administrator", then re-run:
    powershell.exe -ExecutionPolicy Bypass -File .\collect-hwinfo.ps1

No files were written.

"@ -ForegroundColor Red
    exit 1
}

# -----------------------------------------------------------------------------
# 1. Data Collection Manifest & Mandatory Consent Prompt
# -----------------------------------------------------------------------------
Write-Host @"
DATA COLLECTION DISCLOSURE:

This script will collect and save the following to a local directory:
  [+] System manufacturer, model, family, SKU, chassis type, board identity,
      processor name, core count, and BIOS vendor/version information
  [+] Present PnP hardware IDs, compatible IDs, and active driver names
  [+] PCI topology: bus numbers, device addresses, location paths
  [+] Display EDID: raw binary blocks from the registry (unmodified, so it
      may contain the monitor's serial number)
  [+] Battery model, manufacturer, chemistry, and raw capacity parameters
  [+] Raw ACPI tables from both the registry cache and the firmware API

This script explicitly DOES NOT collect:
  [-] Computer / host name
  [-] BIOS / motherboard / battery / system serial numbers or UUIDs
  [-] Attached USB devices, storage volumes, and paired Bluetooth devices
      (classified via Windows removal policy; best effort)
  [-] Windows product key / activation tables (MSDM and SLIC are excluded)
  [-] Usernames, passwords, network credentials, or personal files
"@ -ForegroundColor White

Write-Host "Target output directory: $OutputDir" -ForegroundColor Gray
Write-Host ""
$consent = Read-Host "Do you consent to collecting this data and saving it locally? [y/N]"
if ($consent -notmatch '^(y|yes)$') {
    Write-Host "`nCollection aborted by user. No files were written to disk.`n" -ForegroundColor Yellow
    exit 0
}

Write-Host "`nStarting data collection...`n" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Setup Output Directory (Named by Model, NOT Hostname)
# -----------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$isoTimestamp = (Get-Date).ToString("o")

$sysInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$mfgSanitized = if ($sysInfo -and $sysInfo.Manufacturer) { ($sysInfo.Manufacturer -replace '[^\w\-]', '_').Trim('_') } else { "UnknownMfg" }
$modelSanitized = if ($sysInfo -and $sysInfo.Model) { ($sysInfo.Model -replace '[^\w\-]', '_').Trim('_') } else { "UnknownModel" }
if ([string]::IsNullOrWhiteSpace($mfgSanitized)) { $mfgSanitized = "UnknownMfg" }
if ([string]::IsNullOrWhiteSpace($modelSanitized)) { $modelSanitized = "UnknownModel" }

$dumpFolderName = "hwinfo-${mfgSanitized}-${modelSanitized}-${timestamp}"
$targetDir = Join-Path -Path $OutputDir -ChildPath $dumpFolderName
$edidDir = Join-Path -Path $targetDir -ChildPath "edid"
$acpiRegDir = Join-Path -Path $targetDir -ChildPath "acpi\registry"
$acpiApiDir = Join-Path -Path $targetDir -ChildPath "acpi\firmware-api"

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
New-Item -ItemType Directory -Path $edidDir -Force | Out-Null
New-Item -ItemType Directory -Path $acpiRegDir -Force | Out-Null
New-Item -ItemType Directory -Path $acpiApiDir -Force | Out-Null

function Get-SafeCimRecord([string]$Namespace, [string]$ClassName, [string[]]$AllowList) {
    try {
        $instances = if ($Namespace) {
            @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
        } else {
            @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
        }
        $records = @()
        foreach ($inst in $instances) {
            $record = [ordered]@{}
            foreach ($prop in $AllowList) {
                $val = $inst.$prop
                # Convert CIM datetime or other non-serializable objects cleanly
                if ($val -is [System.Array]) {
                    $record[$prop] = @($val)
                } else {
                    $record[$prop] = $val
                }
            }
            $records += [pscustomobject]$record
        }
        return [ordered]@{ status = "ok"; records = $records }
    } catch {
        return [ordered]@{ status = "query-failed"; error = $_.Exception.Message; records = @() }
    }
}

# -----------------------------------------------------------------------------
# 3. System & BIOS Information (Safe Allowlist)
# -----------------------------------------------------------------------------
Write-Host "[1/4] Collecting System and BIOS Information..." -ForegroundColor Green

$inventory = [ordered]@{
    schema_version = 1
    capture = [ordered]@{
        timestamp = $isoTimestamp
        collector = "collect-hwinfo.ps1"
    }
    privacy = [ordered]@{
        hostname_collected = $false
        system_serials_collected = $false
        battery_serials_collected = $false
        attached_devices_included = $false
        raw_edid_may_contain_monitor_serial = $true
        usb_classification = "Windows removal policy (ExpectNoRemoval kept; attachable/unknown excluded; best effort)"
        excluded_acpi_signatures = @("MSDM", "SLIC")
    }
    sources = [ordered]@{
        "root/cimv2" = [ordered]@{
            "Win32_ComputerSystem" = Get-SafeCimRecord -Namespace "" -ClassName "Win32_ComputerSystem" -AllowList @(
                "Manufacturer", "Model", "SystemFamily", "TotalPhysicalMemory"
            )
            "Win32_ComputerSystemProduct" = Get-SafeCimRecord -Namespace "" -ClassName "Win32_ComputerSystemProduct" -AllowList @(
                "Version", "SKUNumber"
            )
            "Win32_BaseBoard" = Get-SafeCimRecord -Namespace "" -ClassName "Win32_BaseBoard" -AllowList @(
                "Manufacturer", "Product", "Version"
            )
            "Win32_SystemEnclosure" = Get-SafeCimRecord -Namespace "" -ClassName "Win32_SystemEnclosure" -AllowList @(
                "ChassisTypes"
            )
            "Win32_Processor" = Get-SafeCimRecord -Namespace "" -ClassName "Win32_Processor" -AllowList @(
                "Name", "NumberOfCores", "NumberOfLogicalProcessors", "MaxClockSpeed"
            )
            "Win32_BIOS" = Get-SafeCimRecord -Namespace "" -ClassName "Win32_BIOS" -AllowList @(
                "Manufacturer", "SMBIOSBIOSVersion", "SystemBiosMajorVersion", "SystemBiosMinorVersion", "ReleaseDate"
            )
        }
        "root/wmi" = [ordered]@{}
        "pnp" = [ordered]@{}
    }
    artifacts = [ordered]@{
        edid = @()
        acpi = @()
    }
}

# -----------------------------------------------------------------------------
# 4. Plug-and-Play Inventory (Present Hardware Only; Attached Excluded)
# -----------------------------------------------------------------------------
Write-Host "[2/4] Querying Present Plug-and-Play Hardware & Drivers..." -ForegroundColor Green

# Attached devices carry external serial numbers / MACs. We consider only currently
# present devices. For USB, only keep devices whose physical root parent has removal
# policy 1 (ExpectNoRemoval). Removable (2/3) or unknown policy devices are excluded.
$presentPnp = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)

# Identify USB physical parents (non-interface) that are removable or unknown
$excludedUsbVidPids = @($presentPnp |
    Where-Object { $_.InstanceId -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\' -and $_.InstanceId -notmatch '&MI_' } |
    Where-Object {
        $pol = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName "DEVPKEY_Device_RemovalPolicy" -ErrorAction SilentlyContinue).Data
        $pol -ne 1
    } |
    ForEach-Object { $_.InstanceId -replace '^USB\\(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})\\.*', '$1' } |
    Select-Object -Unique)

function Test-IsAttachedDevice([string]$id) {
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }
    if ($id -match '^(STORAGE\\|USBSTOR\\|BTHENUM\\DEV_|BTHLE\\DEV_)') { return $true }
    foreach ($vidPid in $excludedUsbVidPids) {
        if ($id -like "*$vidPid*") { return $true }
    }
    return $false
}

$filteredPnp = @($presentPnp | Where-Object { -not (Test-IsAttachedDevice $_.InstanceId) })
$keptInstanceIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dev in $filteredPnp) { [void]$keptInstanceIds.Add($dev.InstanceId) }

# pnp.devices: lightweight present device list
$pnpDevicesRecords = @()
foreach ($d in $filteredPnp) {
    $pnpDevicesRecords += [pscustomobject][ordered]@{
        InstanceId   = $d.InstanceId
        Class        = $d.Class
        FriendlyName = $d.FriendlyName
        Status       = $d.Status
    }
}
$inventory.sources.pnp["devices"] = [ordered]@{ status = "ok"; records = $pnpDevicesRecords }

# pnp.entities: detailed hardware IDs from Win32_PnPEntity (present & kept only)
try {
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.HardwareID -ne $null -and $keptInstanceIds.Contains($_.DeviceID) })
    $entityRecords = @()
    foreach ($e in $entities) {
        $entityRecords += [pscustomobject][ordered]@{
            Caption       = $e.Caption
            PNPClass      = $e.PNPClass
            DeviceID      = $e.DeviceID
            HardwareID    = @($e.HardwareID)
            CompatibleID  = if ($e.CompatibleID) { @($e.CompatibleID) } else { @() }
            Status        = $e.Status
        }
    }
    $inventory.sources.pnp["entities"] = [ordered]@{ status = "ok"; records = $entityRecords }
} catch {
    $inventory.sources.pnp["entities"] = [ordered]@{ status = "query-failed"; error = $_.Exception.Message; records = @() }
}

# pnp.drivers: active signed drivers for kept devices
try {
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { $_.DeviceName -ne $null -and $keptInstanceIds.Contains($_.DeviceID) })
    $driverRecords = @()
    foreach ($dr in $drivers) {
        $driverRecords += [pscustomobject][ordered]@{
            DeviceClass   = $dr.DeviceClass
            DeviceName    = $dr.DeviceName
            DeviceID      = $dr.DeviceID
            DriverVersion = $dr.DriverVersion
            InfName       = $dr.InfName
            Manufacturer  = $dr.Manufacturer
            HardwareID    = $dr.HardwareID
        }
    }
    $inventory.sources.pnp["drivers"] = [ordered]@{ status = "ok"; records = $driverRecords }
} catch {
    $inventory.sources.pnp["drivers"] = [ordered]@{ status = "query-failed"; error = $_.Exception.Message; records = @() }
}

# pnp.pci_properties: PCI location paths, bus numbers, raw device addresses
$pciRecords = @()
foreach ($d in ($filteredPnp | Where-Object { $_.InstanceId -like "PCI\*" })) {
    $instId = $d.InstanceId
    $locPaths = (Get-PnpDeviceProperty -InstanceId $instId -KeyName "DEVPKEY_Device_LocationPaths" -ErrorAction SilentlyContinue).Data
    $locInfo  = (Get-PnpDeviceProperty -InstanceId $instId -KeyName "DEVPKEY_Device_LocationInfo" -ErrorAction SilentlyContinue).Data
    $busNum   = (Get-PnpDeviceProperty -InstanceId $instId -KeyName "DEVPKEY_Device_BusNumber" -ErrorAction SilentlyContinue).Data
    $devAddr  = (Get-PnpDeviceProperty -InstanceId $instId -KeyName "DEVPKEY_Device_Address" -ErrorAction SilentlyContinue).Data

    $pciRecords += [pscustomobject][ordered]@{
        InstanceId                  = $instId
        DEVPKEY_Device_LocationPaths = if ($locPaths) { @($locPaths) } else { @() }
        DEVPKEY_Device_LocationInfo  = $locInfo
        DEVPKEY_Device_BusNumber     = $busNum
        DEVPKEY_Device_Address       = $devAddr
    }
}
$inventory.sources.pnp["pci_properties"] = [ordered]@{ status = "ok"; records = $pciRecords }

# -----------------------------------------------------------------------------
# 5. Display & Battery Information (Safe Raw Values)
# -----------------------------------------------------------------------------
Write-Host "[3/4] Querying Display EDID & Battery Parameters..." -ForegroundColor Green

# 5a. Monitors & Raw EDID binaries
$monitorQuery = Get-SafeCimRecord -Namespace "root\wmi" -ClassName "WmiMonitorID" -AllowList @(
    "Active", "InstanceName", "ManufacturerName", "ProductCodeID", "UserFriendlyName"
)
$inventory.sources["root/wmi"]["WmiMonitorID"] = $monitorQuery

# Key registry EDID blocks by DISPLAY\<HardwareId>\<InstanceId>
$regEdids = @{}
Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY" -ErrorAction SilentlyContinue | ForEach-Object {
    $hwId = $_.PSChildName
    Get-ChildItem -Path $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $e = (Get-ItemProperty -Path "$($_.PSPath)\Device Parameters" -Name "EDID" -ErrorAction SilentlyContinue).EDID
        if ($e -is [byte[]] -and $e.Length -ge 128) {
            $regEdids[("DISPLAY\$hwId\$($_.PSChildName)").ToUpper()] = $e
        }
    }
}

$edidArtifacts = @()
$edidIdx = 0
foreach ($mon in $monitorQuery.records) {
    if (-not $mon.InstanceName) { continue }
    $cleanInst = ($mon.InstanceName -replace '_\d+$', '').ToUpper()
    $rawBytes = $regEdids[$cleanInst]
    if ($rawBytes) {
        $binName = "edid-${edidIdx}.bin"
        $binPath = Join-Path -Path $edidDir -ChildPath $binName
        [System.IO.File]::WriteAllBytes($binPath, $rawBytes)

        $edidArtifacts += [pscustomobject][ordered]@{
            path                 = "edid/$binName"
            wmi_instance_name    = $mon.InstanceName
            registry_instance_id = $cleanInst
            source               = "registry"
            length_bytes         = $rawBytes.Length
        }
        $edidIdx++
    }
}
$inventory.artifacts.edid = $edidArtifacts

# 5b. Safe Battery Records (root/cimv2 and root/wmi)
# Explicitly OMIT SerialNumber, UniqueID, and DeviceID which contain hardware serials.
$inventory.sources["root/cimv2"]["Win32_Battery"] = Get-SafeCimRecord -Namespace "" -ClassName "Win32_Battery" -AllowList @(
    "Name", "Status", "Availability", "BatteryStatus", "Chemistry", "DesignCapacity", "FullChargeCapacity", "DesignVoltage"
)
$inventory.sources["root/cimv2"]["Win32_PortableBattery"] = Get-SafeCimRecord -Namespace "" -ClassName "Win32_PortableBattery" -AllowList @(
    "Manufacturer", "Chemistry", "DesignCapacity", "DesignVoltage", "Location"
)
$inventory.sources["root/wmi"]["BatteryStaticData"] = Get-SafeCimRecord -Namespace "root\wmi" -ClassName "BatteryStaticData" -AllowList @(
    "InstanceName", "Active", "Chemistry", "DesignedCapacity", "DeviceName", "ManufactureName", "Technology", "Capabilities"
)
$inventory.sources["root/wmi"]["BatteryFullChargedCapacity"] = Get-SafeCimRecord -Namespace "root\wmi" -ClassName "BatteryFullChargedCapacity" -AllowList @(
    "InstanceName", "Active", "FullChargedCapacity", "Tag"
)
$inventory.sources["root/wmi"]["BatteryStatus"] = Get-SafeCimRecord -Namespace "root\wmi" -ClassName "BatteryStatus" -AllowList @(
    "InstanceName", "Active", "Charging", "Discharging", "Critical", "PowerOnline", "RemainingCapacity", "Voltage", "Tag"
)
$inventory.sources["root/wmi"]["BatteryCycleCount"] = Get-SafeCimRecord -Namespace "root\wmi" -ClassName "BatteryCycleCount" -AllowList @(
    "InstanceName", "Active", "CycleCount", "Tag"
)

# -----------------------------------------------------------------------------
# 6. Raw ACPI Tables (Registry Cache and Firmware API Separated)
# -----------------------------------------------------------------------------
Write-Host "[4/4] Extracting ACPI Tables (excluding license tables)..." -ForegroundColor Green

$excludedTables = @("MSDM", "SLIC")
$acpiArtifacts = @()

function Get-AcpiSignature([byte[]]$bytes) {
    if (-not $bytes -or $bytes.Length -lt 4) { return $null }
    $sig = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($sig -match '^[A-Z0-9_]{4}$') { return $sig }
    return $null
}

# 6a. Registry cache (acpi/registry/)
$acpiRegPath = "HKLM:\HARDWARE\ACPI"
$regSigCounts = @{}
if (Test-Path $acpiRegPath) {
    Get-ChildItem -Path $acpiRegPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $regKeyPath = $_.PSPath
        $props = Get-ItemProperty -Path $regKeyPath -ErrorAction SilentlyContinue
        if (-not $props) { return }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match '^PS') { continue }
            if ($p.Value -is [byte[]] -and $p.Value.Length -ge 36) {
                $sig = Get-AcpiSignature $p.Value
                if (-not $sig -or $excludedTables -contains $sig) { continue }

                $idx = if ($regSigCounts.ContainsKey($sig)) { $regSigCounts[$sig] } else { 0 }
                $regSigCounts[$sig] = $idx + 1
                $fileName = "${sig}-${idx}.dat"
                $outFilePath = Join-Path -Path $acpiRegDir -ChildPath $fileName
                [System.IO.File]::WriteAllBytes($outFilePath, $p.Value)

                $acpiArtifacts += [pscustomobject][ordered]@{
                    path          = "acpi/registry/$fileName"
                    source        = "registry"
                    signature     = $sig
                    index         = $idx
                    length_bytes  = $p.Value.Length
                    registry_path = ($regKeyPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
                }
            }
        }
    }
}

# 6b. Firmware API (acpi/firmware-api/)
if (-not ("NativeAcpiDumper" -as [type])) {
    $csharpCode = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class NativeAcpiDumper {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint EnumSystemFirmwareTables(uint FirmwareTableProviderSignature, IntPtr pFirmwareTableEnumBuffer, uint BufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetSystemFirmwareTable(uint FirmwareTableProviderSignature, uint FirmwareTableID, IntPtr pFirmwareTableBuffer, uint BufferSize);

    public const uint ACPI = 0x41435049;

    public class TableRecord {
        public string Name;
        public byte[] Bytes;
    }

    public static List<TableRecord> ReadAll() {
        List<TableRecord> result = new List<TableRecord>();
        uint size = EnumSystemFirmwareTables(ACPI, IntPtr.Zero, 0);
        if (size == 0) return result;

        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try {
            EnumSystemFirmwareTables(ACPI, buffer, size);
            int count = (int)(size / 4);
            for (int i = 0; i < count; i++) {
                uint tableId = (uint)Marshal.ReadInt32(buffer, i * 4);
                string name = new string(new char[] {
                    (char)(tableId & 0xFF), (char)((tableId >> 8) & 0xFF),
                    (char)((tableId >> 16) & 0xFF), (char)((tableId >> 24) & 0xFF) });

                if (name == "MSDM" || name == "SLIC") continue;

                uint tableSize = GetSystemFirmwareTable(ACPI, tableId, IntPtr.Zero, 0);
                if (tableSize == 0) continue;
                IntPtr tableBuf = Marshal.AllocHGlobal((int)tableSize);
                try {
                    uint got = GetSystemFirmwareTable(ACPI, tableId, tableBuf, tableSize);
                    if (got == 0) continue;
                    byte[] bytes = new byte[got];
                    Marshal.Copy(tableBuf, bytes, 0, (int)got);
                    result.Add(new TableRecord { Name = name, Bytes = bytes });
                } finally {
                    Marshal.FreeHGlobal(tableBuf);
                }
            }
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
        return result;
    }
}
"@
    try { Add-Type -TypeDefinition $csharpCode -Language CSharp } catch {
        Write-Warning "Failed to compile native C# firmware API dumper: $($_.Exception.Message)"
    }
}

$apiSigCounts = @{}
if ("NativeAcpiDumper" -as [type]) {
    try {
        foreach ($rec in [NativeAcpiDumper]::ReadAll()) {
            $sig = Get-AcpiSignature $rec.Bytes
            if (-not $sig) { $sig = $rec.Name }
            if ($excludedTables -contains $sig) { continue }

            $idx = if ($apiSigCounts.ContainsKey($sig)) { $apiSigCounts[$sig] } else { 0 }
            $apiSigCounts[$sig] = $idx + 1
            $fileName = "${sig}-${idx}.dat"
            $outFilePath = Join-Path -Path $acpiApiDir -ChildPath $fileName
            [System.IO.File]::WriteAllBytes($outFilePath, $rec.Bytes)

            $acpiArtifacts += [pscustomobject][ordered]@{
                path         = "acpi/firmware-api/$fileName"
                source       = "firmware-api"
                signature    = $sig
                index        = $idx
                length_bytes = $rec.Bytes.Length
            }
        }
    } catch {
        Write-Warning "Firmware API dump failed: $($_.Exception.Message)"
    }
}

$inventory.artifacts.acpi = $acpiArtifacts
$regCount = ($acpiArtifacts | Where-Object { $_.source -eq "registry" }).Count
$apiCount = ($acpiArtifacts | Where-Object { $_.source -eq "firmware-api" }).Count
Write-Host "  Saved $regCount registry ACPI table(s) and $apiCount firmware-API table(s)." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 7. Write inventory.json & Create Zip Archive
# -----------------------------------------------------------------------------
$inventoryJsonPath = Join-Path -Path $targetDir -ChildPath "inventory.json"
$inventory | ConvertTo-Json -Depth 10 | Set-Content -Path $inventoryJsonPath -Encoding UTF8

$zipOutFile = Join-Path -Path $OutputDir -ChildPath "${dumpFolderName}.zip"
Write-Host "Creating archive: $zipOutFile..." -ForegroundColor Cyan

try {
    Compress-Archive -Path "$targetDir\*" -DestinationPath $zipOutFile -Force
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "  EXTRACTION COMPLETE!" -ForegroundColor Green
    Write-Host "  Zip Archive : $zipOutFile" -ForegroundColor Green
    Write-Host "  Folder      : $targetDir" -ForegroundColor Green
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "Tip: Review inventory.json inside before sharing externally." -ForegroundColor Cyan
} catch {
    Write-Warning "Could not create zip archive: $($_.Exception.Message)"
}
