"""
PlatformIO post-upload hook: erase the otadata partition.

After `pio run -t upload` writes app0 directly, the otadata partition
may still reference an old boot state. This confuses the ESP-IDF OTA
bootloader: esp_ota_set_boot_partition() refuses to activate a newly
downloaded image with "Could Not Activate The Firmware".

Erasing otadata (0xe000, 8 KiB) forces the bootloader to fall back to
the factory/ota_0 slot, which is the partition we just flashed.
"""

Import("env")

def erase_otadata(source, target, env):
    """Run esptool erase_region on the otadata partition after upload."""
    import subprocess
    import shutil

    port = env.subst("$UPLOAD_PORT")
    if not port:
        port_args = []
    else:
        port_args = ["--port", port]

    # Find esptool: prefer the standalone command, fall back to
    # PlatformIO's platform-packages copy.
    esptool = shutil.which("esptool.py") or shutil.which("esptool")
    if not esptool:
        # PlatformIO bundles esptool inside the platform package
        import os
        pkg_dir = env.PioPlatform().get_package_dir("tool-esptoolpy")
        if pkg_dir:
            candidate = os.path.join(pkg_dir, "esptool.py")
            if os.path.isfile(candidate):
                esptool = candidate

    if not esptool:
        print("  WARNING: esptool not found, skipping otadata erase")
        return

    cmd = [esptool, "--chip", "esp32s3"] + port_args + [
        "erase_region", "0xe000", "0x2000",
    ]

    print("Erasing otadata partition (0xe000, 8 KiB)...")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            print("  otadata erased OK")
        else:
            print(f"  WARNING: otadata erase failed: {result.stderr.strip()}")
    except Exception as e:
        print(f"  WARNING: otadata erase skipped: {e}")

env.AddPostAction("upload", erase_otadata)
