"""Builds dist/SimpleAH-Linux.zip: the addon plus simple-ah.py, with forward-slash
paths, LF line endings for the script and the executable bit set."""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADDON = os.path.join(ROOT, "addon", "SimpleAH")
OUT = os.path.join(os.path.dirname(HERE), "dist", "SimpleAH-Linux.zip")


def add(z, arcname, data, mode=0o644):
    info = zipfile.ZipInfo(arcname)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (0o100000 | mode) << 16
    info.create_system = 3  # unix, so the mode bits are honoured
    z.writestr(info, data)


def lf(path):
    with open(path, "rb") as f:
        return f.read().replace(b"\r\n", b"\n")


os.makedirs(os.path.dirname(OUT), exist_ok=True)
with zipfile.ZipFile(OUT, "w") as z:
    for dirpath, _, files in os.walk(ADDON):
        for name in sorted(files):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, os.path.dirname(ADDON)).replace(os.sep, "/")
            with open(full, "rb") as f:
                add(z, rel, f.read())
    add(z, "simple-ah.py", lf(os.path.join(HERE, "simple-ah.py")), 0o755)
    add(z, "README.txt", lf(os.path.join(HERE, "README.txt")))
print("Built", OUT)
