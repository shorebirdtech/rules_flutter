"""DXGI Desktop Duplication screenshot for Windows Flutter app verification.

Usage: python dxgi_screenshot.py <app_exe_path> <output_png> [wait_seconds]

Launches the app, waits for it to render, checks that it is still running and
shows a window, captures the desktop via DXGI (which correctly captures
D3D/Flutter surfaces unlike GDI CopyFromScreen), saves the screenshot, and
kills the app. Prints PASS, or FAIL and exits 1: when the app has exited (a
crash at launch), or has no visible top-level window with a non-empty client
area (a runner that never shows the Flutter view).

Requires: pip install dxcam numpy Pillow opencv-python-headless
Must run in an interactive desktop session (PsExec -i <session_id>).
"""

import ctypes
import subprocess
import sys
import time
import os
from ctypes import wintypes

import dxcam
from PIL import Image


_WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def visible_window_of(pid):
    """The first visible top-level window of `pid` with a non-empty client
    area, as (title, width, height), or None.

    EnumWindows lists no message-only windows, which is where the engine
    creates the Flutter view until a runner parents it.
    """
    user32 = ctypes.windll.user32
    found = []

    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value != pid or not user32.IsWindowVisible(hwnd):
            return True
        rect = wintypes.RECT()
        user32.GetClientRect(hwnd, ctypes.byref(rect))
        if rect.right <= 0 or rect.bottom <= 0:
            return True
        title = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(hwnd, title, len(title))
        found.append((title.value, rect.right, rect.bottom))
        return False

    user32.EnumWindows(_WNDENUMPROC(visit), 0)
    return found[0] if found else None


def main():
    if len(sys.argv) < 3:
        print("Usage: python dxgi_screenshot.py <app_exe> <output_png> [wait_seconds]")
        sys.exit(1)

    app_path = sys.argv[1]
    output_path = sys.argv[2]
    wait_seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 10

    app_dir = os.path.dirname(app_path)

    # Launch app
    print(f"Launching: {app_path}")
    proc = subprocess.Popen([app_path], cwd=app_dir)
    time.sleep(wait_seconds)

    if proc.poll() is not None:
        # An NTSTATUS such as 0xC0000005 (access violation) reads as one.
        print(f"FAIL: App exited with code {proc.returncode} "
              f"(0x{proc.returncode & 0xFFFFFFFF:08X})")
        sys.exit(1)

    print(f"App running (PID {proc.pid})")

    window = visible_window_of(proc.pid)
    if window is None:
        print("FAIL: the app shows no visible window")
        proc.terminate()
        sys.exit(1)
    title, width, height = window
    print(f'Window: "{title}" ({width}x{height} client area)')

    # DXGI capture
    print("Capturing via DXGI Desktop Duplication...")
    camera = dxcam.create()
    frame = camera.grab()
    if frame is not None:
        img = Image.fromarray(frame)
        img.save(output_path)
        print(f"Screenshot saved: {output_path} ({img.size[0]}x{img.size[1]})")
    else:
        print("FAIL: dxcam.grab() returned None - no desktop compositor?")
        proc.terminate()
        sys.exit(1)

    # Cleanup
    proc.terminate()
    print("PASS")


if __name__ == "__main__":
    main()
