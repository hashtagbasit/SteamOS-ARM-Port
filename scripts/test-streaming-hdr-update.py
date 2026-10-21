import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install-streaming-hdr.sh"
SOURCE = ROOT / "steamos-overlay/usr/lib/steamos/sm8550-streaming-client"
loader = importlib.machinery.SourceFileLoader("streaming_hdr", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
client = importlib.util.module_from_spec(spec)
loader.exec_module(client)


class StreamingHDRTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.root = self.work / "Steam"
        (self.root / "steamrt64").mkdir(parents=True)
        (self.root / ".pyrowave-box64").touch()
        (self.root / "steamrt64/libSDL3.so.0").write_bytes(b"original SDL")
        self.bundle = self.work / "bundle"
        self.bundle.mkdir()
        library = bytearray(20)
        library[:6] = b"\x7fELF\x02\x01"
        library[18:20] = b"\x3e\x00"
        (self.bundle / "libSDL3.so.0").write_bytes(library)
        (self.bundle / "LICENSE.txt").write_text("test license")
        self.manifest = {
            "sdl_revision": "test",
            "steam_sdl_sha256": hashlib.sha256(b"original SDL").hexdigest(),
            "libSDL3_sha256": hashlib.sha256(library).hexdigest(),
        }
        (self.bundle / "manifest.json").write_text(json.dumps(self.manifest))
        self.board = self.work / "compatible"
        self.board.write_bytes(b"qcom,sm8550\0ayn,odin2portal\0")
        for name, value in (("BUNDLE", self.bundle), ("BOARD", self.board)):
            patcher = mock.patch.object(client, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.rootfs = self.work / "rootfs"
        self.rootfs.mkdir()

    @mock.patch.object(client.Path, "glob", return_value=[Path("/dev/dri/renderD128")])
    @mock.patch.object(client.runpy, "run_path")
    def test_compatible_library_requires_real_ten_bit_probe(self, run_path, glob):
        probe = mock.Mock()
        run_path.return_value = {"probe_av1": probe}
        self.assertEqual(client.hdr_library(self.root), self.bundle / "libSDL3.so.0")
        probe.assert_called_once_with(Path("/dev/dri/renderD128"), 0x100)
        probe.side_effect = RuntimeError("no P010 config")
        with self.assertRaisesRegex(RuntimeError, "no P010 config"):
            client.hdr_library(self.root)

    def test_unsupported_device_and_opt_out_keep_stock_sdl(self):
        for board in (b"ayn,odin2\0", b"ayn,odin2portal-extra\0"):
            self.board.write_bytes(board)
            self.assertIsNone(client.hdr_library(self.root))
        self.board.write_bytes(b"ayn,odin2portal\0")
        (self.root / ".no-hdr-box64").touch()
        self.assertIsNone(client.hdr_library(self.root))
        (self.root / ".no-hdr-box64").unlink()
        (self.root / ".pyrowave-box64").unlink()
        self.assertIsNone(client.hdr_library(self.root))

    def test_steam_update_and_corrupt_bundle_are_rejected(self):
        original = self.root / "steamrt64/libSDL3.so.0"
        original.write_bytes(b"new Steam runtime")
        with self.assertRaisesRegex(RuntimeError, "compatibility check"):
            client.hdr_library(self.root)
        original.write_bytes(b"original SDL")
        (self.bundle / "libSDL3.so.0").write_bytes(b"damaged library")
        with self.assertRaisesRegex(RuntimeError, "compatibility check"):
            client.hdr_library(self.root)

    def test_wrong_architecture_is_rejected_even_with_matching_hash(self):
        library = self.bundle / "libSDL3.so.0"
        library.write_bytes(b"not x86")
        self.manifest["libSDL3_sha256"] = hashlib.sha256(library.read_bytes()).hexdigest()
        (self.bundle / "manifest.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(RuntimeError, "not an x86-64"):
            client.hdr_library(self.root)

    @mock.patch.object(client.os, "execvpe")
    def test_exec_preserves_arguments_and_environment(self, execute):
        for library in (None, self.bundle / "libSDL3.so.0"):
            with self.subTest(library=library), \
                    mock.patch.object(client, "hdr_library", return_value=library), \
                    mock.patch.dict(os.environ, {"BOX64_LD_PRELOAD": "existing.so",
                                                 "BOX64_EMULATED_LIBS": "libSDL3_ttf.so.0"}):
                client.main(self.root, ["--example", "argument with spaces"])
                executable, arguments, environment = execute.call_args.args
                self.assertEqual(executable, "box64")
                self.assertEqual(arguments, ["box64", str(self.root / "steamrt64/streaming_client"),
                                             "--example", "argument with spaces"])
                self.assertEqual(environment["BOX64_EMULATED_LIBS"], "libSDL3_ttf.so.0")
                expected = f"{library}:existing.so" if library else "existing.so"
                self.assertEqual(environment["BOX64_LD_PRELOAD"], expected)

    @mock.patch.object(client.os, "execvpe")
    def test_probe_failure_is_reported_and_stock_client_still_launches(self, execute):
        with mock.patch.object(client, "hdr_library", side_effect=RuntimeError("unsupported")), \
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr, \
                mock.patch.dict(os.environ, {}, clear=True):
            client.main(self.root, [])
            self.assertIn("using stock SDL: unsupported", stderr.getvalue())
            self.assertNotIn("BOX64_LD_PRELOAD", execute.call_args.args[2])

    def install(self, bundle=None):
        return subprocess.run(
            ["bash", str(INSTALLER), str(self.rootfs)], capture_output=True, text=True,
            env={**os.environ, "STREAMING_HDR_BUILD": str(bundle or self.bundle)},
        )

    def test_installs_complete_bundle_and_startup_integration(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in self.bundle.iterdir():
            installed = self.rootfs / "usr/lib/steamos/streaming-hdr" / path.name
            self.assertEqual(installed.read_bytes(), path.read_bytes())
        for path in ("usr/lib/steamos/sm8550-steam-av1",
                     "usr/lib/steamos/sm8550-streaming-client"):
            installed = self.rootfs / path
            self.assertEqual(installed.read_bytes(), (ROOT / "steamos-overlay" / path).read_bytes())
            self.assertEqual(installed.stat().st_mode & 0o777, 0o755)
        for name in ("apply-overlays.sh", "apply-overlays-sm8750.sh"):
            self.assertIn('bash "${SCRIPT_DIR}/install-streaming-hdr.sh" "$R"',
                          (ROOT / "scripts" / name).read_text())

    def test_incomplete_bundle_fails_before_installing_anything(self):
        for name in ("libSDL3.so.0", "manifest.json", "LICENSE.txt"):
            with self.subTest(name=name):
                path = self.bundle / name
                saved = path.read_bytes()
                path.unlink()
                try:
                    result = self.install()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(result.stderr)
                    self.assertFalse(list(self.rootfs.iterdir()))
                finally:
                    path.write_bytes(saved)

    def test_corrupt_bundle_fails_before_installing_anything(self):
        (self.bundle / "libSDL3.so.0").write_bytes(b"corrupt")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertFalse(list(self.rootfs.iterdir()))

    def test_explicit_missing_bundle_fails(self):
        result = self.install(self.work / "missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertFalse(list(self.rootfs.iterdir()))

    def test_optional_absent_bundle_is_reported_without_changes(self):
        environment = {**os.environ, "STEAMOS_WORK": str(self.work)}
        environment.pop("STREAMING_HDR_BUILD", None)
        result = subprocess.run(["bash", str(INSTALLER), str(self.rootfs)],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping HDR client installation", result.stderr)
        self.assertFalse(list(self.rootfs.iterdir()))


if __name__ == "__main__":
    unittest.main()
