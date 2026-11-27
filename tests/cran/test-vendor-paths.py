"""CI: ordinary R-CMD-check POSIX matrix. Exercise both Makevars via real make/sh.

The Windows recipe is exercised on POSIX, not claimed as a Windows native run.
Cargo, Rscript and cleanup are bounded fixture commands; no compiler/model runs.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix", "Makevars shell fixture requires POSIX make/sh")
class VendorPaths(unittest.TestCase):
    def test_vendor_setup_and_cleanup_in_spaced_source(self):
        repository = Path(__file__).resolve().parents[2]
        for template in ("Makevars.in", "Makevars.win.in"):
            for bundled in (False, True):
                with self.subTest(template=template, tarball=bundled):
                    with tempfile.TemporaryDirectory(prefix="relm-vendor-paths-") as temporary:
                        root = Path(temporary).resolve()
                        source = root / "source with spaces" / "src"
                        source.mkdir(parents=True)
                        (source / "rust").mkdir()
                        neighbor = root / "source"
                        neighbor.mkdir()
                        sentinel = neighbor / "keep.txt"
                        sentinel.write_text("neighbor must survive\n")
                        (source / "rust/vendor-config.toml").write_text("fixture config\n")
                        vendor = source / "vendor"
                        vendor.mkdir()
                        (vendor / "fixture.txt").write_text("offline source\n")
                        if bundled:
                            with tarfile.open(source / "rust/vendor.tar.xz", "w:xz") as archive:
                                archive.add(vendor, arcname="vendor")
                            shutil.rmtree(vendor)

                        commands = root / "commands"
                        commands.mkdir()
                        fixture = commands / "command.py"
                        fixture.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

source = Path.cwd().resolve()
name = Path(sys.argv[0]).name
if name == "cargo":
    assert sys.argv[1:6] == ["build", "--locked", "-j", "2", "--offline"], sys.argv
    home = Path(os.environ["CARGO_HOME"])
    native = Path(os.environ["RELM_NATIVE_LIB_DIR"])
    assert home.is_absolute() and home.resolve() == source / ".cargo", str(home)
    assert (home / "config.toml").read_text() == "fixture config\\n"
    assert (source / "vendor/fixture.txt").read_text() == "offline source\\n"
    assert native.resolve().is_relative_to(source / "rust/target"), str(native)
    native.mkdir(parents=True, exist_ok=True)
    (native / "librelm.a").write_text("fixture staticlib\\n")
    Path(os.environ["RELM_PATH_RECEIPT"]).write_text(json.dumps({
        "cargo_home": str(home.resolve()), "native_dir": str(native.resolve())}))
elif name == "rm":
    # Never execute an unsafe old cleanup against a neighboring absolute fragment.
    for argument in sys.argv[1:]:
        if argument.startswith("-"):
            continue
        target = Path(argument).resolve()
        if target == source or not target.is_relative_to(source):
            raise RuntimeError("Refusing cleanup outside fixture source: " + str(target))
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
elif name == "fixture-rscript":
    assert sys.argv[1:] == ["--vanilla", "../tools/generate-wrappers.R", "relm.so", "../R/extendr-wrappers.R"]
else:
    raise AssertionError(name)
''')
                        fixture.chmod(0o755)
                        for command in ("cargo", "rm", "fixture-rscript"):
                            (commands / command).symlink_to(fixture)
                        replacements = {
                            "LIBDIR": "release", "WINDOWS_TARGET": "x86_64-pc-windows-gnu",
                            "R_STATE_LIB": "-lrelm-r-state", "LLAMA_LIBS": "",
                            "NATIVE_BUILD_ENV": "RELM_R_PORTABLE=1",
                            "PANIC_EXPORTS": "", "CRAN_FLAGS": "--locked -j 2 --offline",
                            "SELFTEST_FEATURE": "", "CUDA_FEATURE": "", "PROFILE": "--release",
                            "TARGET": "", "RSCRIPT": "fixture-rscript",
                            "CLEAN_TARGET": "$(TARGET_DIR)",
                        }
                        text = (repository / "rebirth/src" / template).read_text()
                        for key, value in replacements.items():
                            text = text.replace("@" + key + "@", value)
                        self.assertNotRegex(text, r"@[A-Z_]+@")
                        makefile = source / "fixture.mk"
                        makefile.write_text("SHLIB = relm.so\n" + text + "\nrelm.so:\n\ttouch relm.so\n")
                        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                                           RELM_PATH_RECEIPT=str(root / "receipt.json"))
                        environment.pop("PYTHONOPTIMIZE", None)
                        for target in ("all", "clean"):
                            if target == "clean":
                                vendor.mkdir()
                                (source / "rust/target").mkdir()
                                (source / "entrypoint.o").touch()
                            result = subprocess.run(["make", "-f", str(makefile), target],
                                                    cwd=source, env=environment,
                                                    text=True, capture_output=True)
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                            self.assertEqual(sentinel.read_text(), "neighbor must survive\n")
                            self.assertFalse(vendor.exists())
                            self.assertFalse((source / "rust/target").exists())
                            self.assertFalse((source / ".cargo").exists())
                        self.assertFalse((source / "entrypoint.o").exists())
                        self.assertFalse((source / "relm.so").exists())
                        observed = json.loads((root / "receipt.json").read_text())
                        self.assertEqual(observed["cargo_home"], str(source / ".cargo"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
