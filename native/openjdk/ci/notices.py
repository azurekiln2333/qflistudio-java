#!/usr/bin/env python3
"""Keep dependency notices with the distributed native runtime."""

import json
from pathlib import Path
import shutil
import sys


def add_notices(image: Path, work: Path, cache: Path, platform: str) -> None:
    legal = image / "legal"
    if platform == "android":
        retained = cache / "licenses"
        for notice in ("alsa-lib/COPYING", "libiconv/COPYING", "libiconv/COPYING.LIB"):
            if not (retained / notice).is_file():
                raise FileNotFoundError(f"Missing retained dependency notice: {notice}")
        shutil.copytree(retained, legal / "qfli-termux", dirs_exist_ok=True)
        docs = work / "dependencies/data/data/com.termux/files/usr/share/doc"
        for source in docs.rglob("*"):
            name = source.name.lower()
            if source.is_file() and (name.startswith(("copying", "copyright", "license"))):
                target = legal / "qfli-termux-packages" / source.relative_to(docs)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    elif platform == "ohos":
        for source, package in ((work / "alsa/COPYING", "alsa-lib"),
                                (work / "libffi/LICENSE", "libffi")):
            target = legal / f"qfli-{package}" / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    else:
        raise ValueError(f"Unsupported platform: {platform}")

    inputs = json.loads(Path(__file__).with_name("inputs.lock.json").read_text())
    (legal / "qfli-build-inputs.json").write_text(
        json.dumps(inputs, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    add_notices(*(Path(value) for value in sys.argv[1:4]), sys.argv[4])
