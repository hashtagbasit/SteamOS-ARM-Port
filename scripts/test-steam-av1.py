#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "steamos-overlay/usr/lib/steamos/sm8550-steam-av1"
loader = importlib.machinery.SourceFileLoader("steam_av1", str(MODULE))
spec = importlib.util.spec_from_loader(loader.name, loader)
bridge = importlib.util.module_from_spec(spec)
loader.exec_module(bridge)


class SteamAV1Tests(unittest.TestCase):
    def test_source_round_trip_and_idempotence(self):
        source = '"use strict";SteamClient.RemotePlay.RegisterForSettingsChanges(cb);'
        updated = bridge.adapt_source(source, True)
        self.assertTrue(updated.startswith('"use strict";'))
        self.assertEqual(bridge.adapt_source(updated, True), updated)
        self.assertEqual(bridge.adapt_source(updated, False), source)

    def test_unknown_and_ambiguous_layouts_are_rejected(self):
        for source in ("", bridge.CALL + "(cb);" + bridge.CALL + "(cb);",
                       bridge.BEGIN + "incomplete"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                bridge.adapt_source(source, True)

    def make_client(self, root):
        (root / ".pyrowave-box64").touch()
        wrapper = root / "steamrtarm64/streaming_client"
        wrapper.parent.mkdir()
        launcher = (ROOT / "steamos-overlay/usr/share/deckard/RUNSTEAM.sh").read_text()
        template = launcher.split('cat >"${_sc}" <<EOF || true\n', 1)[1].split("\nEOF", 1)[0]
        generated = subprocess.run(
            ["bash", "-c", "STEAMROOT=$1\ncat <<EOF\n" + template + "\nEOF",
             "wrapper", str(root)], check=True, capture_output=True,
        )
        wrapper.write_bytes(generated.stdout)
        wrapper.chmod(0o755)
        client = root / "steamrt64/streaming_client"
        client.parent.mkdir()
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = b"\x3e\x00"
        client.write_bytes(header + b"--enable-av1\0CVAAPIGamescopeAccel:\0")
        client.chmod(0o755)
        return wrapper, client

    @mock.patch.object(bridge.shutil, "which", return_value="/usr/bin/box64")
    def test_requires_known_compatible_client(self, which):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper, client = self.make_client(root)
            self.assertTrue(bridge.uses_box64_client(root, "steamrtarm64"))
            original = client.read_bytes()
            for contents in (b"", b"\x7fELF\x02\x01" + bytes(80),
                             original.replace(b"--enable-av1", b"--enable-xxx"),
                             original.replace(b"CVAAPIGamescopeAccel", b"UnsupportedDecoder_")):
                client.write_bytes(contents)
                self.assertFalse(bridge.uses_box64_client(root, "steamrtarm64"))
            client.write_bytes(original)
            wrapper.write_text(wrapper.read_text().replace(
                "exec env ", "exec env LIBVA_DRIVER_NAME=other "))
            self.assertFalse(bridge.uses_box64_client(root, "steamrtarm64"))
            wrapper.write_bytes(b"\x7fELF" + bytes(80))
            self.assertFalse(bridge.uses_box64_client(root, "steamrtarm64"))

    @mock.patch.object(bridge.shutil, "which", return_value=None)
    def test_requires_box64(self, which):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_client(root)
            self.assertFalse(bridge.uses_box64_client(root, "steamrtarm64"))

    def test_stale_bridge_is_removed_before_probe_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "steamui/sp.js"
            path.parent.mkdir()
            source = bridge.CALL + "(cb);"
            path.write_text(bridge.adapt_source(source, True))
            with mock.patch.object(bridge, "uses_box64_client", return_value=True), \
                    mock.patch.object(bridge.Path, "glob", return_value=[Path("/dev/dri/renderD128")]), \
                    mock.patch.object(bridge, "probe_av1", side_effect=RuntimeError("unsupported")):
                with self.assertRaisesRegex(RuntimeError, "unsupported"):
                    bridge.main(root, "steamrtarm64")
            self.assertEqual(path.read_text(), source)

    def test_native_client_removes_stale_bridge_without_probing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "steamui/sp.js"
            path.parent.mkdir()
            source = bridge.CALL + "(cb);"
            path.write_text(bridge.adapt_source(source, True))
            with mock.patch.object(bridge, "uses_box64_client", return_value=False), \
                    mock.patch.object(bridge, "probe_av1") as probe:
                bridge.main(root, "steamrtarm64")
                probe.assert_not_called()
            self.assertEqual(path.read_text(), source)

    def test_real_va_api_configuration_and_cleanup(self):
        for operation in (None, "vaInitialize", "vaCreateConfig"):
            with self.subTest(operation=operation):
                va, drm = mock.Mock(), mock.Mock()
                for name in ("vaInitialize", "vaCreateConfig",
                             "vaDestroyConfig", "vaTerminate"):
                    getattr(va, name).return_value = 0
                drm.vaGetDisplayDRM.return_value = 100
                va.vaErrorStr.return_value = b"unsupported profile"
                if operation:
                    getattr(va, operation).return_value = 12
                with mock.patch.object(bridge.ctypes, "CDLL", side_effect=[va, drm]), \
                        mock.patch.object(bridge.os, "open", return_value=99), \
                        mock.patch.object(bridge.os, "close") as close:
                    if operation:
                        with self.assertRaisesRegex(RuntimeError, "unsupported profile"):
                            bridge.probe_av1("/dev/dri/renderD128")
                    else:
                        bridge.probe_av1("/dev/dri/renderD128")
                    close.assert_called_once_with(99)
                if operation == "vaInitialize":
                    va.vaCreateConfig.assert_not_called()
                    va.vaTerminate.assert_not_called()
                else:
                    arguments = va.vaCreateConfig.call_args.args
                    self.assertEqual(arguments[:3], (100, 32, 1))
                    self.assertEqual(arguments[3]._obj.type, 0)
                    self.assertEqual(arguments[3]._obj.value, 1)
                    va.vaTerminate.assert_called_once_with(100)
                self.assertEqual(va.vaDestroyConfig.call_count, int(operation is None))

    def test_runtime_adapter_preserves_other_capabilities_and_subscriptions(self):
        program = r"""
const assert = require("node:assert/strict");
let listener, calls = 0;
const subscription = {unregister() {}};
const remote = {
  RegisterForSettingsChanges(callback) {
    assert.equal(this, remote);
    listener = callback;
    calls++;
    return subscription;
  }
};
global.SteamClient = {RemotePlay: remote};
const install = () => eval(BRIDGE);
const subscribe = install();
const installed = remote.RegisterForSettingsChanges;
install();
assert.equal(remote.RegisterForSettingsChanges, installed);
let received;
assert.equal(subscribe(value => {received = value}), subscription);
assert.equal(calls, 1);
const local = {
  unStreamingSessionID: 0, bAV1DecodeAvailable: false,
  bHEVCDecodeAvailable: false, bPyrowaveDecodeAvailable: false,
  RemotePlayClientConfig: new Uint8Array([1, 2])
};
listener(local);
assert.equal(received.bAV1DecodeAvailable, true);
assert.equal(local.bAV1DecodeAvailable, false);
assert.equal(received.bHEVCDecodeAvailable, false);
assert.equal(received.bPyrowaveDecodeAvailable, false);
assert.equal(received.RemotePlayClientConfig, local.RemotePlayClientConfig);
for (const value of [
  {...local, unStreamingSessionID: 7},
  {...local, bAV1DecodeAvailable: true},
  {bAV1DecodeAvailable: false},
  null
]) {
  listener(value);
  assert.equal(received, value);
}
const failure = new Error("consumer failed");
subscribe(() => {throw failure});
assert.throws(() => listener(local), error => error === failure);
const native = function () {return subscription};
SteamClient.RemotePlay = Object.freeze({RegisterForSettingsChanges: native});
assert.equal(install()(() => {}), subscription);
assert.equal(SteamClient.RemotePlay.RegisterForSettingsChanges, native);
"""
        subprocess.run(["node", "-e", "const BRIDGE = " +
                        json.dumps(bridge.BRIDGE) + ";\n" + program], check=True)


if __name__ == "__main__":
    unittest.main()
