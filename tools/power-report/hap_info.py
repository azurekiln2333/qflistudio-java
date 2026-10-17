"""Read-only: report the real bundleName/version from a .hap (zip) module.json.

Used only to verify which bundle a built HAP actually targets, so the device
install targets the correct package. Prints no signing material.
"""
import json
import re
import sys
import zipfile


def main(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    print("hap entries:", len(names))
    cands = [n for n in names if n.endswith("module.json")]
    print("module.json entries:", cands[:5])
    for n in cands[:1]:
        raw = z.read(n).decode("utf-8", "ignore")
        # The packed module.json may be plain JSON.
        try:
            data = json.loads(raw)
        except Exception:
            m = re.search(r'"bundleName"\s*:\s*"([^"]+)"', raw)
            print("bundleName(regex):", m.group(1) if m else "n/a")
            continue
        mod = data.get("module", {})
        app = data.get("app", {})
        print("bundleName:", app.get("bundleName"))
        print("moduleName:", mod.get("name"))
        print("versionCode:", app.get("versionCode"))
        print("versionName:", app.get("versionName"))
        print("debuggable:", app.get("debug"))


if __name__ == "__main__":
    main(sys.argv[1])
