#!/usr/bin/env python3
"""Make an .app bundle self-contained: copy every non-system dylib/framework that its Mach-O files
link against into Contents/Frameworks and rewrite the references to @rpath.

usage: bundle_fix.py Amarok.app SEARCH_DIR...
SEARCH_DIRs are where '@rpath/x.dylib' references (no absolute path) can be resolved from."""
import os, re, shutil, subprocess, sys

app = os.path.abspath(sys.argv[1])
search = sys.argv[2:]
contents = os.path.join(app, "Contents")
fw_dir = os.path.join(contents, "Frameworks")
os.makedirs(fw_dir, exist_ok=True)


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def deps(path):
    """Load-command references of a Mach-O file, without its own install name."""
    out = run("otool", "-L", path).stdout.splitlines()[1:]
    refs = [l.strip().split(" (")[0] for l in out]
    own = run("otool", "-D", path).stdout.splitlines()[1:]
    return [r for r in refs if r not in own]


def rpaths(path):
    out = run("otool", "-l", path).stdout.splitlines()
    return [out[i + 2].strip().split(" (")[0][5:] for i, l in enumerate(out) if "cmd LC_RPATH" in l]


def system(dep):
    return dep.startswith(("/usr/lib/", "/System/", "@loader_path", "@executable_path"))


def find_file(dep):
    """Resolve a dependency reference to a real file on disk, or None."""
    if dep.startswith("@rpath/"):
        rel = dep[7:]
        for d in search:
            p = os.path.join(d, rel)
            if os.path.exists(p):
                return os.path.realpath(p)
        return None
    return os.path.realpath(dep) if os.path.exists(dep) else None


def bundled_ref(dep, real):
    """Copy the dependency into Frameworks (once); return the new @rpath reference."""
    m = re.search(r"([^/]+\.framework)/(.*)$", dep)
    if m:
        fw, rest = m.group(1), m.group(2)
        dst = os.path.join(fw_dir, fw)
        if not os.path.exists(dst):
            root = real[: real.index("/" + fw + "/") + len(fw) + 1]
            shutil.copytree(root, dst, symlinks=True, ignore=shutil.ignore_patterns("Headers", "*.prl", "*.dSYM"))
        return "@rpath/%s/%s" % (fw, rest)
    name = os.path.basename(dep)
    dst = os.path.join(fw_dir, name)
    if not os.path.exists(dst):
        shutil.copy2(real, dst)
        os.chmod(dst, 0o755)
    return "@rpath/" + name


def all_macho():
    for base, dirs, files in os.walk(contents):
        for n in files:
            p = os.path.join(base, n)
            if is_macho(p):
                yield p


done, missing = set(), set()
while True:
    todo = [p for p in all_macho() if p not in done]
    if not todo:
        break
    for path in todo:
        done.add(path)
        for dep in deps(path):
            if system(dep):
                continue
            if dep.startswith("@rpath/") and os.path.exists(os.path.join(fw_dir, dep[7:])):
                continue
            real = find_file(dep)
            if real is None:
                missing.add(dep)
                continue
            new = bundled_ref(dep, real)
            run("install_name_tool", "-change", dep, new, path)

# install names of the bundled libraries, and an rpath on every file that points at Frameworks
for path in all_macho():
    rel = os.path.relpath(fw_dir, os.path.dirname(path))
    want = "@loader_path/" + rel if rel != "." else "@loader_path"
    for rp in rpaths(path):
        if rp != want:
            run("install_name_tool", "-delete_rpath", rp, path, check=False)
    if want not in rpaths(path):
        run("install_name_tool", "-add_rpath", want, path)
    if path.startswith(fw_dir + "/"):
        run("install_name_tool", "-id", "@rpath/" + os.path.relpath(path, fw_dir), path, check=False)
    elif path.endswith((".dylib", ".so")):  # plugins: just don't leave the build path as the install name
        run("install_name_tool", "-id", "@rpath/" + os.path.basename(path), path, check=False)

if missing:
    print("UNRESOLVED:", *sorted(missing), sep="\n  ")
    sys.exit(1)
print("bundled %d Mach-O files" % len(done))
