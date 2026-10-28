"""Run against an ad-hoc prepared Ahna .ipa or .app, without Apple credentials."""
import copy
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from verify_ipa import ValidationError, commands, load_files, verify_files

fixture = sys.argv.pop(1) if len(sys.argv) > 1 else None


class SigningPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if fixture is None:
            raise RuntimeError("Provide the prepared .ipa or .app as the first argument")
        cls.original = load_files(fixture)
        cls.host_info = next(p for p in cls.original if p.endswith(".app/Info.plist"))
        cls.extension_info = next(p for p in cls.original if p.endswith(".appex/Info.plist"))
        cls.prefix = cls.extension_info[:-len("Info.plist")]
        cls.binary = cls.prefix + "AhnaShare"

    def setUp(self):
        self.files = copy.copy(self.original)

    def signature_offsets(self):
        data = self.files[self.binary]
        load_offset = next(offset for command, offset, _ in commands(data) if command == 0x1D)
        start = struct.unpack_from("<I", data, load_offset + 8)[0]
        count = struct.unpack_from(">I", data, start + 8)[0]
        for index in range(count):
            slot, relative = struct.unpack_from(">2I", data, start + 12 + index * 8)
            if slot == 0:
                return load_offset, start + relative
        raise AssertionError("Missing code directory")

    def test_prepared_bundle_is_accepted(self):
        report = verify_files(self.files)
        self.assertEqual(len(report["bundles"]), 2)
        self.assertTrue(all(b["directories"][0]["execSegFlags"] & 1 for b in report["bundles"]))

    def test_unsigned_extension_is_rejected(self):
        load, _ = self.signature_offsets()
        data = bytearray(self.files[self.binary])
        struct.pack_into("<I", data, load, 0x9999)
        self.files[self.binary] = bytes(data)
        with self.assertRaisesRegex(ValidationError, "Missing LC_CODE_SIGNATURE"):
            verify_files(self.files)

    def test_missing_main_binary_flag_is_rejected(self):
        _, directory = self.signature_offsets()
        data = bytearray(self.files[self.binary])
        struct.pack_into(">Q", data, directory + 80, 0)
        self.files[self.binary] = bytes(data)
        with self.assertRaisesRegex(ValidationError, "CS_EXECSEG_MAIN_BINARY"):
            verify_files(self.files)

    def test_wrong_executable_bounds_are_rejected(self):
        _, directory = self.signature_offsets()
        data = bytearray(self.files[self.binary])
        struct.pack_into(">Q", data, directory + 72, 0)
        self.files[self.binary] = bytes(data)
        with self.assertRaisesRegex(ValidationError, "segment bounds"):
            verify_files(self.files)

    def test_corrupted_code_page_is_rejected(self):
        data = bytearray(self.files[self.binary])
        data[0x30F0] ^= 1
        self.files[self.binary] = bytes(data)
        with self.assertRaisesRegex(ValidationError, "Code page hash mismatch"):
            verify_files(self.files)

    def test_changed_info_plist_is_rejected(self):
        info = plistlib.loads(self.files[self.extension_info])
        info["CFBundleDisplayName"] = "Tampered"
        self.files[self.extension_info] = plistlib.dumps(info)
        with self.assertRaisesRegex(ValidationError, "Special slot hash mismatch: 1"):
            verify_files(self.files)

    def test_changed_resource_seal_is_rejected(self):
        name = self.prefix + "_CodeSignature/CodeResources"
        self.files[name] += b"\n"
        with self.assertRaisesRegex(ValidationError, "Special slot hash mismatch: 3"):
            verify_files(self.files)

    def test_changed_resource_contents_are_rejected(self):
        name = self.prefix + "PrivacyInfo.xcprivacy"
        self.files[name] += b"\n"
        with self.assertRaisesRegex(ValidationError, "Resource hash mismatch"):
            verify_files(self.files)

    def test_missing_share_executable_is_rejected(self):
        del self.files[self.binary]
        with self.assertRaisesRegex(ValidationError, "Missing executable"):
            verify_files(self.files)

    def test_different_app_extension_versions_are_rejected(self):
        info = plistlib.loads(self.files[self.extension_info])
        info["CFBundleVersion"] = "wrong-build"
        self.files[self.extension_info] = plistlib.dumps(info)
        with self.assertRaisesRegex(ValidationError, "versions differ"):
            verify_files(self.files)

    def test_path_traversal_archive_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="ahna-sign-test-") as directory:
            path = Path(directory) / "bad.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("../escape", b"x")
            with self.assertRaisesRegex(ValidationError, "Unsafe ZIP path"):
                load_files(path)

    def test_duplicate_archive_entry_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="ahna-sign-test-") as directory:
            path = Path(directory) / "duplicate.ipa"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("Payload/a", b"x")
                    archive.writestr("Payload/a", b"y")
            with self.assertRaisesRegex(ValidationError, "Duplicate ZIP entry"):
                load_files(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
