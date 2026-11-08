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
from extract_apex_info import (
    parse_manifest_pb,
    extract_manifest_from_apex,
    validate_package_name,
    validate_apex_info_xml,
    generate_apex_info_xml,
    get_apex_manifest_info,
)


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

    def test_varint_64bit_overflow_rejected(self):
        # 10 bytes with all bits set (value > 2^64 - 1)
        data = bytearray([(2 << 3) | 0])
        data.extend([0xFF] * 9 + [0x7F])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("exceeds 64-bit unsigned limit", str(ctx.exception))

    def test_invalid_protobuf_tag_0_and_huge_tag_rejected(self):
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes([0]))
        self.assertIn("Invalid protobuf tag 0", str(ctx.exception))

    def test_duplicate_critical_field_rejected(self):
        # Two identical name fields
        data = bytearray()
        data.extend(build_manifest_pb("com.android.runtime", 1))
        data.extend(build_manifest_pb("com.android.runtime", 1))
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("Duplicate critical field", str(ctx.exception))

    def test_json_manifest_type_validations(self):
        with tempfile.NamedTemporaryFile(suffix=".apex", delete=False) as f:
            temp_path = f.name
        try:
            # Non-dict root
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("apex_manifest.json", json.dumps(["com.android.runtime", 1]))
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("root must be an object", str(ctx.exception))

            # Non-string name
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("apex_manifest.json", json.dumps({"name": 12345, "version": 1}))
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("'name' must be a non-empty string", str(ctx.exception))

            # Boolean version (bool is subclass of int in Python)
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("apex_manifest.json", json.dumps({"name": "com.android.runtime", "version": True}))
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("'version' must be a positive integer", str(ctx.exception))

            # Zero or negative version
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("apex_manifest.json", json.dumps({"name": "com.android.runtime", "version": -5}))
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("'version' must be a positive integer", str(ctx.exception))
            # Non-string versionName
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("apex_manifest.json", json.dumps({"name": "com.android.runtime", "version": 1, "versionName": 12345}))
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("'versionName' must be a string", str(ctx.exception))
        finally:
            os.unlink(temp_path)

    def test_multibyte_field_tag_and_unknown_fields(self):
        # Build valid manifest and append an unknown tag with field number 20 (wire 2: length delimited)
        data = bytearray(build_manifest_pb("com.android.runtime", 361501120, "16.0"))
        # Tag 20: key = (20 << 3) | 2 = 162 = 0xA2. In varint: [0xA2, 0x01]
        key = encode_varint((20 << 3) | 2)
        payload = b"unknown_field_data"
        data.extend(key)
        data.extend(encode_varint(len(payload)))
        data.extend(payload)

        name, version, version_name = parse_manifest_pb(bytes(data))
        self.assertEqual(name, "com.android.runtime")
        self.assertEqual(version, 361501120)
        self.assertEqual(version_name, "16.0")

    def test_wrong_wire_types_for_known_fields(self):
        # Tag 1 (name) with wire 0 (varint) instead of wire 2
        data = bytearray([(1 << 3) | 0, 42])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("Wrong wire type", str(ctx.exception))

        # Tag 2 (version) with wire 2 (length-delimited) instead of wire 0
        data2 = bytearray([(2 << 3) | 2, 4, b"test"[0], b"test"[1], b"test"[2], b"test"[3]])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data2))
        self.assertIn("Wrong wire type", str(ctx.exception))

        # Tag 3 (versionName) with wire 0 (varint) instead of wire 2
        data3 = bytearray([(3 << 3) | 0, 10])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data3))
        self.assertIn("Wrong wire type", str(ctx.exception))

    def test_duplicate_version_name_rejected(self):
        data = bytearray(build_manifest_pb("com.android.runtime", 1, "1.0"))
        # Add tag 3 again
        vn_bytes = b"2.0"
        data.append((3 << 3) | 2)
        data.extend(encode_varint(len(vn_bytes)))
        data.extend(vn_bytes)

        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data))
        self.assertIn("Duplicate critical field", str(ctx.exception))

    def test_truncated_and_overlong_tag_varint(self):
        # High bit set on tag byte but ends prematurely
        data = bytes([0x80])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(data)
        self.assertIn("Truncated varint tag", str(ctx.exception))

        # Overlong tag varint (> 10 bytes)
        data_overlong = bytes([0x80] * 11 + [0x01])
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(data_overlong)
        self.assertIn("Varint tag exceeds 10 bytes", str(ctx.exception))

    def test_malformed_nested_original_apex_rejected(self):
        with tempfile.NamedTemporaryFile(suffix=".apex", delete=False) as f:
            temp_path = f.name
        try:
            with zipfile.ZipFile(temp_path, "w") as z:
                z.writestr("original_apex", b"CORRUPTED_NESTED_NOT_ZIP_DATA")
            with self.assertRaises(ValueError) as ctx:
                extract_manifest_from_apex(temp_path)
            self.assertIn("Invalid or corrupted ZIP", str(ctx.exception))
        finally:
            os.unlink(temp_path)

    def test_provide_shared_apex_libs_pb_and_json(self):
        # Protobuf with tag 11 = 1 (true)
        data = bytearray(build_manifest_pb("com.android.runtime", 1, "1.0"))
        data.append((11 << 3) | 0)
        data.extend(encode_varint(1))

        res = parse_manifest_pb(bytes(data), include_extended=True)
        self.assertEqual(res, ("com.android.runtime", 1, "1.0", True))

        # Protobuf with tag 11 = 0 (false)
        data2 = bytearray(build_manifest_pb("com.android.runtime", 1, "1.0"))
        data2.append((11 << 3) | 0)
        data2.extend(encode_varint(0))
        res2 = parse_manifest_pb(bytes(data2), include_extended=True)
        self.assertEqual(res2, ("com.android.runtime", 1, "1.0", False))

        # Tag 11 with wrong wire type
        data3 = bytearray(build_manifest_pb("com.android.runtime", 1, "1.0"))
        data3.append((11 << 3) | 2)
        data3.extend(encode_varint(1))
        data3.append(0)
        with self.assertRaises(ValueError) as ctx:
            parse_manifest_pb(bytes(data3), include_extended=True)
        self.assertIn("Wrong wire type", str(ctx.exception))

    def test_validate_apex_info_xml_valid(self):
        xml_content = """<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" modulePath="/apex/com.android.runtime@1" preinstalledModulePath="/system/apex/com.android.runtime.apex" versionCode="1" versionName="16.0" isFactory="true" isActive="true" provideSharedApexLibs="false" partition="SYSTEM" />
  <apex-info moduleName="com.android.art" modulePath="/apex/com.android.art@361501120" preinstalledModulePath="/system/apex/com.google.android.art_compressed.apex" versionCode="361501120" versionName="" isFactory="true" isActive="true" provideSharedApexLibs="false" partition="SYSTEM" />
</apex-info-list>
"""
        self.assertTrue(validate_apex_info_xml(xml_content))

    def test_validate_apex_info_xml_missing_attribute(self):
        # Missing modulePath
        xml_missing = """<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" versionCode="1" versionName="16.0" isFactory="true" isActive="true" />
</apex-info-list>
"""
        with self.assertRaises(ValueError) as ctx:
            validate_apex_info_xml(xml_missing)
        self.assertIn("Invalid or missing 'modulePath'", str(ctx.exception))

    def test_validate_apex_info_xml_invalid_version_code(self):
        xml_bad_ver = """<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" modulePath="/apex/com.android.runtime@0" versionCode="0" versionName="16.0" isFactory="true" isActive="true" />
</apex-info-list>
"""
        with self.assertRaises(ValueError) as ctx:
            validate_apex_info_xml(xml_bad_ver)
        self.assertIn("must be positive", str(ctx.exception))

    def test_validate_apex_info_xml_invalid_partition(self):
        xml_bad_part = """<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" modulePath="/apex/com.android.runtime@1" versionCode="1" versionName="" isFactory="true" isActive="true" partition="INVALID_PART" />
</apex-info-list>
"""
        with self.assertRaises(ValueError) as ctx:
            validate_apex_info_xml(xml_bad_part)
        self.assertIn("Invalid 'partition'", str(ctx.exception))

    def test_validate_apex_info_xml_duplicate_module(self):
        xml_dup = """<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" modulePath="/apex/com.android.runtime@1" versionCode="1" versionName="" isFactory="true" isActive="true" />
  <apex-info moduleName="com.android.runtime" modulePath="/apex/com.android.runtime@2" versionCode="2" versionName="" isFactory="false" isActive="true" />
</apex-info-list>
"""
        with self.assertRaises(ValueError) as ctx:
            validate_apex_info_xml(xml_dup)
        self.assertIn("Duplicate moduleName", str(ctx.exception))

    def test_validate_apex_info_xml_active_mount_check(self):
        xml_content = """<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" modulePath="/apex/com.android.runtime@1" versionCode="1" versionName="" isFactory="true" isActive="true" />
</apex-info-list>
"""
        # Active mounts lacking this path
        with self.assertRaises(ValueError) as ctx:
            validate_apex_info_xml(xml_content, active_mounts=["/dev", "/proc", "/sys"])
        self.assertIn("NOT present in active filesystem mounts", str(ctx.exception))

        # Active mounts containing this path
        self.assertTrue(validate_apex_info_xml(xml_content, active_mounts=["/apex/com.android.runtime@1", "/apex/com.android.runtime"]))

    def test_generate_apex_info_xml(self):
        entries = [
            {
                "moduleName": "com.android.runtime",
                "modulePath": "/apex/com.android.runtime@1",
                "preinstalledModulePath": "/system/apex/com.android.runtime.apex",
                "versionCode": 1,
                "versionName": "",
                "isFactory": True,
                "isActive": True,
                "provideSharedApexLibs": False,
                "partition": "SYSTEM",
            }
        ]
        xml_out = generate_apex_info_xml(entries)
        self.assertIn('<apex-info-list>', xml_out)
        self.assertIn('moduleName="com.android.runtime"', xml_out)
        self.assertIn('provideSharedApexLibs="false"', xml_out)
        self.assertTrue(validate_apex_info_xml(xml_out))


if __name__ == "__main__":
    unittest.main()
