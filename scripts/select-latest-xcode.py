#!/usr/bin/env python3
"""Print the path of the newest Xcode.app under /Applications."""

import glob
import os
import subprocess


def version(app: str) -> tuple:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = os.path.join(app, "Contents", "Developer")
    output = subprocess.check_output(["xcodebuild", "-version"], env=env, text=True)
    numbers = output.splitlines()[0].split()[-1]
    return tuple(int(part) for part in numbers.split("."))


def main() -> None:
    apps = glob.glob("/Applications/Xcode*.app")
    if not apps:
        raise SystemExit("No Xcode.app found in /Applications")
    print(max(apps, key=version))


if __name__ == "__main__":
    main()
