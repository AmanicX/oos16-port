#!/usr/bin/env python3
"""
Unit test suite for tools/extract_apex_info.py
Tests:
- Valid protobuf manifest extraction
- Valid JSON manifest extraction
- Compressed APEX archives
- Truncated varints
- Oversized / out-of-bounds length fields
- Malformed UTF-8 package names
- Conflicting duplicate tags
- Malformed / corrupted ZIP archives
- Invalid package identifiers
"""

import io
import json
import os
import sys
import tempfile
import unittest
import zipfile

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "tools"))
from extract_apex_info import parse_manifest_pb, extract_manifest_from_apex, validate_package_name


def encode_varint(value: int) -> bytes:
    res = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            res.append(b | 0x80)
        else:
            res.append(b)
            break
    return bytes(res)


def build_manifest_pb(name: str, version: int, version_name: str = "") -> bytes:
    buf = bytearray()
    # Field 1: name (string, wire 2)
    name_bytes = name.encode("utf-8")
    buf.append((1 << 3) | 2)
    buf.extend(encode_varint(len(name_bytes)))
    buf.extend(name_bytes)

    # Field 2: version (int64, wire 0)
    buf.append((2 << 3) | 0)
    buf.extend(encode_varint(version))

    # Field 3: versionName (string, wire 2)
    if version_name:
        vn_bytes = version_name.encode("utf-8")
        buf.append((3 << 3) | 2)
        buf.extend(encode_varint(len(vn_bytes)))
        buf.extend(vn_bytes)

    return bytes(buf)


class TestApexInfoParser(unittest.TestCase):
    def test_valid_manifest_pb(self):
        data = build_manifest_pb("com.android.runtime", 361501120, "16.0")
        name, version, version_name = parse_manifest_pb(data)
        self.assertEqual(name, "com.android.runtime")
        self.assertEqual(version, 361501120)
        self.assertEqual(version_name, "16.0")

    def test_truncated_varint_rejected(self):
        # Wire 0 with high bit set, but data ends
        data = bytearray([(2 << 3) | 0, 0x80])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("Truncated varint", str(ctx.exception))

    def test_oversized_length_delimited_field_rejected(self):
        # Wire 2 with declared length 100, but only 5 bytes provided
        data = bytearray([(1 << 3) | 2, 100, 65, 66, 67, 68, 69])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("exceeds remaining data", str(ctx.exception))

    def test_malformed_utf8_package_name_rejected(self):
        # Non-UTF8 byte sequence in field 1
        data = bytearray([(1 << 3) | 2, 4, 0xFF, 0xFE, 0x80, 0x81])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("Malformed UTF-8", str(ctx.exception))

    def test_conflicting_duplicate_fields_rejected(self):
        # Field 1 twice with different package names
        data = bytearray()
        data.extend(build_manifest_pb("com.android.runtime", 1))
        # Append conflicting name
        name_bytes = b"com.android.other"
        data.append((1 << 3) | 2)
        data.extend(encode_varint(len(name_bytes)))
        data.extend(name_bytes)

        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("Conflicting duplicate", str(ctx.exception))

    def test_invalid_package_name_format_rejected(self):
        with self.assertRaises(ValueError):
            validate_package_name("invalid_single_token")
        with self.assertRaises(ValueError):
            validate_package_name("com.android..double_dot")
        with self.assertRaises(ValueError):
            validate_package_name("")

    def test_corrupted_zip_archive_rejected(self):
        with tempfile.NamedTemporaryFile(suffix=".apex", delete=False) as f:
            f.write(b"NOT_A_VALID_ZIP_ARCHIVE_HEADER")
            temp_path = f.name
        try:
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("Invalid or corrupted ZIP", str(ctx.exception))
        finally:
            os.unlink(temp_path)

    def test_extract_from_valid_apex(self):
        with tempfile.NamedTemporaryFile(suffix=".apex", delete=False) as f:
            temp_path = f.name
        try:
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("apex_manifest.pb", build_manifest_pb("com.android.art", 361501120))
            name, version, _ = extract_manifest_from_apex(temp_path)
            self.assertEqual(name, "com.android.art")
            self.assertEqual(version, 361501120)
        finally:
            os.unlink(temp_path)

    def test_extract_from_compressed_apex(self):
        with tempfile.NamedTemporaryFile(suffix=".apex", delete=False) as f:
            temp_path = f.name
        try:
            # Inner zip
            inner_buf = io.BytesIO()
            with zipfile.ZipFile(inner_buf, "w") as iz:
                iz.writestr("apex_manifest.pb", build_manifest_pb("com.android.tzdata", 361157000))
            inner_data = inner_buf.getvalue()

            # Outer zip containing original_apex
            with zipfile.ZipFile(temp_path, "w") as oz:
                oz.writestr("original_apex", inner_data)

            name, version, _ = extract_manifest_from_apex(temp_path)
            self.assertEqual(name, "com.android.tzdata")
            self.assertEqual(version, 361157000)
        finally:
            os.unlink(temp_path)


if __name__ == "__main__":
    unittest.main()
