#!/usr/bin/env python3
"""Audit every executable in an extracted TrollStore app, including WebRTC."""
import pathlib
import plistlib
import re
import subprocess
import sys


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0])[:3])


def audit(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["MinimumOSVersion"] == "15.0", "App must retain the iOS 15.0 minimum"
    assert sorted(info["UIDeviceFamily"]) == [1, 2], "Universal iPhone/iPad app required"
    assert not list(app.rglob("embedded.mobileprovision")), "Unexpected provisioning profile"
    assert (app / "Frameworks/WebRTC.framework/WebRTC").is_file(), "Missing embedded WebRTC"
    assert (app / "WebRTC-LICENSE.txt").is_file(), "Missing WebRTC license"

    magic = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    count = 0
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as handle:
            if handle.read(4) not in magic:
                continue
        relative = path.relative_to(app)
        assert command("xcrun", "lipo", "-archs", str(path)).strip() == "arm64", relative
        build = command("xcrun", "vtool", "-show-build", str(path))
        platforms = re.findall(r"platform\s+(\S+)", build)
        minimums = re.findall(r"minos\s+(\S+)", build)
        assert platforms == ["IOS"], f"{relative}: wrong platform {platforms}"
        assert len(minimums) == 1 and version(minimums[0]) <= version("15.0"), (
            f"{relative}: minimum OS {minimums}"
        )
        libraries = command("otool", "-L", str(path))
        assert "/PrivateFrameworks/" not in libraries, f"{relative}: private framework dependency"
        signature = subprocess.run(
            ["codesign", "-d", "--verbose=2", str(path)], capture_output=True, text=True
        )
        details = signature.stdout + signature.stderr
        if signature.returncode == 0:
            assert "Signature=adhoc" in details and "Authority=" not in details, (
                f"{relative}: unexpected certificate signature"
            )
            entitlements = subprocess.run(
                ["codesign", "-d", "--entitlements", ":-", str(path)], capture_output=True
            ).stdout
            if entitlements:
                assert not plistlib.loads(entitlements), f"{relative}: unexpected entitlements"
            signing = "ad hoc, no entitlements"
        else:
            assert "not signed at all" in details, f"{relative}: unreadable signature"
            signing = "unsigned"
        count += 1
        print(f"{relative}: arm64, iOS {minimums[0]}, {signing}, public framework dependencies")
    assert count >= 2, "Expected app and embedded WebRTC executable"
    print(f"All {count} Mach-O executables passed the extracted-app audit.")


if __name__ == "__main__":
    audit(pathlib.Path(sys.argv[1]).resolve())
