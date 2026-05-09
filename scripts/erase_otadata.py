"""
PlatformIO post-upload hook: reset the otadata partition.

After `pio run -t upload` writes app0 directly, the otadata partition
may still reference an old boot state. This confuses the ESP-IDF OTA
bootloader: esp_ota_set_boot_partition() refuses to activate a newly
downloaded image with "Could Not Activate The Firmware".

Writing the default boot_app0.bin (all 0xFF) resets otadata so the
bootloader falls back to the first OTA slot (app0), which is the
partition we just flashed.
"""

Import("env")

def reset_otadata(source, target, env):
    """Write default otadata after upload so OTA works cleanly."""
    import subprocess
    import shutil
    import os

    port = env.subst("$UPLOAD_PORT")
    port_args = ["--port", port] if port else []

    # Find boot_app0.bin — the default otadata image shipped with
    # the Arduino-ESP32 framework. It's 8 KiB of 0xFF which tells
    # the bootloader "no OTA state, boot from ota_0".
    framework_dir = env.PioPlatform().get_package_dir("framework-arduinoespressif32")
    boot_app0 = os.path.join(framework_dir, "tools", "partitions", "boot_app0.bin") if framework_dir else None

    if not boot_app0 or not os.path.isfile(boot_app0):
        print("  WARNING: boot_app0.bin not found, skipping otadata reset")
        return

    esptool = shutil.which("esptool.py") or shutil.which("esptool")
    if not esptool:
        pkg_dir = env.PioPlatform().get_package_dir("tool-esptoolpy")
        if pkg_dir:
            candidate = os.path.join(pkg_dir, "esptool.py")
            if os.path.isfile(candidate):
                esptool = candidate

    if not esptool:
        print("  WARNING: esptool not found, skipping otadata reset")
        return

    cmd = [esptool, "--chip", "esp32s3"] + port_args + [
        "write_flash", "0xe000", boot_app0,
    ]

    print("Resetting otadata partition...")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            print("  otadata reset OK")
        else:
            print(f"  WARNING: otadata reset failed: {result.stderr.strip()}")
    except Exception as e:
        print(f"  WARNING: otadata reset skipped: {e}")

env.AddPostAction("upload", reset_otadata)
