#!/usr/bin/env python3
import ctypes
import glob
import os
import re
import signal
import socket
import sys
import threading
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

VM_NAME = "win11"                          # VM name
SOCK_GLOB = f"/run/libvirt/qemu/channel/*-{VM_NAME}/org.local.gpu-temp"

GPU_PCI_ADDRESS = "0000:01:00.0"           # dGPU PCI address, find out with: lspci -D | grep -i nvidia

OUT_PATH = "/dev/shm/gpu-temp"             # where we write the resulting value

STALE_AFTER = 5.0                          # sec - after this, guest data is considered stale
FALLBACK_TEMP = 50                         # used if neither host nor guest is available

RECONNECT_DELAY = 2.0                      # sec - pause before reconnecting after a real disconnect
SOCK_POLL_DELAY = 3.0                      # sec - pause if the VM socket hasn't appeared yet

# ---------------------------------------------------------------------------
# Shared state (guest thread <-> main thread)
# ---------------------------------------------------------------------------

guest_temp = None
guest_temp_ts = 0.0
lock = threading.Lock()

# ---------------------------------------------------------------------------
# Guest side: reading from the virtio-serial unix socket
# ---------------------------------------------------------------------------

def find_socket() -> str | None:
    matches = glob.glob(SOCK_GLOB)
    return matches[0] if matches else None


def guest_listener() -> None:
    """Runs in the background continuously. Keeps a single connection open
    for as long as needed - absence of data is NOT a reason to reconnect,
    only a real EOF/socket error is."""
    global guest_temp, guest_temp_ts

    while True:
        sock_path = find_socket()
        if sock_path is None:
            time.sleep(SOCK_POLL_DELAY)
            continue

        s = None
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(sock_path)

            buf = b""
            while True:
                data = s.recv(1024)
                if not data:
                    break  # real EOF: guest/VM closed the port

                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    m = re.match(rb"GPU:(\d+)", line)
                    if m:
                        with lock:
                            guest_temp = int(m.group(1))
                            guest_temp_ts = time.time()

        except OSError:
            pass
        finally:
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
            with lock:
                guest_temp = None
            time.sleep(RECONNECT_DELAY)


# ---------------------------------------------------------------------------
# sysfs: who currently owns the GPU (without touching the device itself)
# ---------------------------------------------------------------------------

def gpu_driver_name() -> str | None:
    """Returns the name of the driver the GPU is currently bound to
    ("nvidia", "vfio-pci", ...), or None if it could not be determined.
    This reads a symlink in sysfs - pure kernel metadata, does NOT touch
    the device itself and creates no contention with VFIO/guest."""
    link_path = f"/sys/bus/pci/devices/{GPU_PCI_ADDRESS}/driver"
    try:
        target = os.readlink(link_path)
    except OSError:
        return None
    return os.path.basename(target)


# ---------------------------------------------------------------------------
# Host side: temperature via NVML (ctypes), only when the GPU belongs to the host
# ---------------------------------------------------------------------------

class NvmlBridge:
    NVML_SUCCESS = 0
    NVML_TEMPERATURE_GPU = 0

    def __init__(self, device_index: int = 0):
        self._device_index = device_index
        self._lib = None
        self._device = None
        self._initialized = False

    def ensure_init(self) -> bool:
        """Initializes NVML if not already initialized.
        Call ONLY after gpu_driver_name() has confirmed that
        the device is on the nvidia driver."""
        if self._initialized:
            return True

        if self._lib is None:
            try:
                self._lib = ctypes.CDLL("libnvidia-ml.so.1")
            except OSError:
                return False

        if self._lib.nvmlInit_v2() != self.NVML_SUCCESS:
            return False

        handle = ctypes.c_void_p()
        ret = self._lib.nvmlDeviceGetHandleByIndex_v2(
            ctypes.c_uint(self._device_index), ctypes.byref(handle)
        )
        if ret != self.NVML_SUCCESS:
            self._lib.nvmlShutdown()
            return False

        self._device = handle
        self._initialized = True
        return True

    def release(self) -> None:
        """Explicitly shuts down NVML. Called as soon as we see that
        the device's driver has switched to something other than nvidia -
        so we don't hold a handle during hot-unbind."""
        if self._initialized and self._lib is not None:
            try:
                self._lib.nvmlShutdown()
            except OSError:
                pass
        self._initialized = False
        self._device = None

    def get_temp(self) -> int | None:
        if not self._initialized:
            return None
        temp = ctypes.c_uint()
        ret = self._lib.nvmlDeviceGetTemperature(
            self._device, ctypes.c_int(self.NVML_TEMPERATURE_GPU), ctypes.byref(temp)
        )
        if ret != self.NVML_SUCCESS:
            self._initialized = False
            self._device = None
            return None
        return temp.value


# ---------------------------------------------------------------------------
# Writing the result
# ---------------------------------------------------------------------------

def write_temp(temp_celsius: int) -> None:
    """CoolerControl (like standard sysfs hwmon: tempN_input) expects
    an integer in millidegrees Celsius, e.g. 80000 for 80°C."""
    millidegrees = int(temp_celsius) * 1000
    tmp_path = OUT_PATH + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(str(millidegrees))
    os.replace(tmp_path, OUT_PATH)  # atomic replace

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

nvml = NvmlBridge()


def handle_shutdown_signal(signum, _frame) -> None:
    """SIGTERM/SIGINT (incl. from `systemctl stop`) - release NVML
    before exiting, so we don't interfere with the hook unbinding the GPU from nvidia."""
    print(f"Received signal {signum}, releasing NVML before exit")
    nvml.release()
    sys.exit(0)


def main() -> None:
    signal.signal(signal.SIGTERM, handle_shutdown_signal)
    signal.signal(signal.SIGINT, handle_shutdown_signal)

    threading.Thread(target=guest_listener, daemon=True).start()

    last_source = None

    while True:
        with lock:
            gt, ts = guest_temp, guest_temp_ts

        if gt is not None and (time.time() - ts) < STALE_AFTER:
            source, temp = "guest", gt
            nvml.release()
        else:
            driver = gpu_driver_name()
            if driver == "nvidia" and nvml.ensure_init():
                host_temp = nvml.get_temp()
            else:
                nvml.release()
                host_temp = None

            if host_temp is not None:
                source, temp = "host", host_temp
            else:
                source, temp = "fallback", FALLBACK_TEMP

        write_temp(temp)

        if source != last_source:
            if source == "fallback":
                print(f"!!! WARNING: neither host nor guest GPU temp available, "
                      f"writing fallback value {FALLBACK_TEMP}")
            else:
                print(f"Source switched to: {source} ({temp}°C)")
            last_source = source

        time.sleep(1)


if __name__ == "__main__":
    main()
