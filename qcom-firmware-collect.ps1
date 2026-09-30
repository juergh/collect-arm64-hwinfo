<#
.SYNOPSIS
    Qualcomm Snapdragon X Firmware Harvesting Script for Linux Enablement.
    Collects proprietary DSP, GPU, video, Wi-Fi, and Bluetooth firmware binaries
    from the Windows DriverStore for local personal use on Linux.

.DESCRIPTION
    This script extracts the vendor firmware required to boot and run Linux on
    Qualcomm Snapdragon X (X1E / X1P) platforms:
      - Audio DSP (ADSP): qcadsp8380.mbn, adsp_dtbs.elf, JSON config files
      - Compute DSP (CDSP): qccdsp8380.mbn, cdsp_dtbs.elf
      - GPU Zap Shader: qcdxkmsuc8380.mbn, qcdxkmsucpurwa.mbn, a780_zap.mbn
      - Video Decoder (Iris / VSS): qcvss8380.mbn
      - Wi-Fi 6E / 7: board-2.bin, qcvid*.bin, bdf*.bin
      - Bluetooth (btqca): rampatch_*.bin, nvm_*.bin, BTFW.mbn

    LEGAL NOTICE & REDISTRIBUTION WARNING:
    The files collected by this script are proprietary intellectual property
    owned by Qualcomm Technologies, Inc. and your device manufacturer.
    They are harvested STRICTLY FOR PERSONAL USE to enable Linux hardware
    support on this specific device. DO NOT redistribute, upload, or share
    the resulting archive publicly.

.PARAMETER OutputDir
    Directory where the output folder and zip archive will be saved.
    Defaults to the current working directory.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\qcom-firmware-collect.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDir = (Get-Location).Path
)

$ErrorActionPreference = "Continue"

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "              Qualcomm Snapdragon X Firmware Collector for Linux                " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. Legal Warning & Consent Gate
# -----------------------------------------------------------------------------
Write-Host @"

********************************************************************************
                         LEGAL & REDISTRIBUTION WARNING
********************************************************************************
The firmware binaries that will be collected by this script are proprietary
intellectual property of Qualcomm Technologies, Inc. and your hardware vendor.

- These binaries are licensed for use on THIS SPECIFIC MACHINE.
- They are collected SOLELY FOR YOUR PERSONAL USE to run Linux on this hardware.
- DO NOT redistribute, mirror, publish, or upload the resulting archive.
- Unauthorized redistribution may violate vendor copyright and license terms.
********************************************************************************

"@ -ForegroundColor Yellow

$consent = Read-Host "Do you acknowledge this notice and consent to collecting firmware for personal use? [y/N]"
if ($consent -notmatch '^(y|yes)$') {
    Write-Host "`nCollection aborted by user. No files were written to disk.`n" -ForegroundColor Yellow
    exit 0
}

Write-Host "`nInitializing firmware search...`n" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. System Identification & Directory Setup
# -----------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$sysInfo = Get-CimInstance -ClassName Win32_ComputerSystem
$mfgSanitized = ($sysInfo.Manufacturer -replace '[^\w\-]', '_').Trim('_')
$modelSanitized = ($sysInfo.Model -replace '[^\w\-]', '_').Trim('_')
if ([string]::IsNullOrWhiteSpace($mfgSanitized)) { $mfgSanitized = "UnknownMfg" }
if ([string]::IsNullOrWhiteSpace($modelSanitized)) { $modelSanitized = "UnknownModel" }

$baseArchiveName = "qcom-firmware-${mfgSanitized}-${modelSanitized}-${timestamp}"
$targetDir = Join-Path -Path $OutputDir -ChildPath $baseArchiveName
$fwRoot = Join-Path -Path $targetDir -ChildPath "qcom-firmware"

New-Item -ItemType Directory -Path $fwRoot -Force | Out-Null

$driverStorePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\DriverStore\FileRepository"
if (-not (Test-Path $driverStorePath)) {
    Write-Host "[ERROR] Windows DriverStore not found at: $driverStorePath" -ForegroundColor Red
    exit 1
}

Write-Host "Searching DriverStore: $driverStorePath" -ForegroundColor Gray
Write-Host "Output Directory      : $targetDir`n" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# 3. Harvest Definitions & Active Wi-Fi Discovery
# -----------------------------------------------------------------------------
# Query active Qualcomm Wi-Fi adapter settings from the registry to target the
# exact board calibration file and firmware image selected for this machine.
$activeWifiInfo = @()
$netClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
if (Test-Path $netClassPath) {
    Get-ChildItem -Path $netClassPath -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($props -and ($props.DriverDesc -match 'Qualcomm|FastConnect|Wi-Fi|WLAN' -or $props.BDFileName)) {
            # Extract PCI IDs from MatchingDeviceId or DeviceInstanceID if present
            $pciMatch = [regex]::Match($props.MatchingDeviceId, 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})(?:&SUBSYS_([0-9A-Fa-f]{4})([0-9A-Fa-f]{4}))?')
            $pciIds = if ($pciMatch.Success) {
                [pscustomobject][ordered]@{
                    vendor_id           = "0x$($pciMatch.Groups[1].Value.ToLower())"
                    device_id           = "0x$($pciMatch.Groups[2].Value.ToLower())"
                    subsystem_vendor_id = if ($pciMatch.Groups[4].Success) { "0x$($pciMatch.Groups[4].Value.ToLower())" } else { $null }
                    subsystem_device_id = if ($pciMatch.Groups[3].Success) { "0x$($pciMatch.Groups[3].Value.ToLower())" } else { $null }
                }
            } else { $null }

            $activeWifiInfo += [pscustomobject][ordered]@{
                DriverDesc    = $props.DriverDesc
                InfPath       = $props.InfPath
                InfSection    = $props.InfSection
                BoardDataFile = $props.BDFileName
                FirmwareFile  = $props.FWFileName
                PciIds        = $pciIds
            }
        }
    }
}

# Determine Wi-Fi target files: prioritize the specific active board data file
$wifiTargets = @("board-2.bin", "board*.bin", "m3.bin", "amss.bin")
$activeBoardFiles = @($activeWifiInfo | Where-Object { $_.BoardDataFile } | ForEach-Object { $_.BoardDataFile })
$activeFwFiles    = @($activeWifiInfo | Where-Object { $_.FirmwareFile } | ForEach-Object { $_.FirmwareFile })

if ($activeBoardFiles.Count -gt 0) {
    $wifiTargets += $activeBoardFiles
} else {
    # Fallback to general patterns only if active file name was not discovered
    $wifiTargets += @("bdwlan*.elf", "bdwlan*.e*", "bdf*.bin")
}

if ($activeFwFiles.Count -gt 0) {
    $wifiTargets += $activeFwFiles
    # DriverStore often names the matching file with version suffix, e.g. wlanfw20.mbn
    foreach ($fw in $activeFwFiles) {
        $baseFw = [System.IO.Path]::GetFileNameWithoutExtension($fw)
        $wifiTargets += "${baseFw}*.mbn"
    }
} else {
    $wifiTargets += @("wlanfw*.mbn", "wlanfw*.bin")
}

$harvestRules = @(
    @{
        Subsystem    = "adsp"
        Description  = "Audio DSP Firmware & Config"
        InfPatterns  = @("qcadsp*.inf_*", "qcsubsys*.inf_*")
        TargetFiles  = @("qcadsp*.mbn", "adsp_dtbs.elf", "adspr.jsn", "adsps.jsn", "adspua.jsn", "battmgr.jsn", "adsp*.jsn")
    },
    @{
        Subsystem    = "cdsp"
        Description  = "Compute DSP / NPU Firmware & Config"
        InfPatterns  = @("qccdsp*.inf_*", "qcsubsys*.inf_*")
        TargetFiles  = @("qccdsp*.mbn", "cdsp_dtbs.elf", "cdspr.jsn", "cdsp*.jsn")
    },
    @{
        Subsystem    = "gpu"
        Description  = "Adreno GPU Zap Shader"
        InfPatterns  = @("qcdx*.inf_*", "qcgpu*.inf_*")
        TargetFiles  = @("qcdxkmsuc*.mbn", "*zap*.mbn", "a780_zap.mbn")
    },
    @{
        Subsystem    = "video"
        Description  = "Video Decoder (Iris / VSS)"
        InfPatterns  = @("qcvss*.inf_*")
        TargetFiles  = @("qcvss*.mbn")
    },
    @{
        Subsystem    = "wifi"
        Description  = "Qualcomm Wi-Fi Calibration & Firmware"
        InfPatterns  = @("qcathena*.inf_*", "qcwlan*.inf_*", "qcwcn*.inf_*", "ath*.inf_*")
        TargetFiles  = ($wifiTargets | Select-Object -Unique)
    },
    @{
        Subsystem    = "bluetooth"
        Description  = "Qualcomm Bluetooth Firmware & NVM"
        InfPatterns  = @("qcbthuart*.inf_*", "qcbt*.inf_*", "btqca*.inf_*", "qcbluetooth*.inf_*")
        TargetFiles  = @("*btfw*.tlv", "*btfw*.ver", "*nv*.bin", "*nv*.b*", "bsrc_bt*.bin", "hpnv*.bin", "BTFW.mbn")
    }
)

# -----------------------------------------------------------------------------
# 4. Firmware Harvesting Execution
# -----------------------------------------------------------------------------
$manifestEntries = @()
$totalCollected = 0

foreach ($rule in $harvestRules) {
    $subsystemName = $rule.Subsystem
    $subsystemDir = Join-Path -Path $fwRoot -ChildPath $subsystemName
    New-Item -ItemType Directory -Path $subsystemDir -Force | Out-Null

    Write-Host "[$subsystemName] Harvesting $($rule.Description)..." -ForegroundColor Green

    # Find matching INF directories
    $matchingInfDirs = @()
    foreach ($pattern in $rule.InfPatterns) {
        $matchingInfDirs += Get-ChildItem -Path $driverStorePath -Directory -Filter $pattern -ErrorAction SilentlyContinue
    }

    if ($matchingInfDirs.Count -eq 0) {
        # Fallback: scan all qc*.inf_* directories if specific prefix was not found
        $matchingInfDirs = Get-ChildItem -Path $driverStorePath -Directory -Filter "qc*.inf_*" -ErrorAction SilentlyContinue
    }

    $collectedForSubsystem = 0
    $seenFiles = @{}

    foreach ($filePattern in $rule.TargetFiles) {
        foreach ($infDir in $matchingInfDirs) {
            $matchedFiles = Get-ChildItem -Path $infDir.FullName -File -Filter $filePattern -Recurse -ErrorAction SilentlyContinue
            foreach ($file in $matchedFiles) {
                # If multiple versions exist across INF updates, prefer newest
                if (-not $seenFiles.ContainsKey($file.Name)) {
                    $seenFiles[$file.Name] = $file
                } else {
                    if ($file.LastWriteTime -gt $seenFiles[$file.Name].LastWriteTime) {
                        $seenFiles[$file.Name] = $file
                    }
                }
            }
        }
    }

    # Copy files into subsystem folder and compute SHA256
    foreach ($kv in $seenFiles.GetEnumerator()) {
        $srcFile = $kv.Value
        $destPath = Join-Path -Path $subsystemDir -ChildPath $srcFile.Name
        Copy-Item -Path $srcFile.FullName -Destination $destPath -Force

        $sha256 = (Get-FileHash -Path $destPath -Algorithm SHA256).Hash
        $sizeBytes = $srcFile.Length

        Write-Host "  -> Copied: $($srcFile.Name) ($([math]::Round($sizeBytes / 1KB, 1)) KB)" -ForegroundColor Gray

        $manifestEntries += [pscustomobject][ordered]@{
            Subsystem    = $subsystemName
            FileName     = $srcFile.Name
            RelativePath = "$subsystemName/$($srcFile.Name)"
            SizeBytes    = $sizeBytes
            SHA256       = $sha256
            SourceDir    = $srcFile.Directory.Name
        }

        $collectedForSubsystem++
        $totalCollected++
    }

    if ($collectedForSubsystem -eq 0) {
        Write-Host "  No matching firmware files found for $subsystemName in DriverStore." -ForegroundColor DarkGray
    }
}

# -----------------------------------------------------------------------------
# 5. Generate Manifest File
# -----------------------------------------------------------------------------
$manifestPath = Join-Path -Path $fwRoot -ChildPath "manifest.json"

$subsystemsObj = [ordered]@{}
foreach ($rule in $harvestRules) {
    $subsystemsObj[$rule.Subsystem] = @()
}
foreach ($entry in $manifestEntries) {
    $subsystemsObj[$entry.Subsystem] += [pscustomobject][ordered]@{
        file_name      = $entry.FileName
        relative_path  = $entry.RelativePath
        size_bytes     = $entry.SizeBytes
        sha256         = $entry.SHA256
        source_inf_dir = $entry.SourceDir
    }
}

$manifestData = [ordered]@{
    schema_version        = 1
    archive_type          = "qcom-firmware"
    capture               = [ordered]@{
        timestamp   = (Get-Date).ToString("o")
        collector   = "qcom-firmware-collect.ps1"
        total_files = $totalCollected
    }
    system                = [ordered]@{
        manufacturer = $sysInfo.Manufacturer
        model        = $sysInfo.Model
    }
    active_configurations = [ordered]@{
        wifi = @($activeWifiInfo | ForEach-Object {
            [pscustomobject][ordered]@{
                driver_desc     = $_.DriverDesc
                inf_path        = $_.InfPath
                inf_section     = $_.InfSection
                board_data_file = $_.BoardDataFile
                firmware_file   = $_.FirmwareFile
                pci_ids         = $_.PciIds
                linux_notes     = "Match board_data_file to the hardware OTP qmi-board-id reported in dmesg by ath12k/ath11k"
            }
        })
    }
    subsystems            = $subsystemsObj
}

$manifestData | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "`nManifest written to: $manifestPath" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 6. Compress Output to Zip Archive
# -----------------------------------------------------------------------------
$zipOutFile = Join-Path -Path $OutputDir -ChildPath "${baseArchiveName}.zip"
Write-Host "Creating zip archive: $zipOutFile..." -ForegroundColor Cyan

try {
    Compress-Archive -Path "$targetDir\*" -DestinationPath $zipOutFile -Force
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "  FIRMWARE HARVEST COMPLETE!" -ForegroundColor Green
    Write-Host "  Zip Archive : $zipOutFile" -ForegroundColor Green
    Write-Host "  Folder      : $targetDir" -ForegroundColor Green
    Write-Host "  Total Files : $totalCollected firmware binaries and libraries" -ForegroundColor Green
    Write-Host "================================================================================" -ForegroundColor Green
    Write-Host "Remember: This archive contains proprietary firmware. Do NOT share publicly." -ForegroundColor Yellow
} catch {
    Write-Warning "Could not create zip archive: $($_.Exception.Message)"
}
