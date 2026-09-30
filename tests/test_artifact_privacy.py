import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("artifact_privacy", ROOT / "scripts/check-artifact-privacy.py")
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class ArtifactPrivacyTests(unittest.TestCase):
    def test_rejects_home_paths_without_rejecting_remapped_paths(self):
        for path in (b"/home/builder/.cargo/src/file.rs", b"/Users/builder/code/file.cpp",
                     b"C:\\Users\\builder\\code\\file.cpp", b"C:/Users/builder/code/file.cpp"):
            self.assertTrue(privacy.contains_local_path(path, []))
        for encoding in ("utf-16le", "utf-16be"):
            self.assertTrue(privacy.contains_local_path("/home/builder/code/file.rs".encode(encoding), []))
        self.assertFalse(privacy.contains_local_path(b"/build/cargo/src/file.rs /build/source/file.cpp", []))
        self.assertTrue(privacy.contains_local_path(b"/work/checkout/src/file.rs", [b"/work/checkout/"]))

    def test_checks_all_apk_entries_and_native_files(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("lib/arm64-v8a/libtest.so", b"/build/source/lib.rs")
                archive.writestr("classes.dex", b"/home/builder/code/file.rs")
                archive.writestr("assets/", b"")
                archive.writestr("home/builder/code/", b"")
                archive.writestr("assets/home/builder/code/file.txt", b"fixture")
            self.assertEqual(["classes.dex", "assets/home/builder/code/file.txt"], privacy.check(apk, []))
            result = subprocess.run([os.sys.executable, str(ROOT / "scripts/check-artifact-privacy.py"), str(apk)],
                                    capture_output=True, text=True)
            self.assertEqual(1, result.returncode)
            self.assertIn("local build paths in 2 entries", result.stdout)
            self.assertNotIn("builder", result.stdout)
            self.assertNotIn("assets/home", result.stdout)
            library = Path(directory) / "test.so"
            library.write_bytes(b"/Users/builder/code/file.cpp")
            self.assertEqual(["test.so"], privacy.check(library, []))
            library.write_bytes(b"/build/source/file.cpp")
            self.assertEqual([], privacy.check(library, []))

    def flags(self, **overrides):
        env = {key: value for key, value in os.environ.items()
               if key not in ("CARGO_ENCODED_RUSTFLAGS", "RUSTFLAGS", "CARGO_HOME", "RUSTUP_HOME", "ANDROID_NDK_HOME")}
        env.update(HOME="/tmp/example user", **overrides)
        result = subprocess.check_output([
            "bash", "-euc", 'source "$1"; printf "%s\\0" "$CARGO_ENCODED_RUSTFLAGS" "${native_cpp_flags[@]}"',
            "flags-test", str(ROOT / "scripts/native-path-flags.sh")], cwd=ROOT, env=env)
        values = result.decode().rstrip("\0").split("\0")
        return values[0].split("\x1f"), values[1:]

    def test_flags_preserve_spaces_and_encoded_caller_options(self):
        rust, cpp = self.flags(CARGO_ENCODED_RUSTFLAGS="--cfg\x1ffeature=\"custom\"", RUSTFLAGS="ignored")
        self.assertEqual(["--cfg", 'feature="custom"'], rust[:2])
        self.assertIn("--remap-path-prefix=/tmp/example user=/build/user", rust)
        self.assertEqual(f"--remap-path-prefix={ROOT}=/build/source", rust[-1])
        self.assertIn("-ffile-prefix-map=/tmp/example user=/build/user", cpp)
        self.assertIn("-g0", cpp)
        self.assertNotIn("ignored", rust)

    def test_plain_and_empty_flags_and_external_cache_paths(self):
        rust, _ = self.flags(RUSTFLAGS="-C opt-level=2", CARGO_HOME="/cache/cargo", RUSTUP_HOME="/cache/rustup")
        self.assertEqual(["-C", "opt-level=2"], rust[:2])
        self.assertIn("--remap-path-prefix=/cache/cargo=/build/cargo", rust)
        self.assertIn("--remap-path-prefix=/cache/rustup=/build/rustup", rust)
        rust, _ = self.flags()
        self.assertTrue(all(rust))

    def test_removes_local_development_rpaths_without_losing_toolchain_paths(self):
        env = dict(os.environ, HOME="/tmp/example user",
                   NIX_LDFLAGS=f'-rpath "/tmp/example user/lib" -rpath {ROOT}/outputs/out/lib -rpath /nix/store/toolchain/lib -z now')
        result = subprocess.check_output([
            "bash", "-euc", 'source "$1"; printf "%s" "$NIX_LDFLAGS"',
            "rpath-test", str(ROOT / "scripts/native-path-flags.sh")], cwd=ROOT, env=env)
        self.assertEqual("-rpath /nix/store/toolchain/lib -z now", result.decode())


if __name__ == "__main__":
    unittest.main()
