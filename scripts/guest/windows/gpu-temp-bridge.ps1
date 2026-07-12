# ---------------------------------------------------------------------------
# Set up PATH so nvml.dll can be found (it's not in System32, but in NVSMI)
# ---------------------------------------------------------------------------

$nvsmiDir = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI"
if (Test-Path $nvsmiDir) {
    $env:PATH = "$nvsmiDir;$env:PATH"
}

# ---------------------------------------------------------------------------
# P/Invoke: virtio-serial (kernel32) + NVML
# ---------------------------------------------------------------------------

if (-not ([System.Management.Automation.PSTypeName]'Vioser').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Vioser {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFile(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(IntPtr handle, byte[] buffer, uint bytesToWrite,
        out uint bytesWritten, IntPtr overlapped);
}

public static class Nvml {
    // NVML on Windows uses cdecl (see pynvml/official NVML headers) -
    // this is the only thing that actually differs from regular Win32 P/Invoke.
    private const string DllName = "nvml.dll";

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlInit_v2();

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlShutdown();

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetTemperature(IntPtr device, int sensorType, out uint temp);
}
"@
}

$GENERIC_READ_WRITE = 3221225472  # 0xC0000000
$OPEN_EXISTING = 3
$portName = "\\.\Global\org.local.gpu-temp"
$VC_DISCONNECTED = 554
$NVML_TEMPERATURE_GPU = 0

# ---------------------------------------------------------------------------
# NVML: initialization with lazy reconnect
# ---------------------------------------------------------------------------

$script:nvmlDevice = [IntPtr]::Zero
$script:nvmlReady = $false

function Initialize-Nvml {
    if ([Nvml]::nvmlInit_v2() -ne 0) { return $false }
    $handle = [IntPtr]::Zero
    if ([Nvml]::nvmlDeviceGetHandleByIndex_v2(0, [ref]$handle) -ne 0) {
        [Nvml]::nvmlShutdown() | Out-Null
        return $false
    }
    $script:nvmlDevice = $handle
    return $true
}

function Get-GpuTemp {
    if (-not $script:nvmlReady) {
        $script:nvmlReady = Initialize-Nvml
        if (-not $script:nvmlReady) { return $null }
    }
    $temp = 0
    $ret = [Nvml]::nvmlDeviceGetTemperature($script:nvmlDevice, $NVML_TEMPERATURE_GPU, [ref]$temp)
    if ($ret -ne 0) {
        $script:nvmlReady = $false
        return $null
    }
    return [int]$temp
}

# ---------------------------------------------------------------------------
# Opening the virtio-serial port
# ---------------------------------------------------------------------------

Write-Host "Opening port: $portName"
$h = [Vioser]::CreateFile($portName, $GENERIC_READ_WRITE, 0,
    [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)

if ($h.ToInt64() -eq -1) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host "Failed to open port, error code: $err"
    exit 1
}
Write-Host "Port opened, handle: $h"

if (-not (Initialize-Nvml)) {
    Write-Host "WARNING: NVML not ready yet, will keep retrying in the background"
} else {
    $script:nvmlReady = $true
}

# ---------------------------------------------------------------------------
# Main loop - log only on state change
# ---------------------------------------------------------------------------

try {
    $lastState = $null

    while ($true) {
        $temp = Get-GpuTemp
        if ($null -eq $temp) {
            if ($lastState -ne "nvml-unavailable") {
                Write-Host "NVML unavailable, retrying..."
                $lastState = "nvml-unavailable"
            }
            Start-Sleep -Milliseconds 1000
            continue
        }

        $line = "GPU:$temp`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($line)
        $written = 0
        $ok = [Vioser]::WriteFile($h, $bytes, $bytes.Length, [ref]$written, [IntPtr]::Zero)

        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $state = if ($err -eq $VC_DISCONNECTED) { "host-disconnected" } else { "write-error-$err" }
        } else {
            $state = "streaming"
        }

        if ($state -ne $lastState) {
            switch -Wildcard ($state) {
                "host-disconnected" { Write-Host "Host not connected yet, waiting..." }
                "streaming"         { Write-Host "Streaming to host (current: $temp C)" }
                "write-error-*"     { Write-Host "Unexpected write error: $state" }
            }
            $lastState = $state
        }

        Start-Sleep -Milliseconds 1000
    }
}
finally {
    [Vioser]::CloseHandle($h) | Out-Null
    if ($script:nvmlReady) {
        [Nvml]::nvmlShutdown() | Out-Null
    }
    Write-Host "Handle closed, NVML shut down"
}
