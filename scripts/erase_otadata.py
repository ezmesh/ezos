"""
PlatformIO pre-upload hook: reset the otadata partition.

Writing the default boot_app0.bin (all 0xFF) before each upload ensures
the OTA bootloader treats the about-to-be-flashed app0 as the active
slot. Without this, esp_ota_set_boot_partition() may refuse to activate
a downloaded OTA image with "Could Not Activate The Firmware" because
otadata still references stale state from a previous OTA cycle.

Runs before the upload so the firmware flash's own hard-reset at the
end is the only reset — no double-reset race that could interrupt boot.
"""

Import("env")

def reset_otadata(source, target, env):
    """Write default otadata before upload so OTA works cleanly."""
    import subprocess
    import shutil
    import os

    port = env.subst("$UPLOAD_PORT")
    port_args = ["--port", port] if port else []

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
        "--after", "no_reset",
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

env.AddPreAction("upload", reset_otadata)
