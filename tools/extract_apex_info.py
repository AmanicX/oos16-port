#!/usr/bin/env python3
"""
tools/extract_apex_info.py - Extract and validate APEX manifest metadata.
Target: OxygenOS 16 APEX modules on OnePlus 7T (HD1901)

Parses apex_manifest.pb (or apex_manifest.json) from APEX packages
(including compressed APEX archives containing original_apex).
Strictly validates protobuf tags, wire types, lengths, UTF-8 strings,
and package identifiers without silent fallback or error suppression.
"""

import argparse
import io
import json
import os
import re
import sys
import zipfile
import zlib

MAX_VARINT_64 = (1 << 64) - 1
MAX_APEX_FILE_SIZE = 500 * 1024 * 1024       # 500 MB archive limit
MAX_ZIP_ENTRIES = 1000                       # Max directory members
MAX_MANIFEST_BYTES = 10 * 1024 * 1024        # 10 MB manifest limit
MAX_ORIGINAL_APEX_BYTES = 500 * 1024 * 1024  # 500 MB nested payload limit


def parse_manifest_pb(data: bytes):
    """
    Parses AOSP apex_manifest.pb protobuf payload with strict validation.
    Fields:
      1 (length-delimited): string name
      2 (varint): int64 version
      3 (length-delimited): string versionName
    """
    if not data:
        raise ValueError("Protobuf manifest payload is empty")

    idx = 0
    name = None
    version = None
    version_name = None
    seen_tags = set()

    while idx < len(data):
        # Decode protobuf field tag key (varint: tag << 3 | wire)
        key = 0
        shift = 0
        varint_bytes = 0
        found_end = False
        while idx < len(data):
            b = data[idx]
            idx += 1
            varint_bytes += 1
            key |= (b & 0x7F) << shift
            shift += 7
            if (b & 0x80) == 0:
                found_end = True
                break
            if varint_bytes > 10:
                raise ValueError("Varint tag exceeds 10 bytes (malformed)")
        if not found_end:
            raise ValueError("Truncated varint tag in protobuf data")

        tag = key >> 3
        wire = key & 7

        if tag == 0 or tag > 536870911:
            raise ValueError(f"Invalid protobuf tag {tag}")

        # Only standard proto3 wire types allowed: 0 (varint), 1 (64-bit), 2 (length-delimited), 5 (32-bit)
        if wire not in (0, 1, 2, 5):
            raise ValueError(f"Unsupported or malformed protobuf wire type {wire} for tag {tag}")

        # Validate expected wire types for known manifest fields
        if tag == 1 and wire != 2:
            raise ValueError(f"Wrong wire type {wire} for package name tag {tag} (expected wire 2)")
        if tag == 2 and wire != 0:
            raise ValueError(f"Wrong wire type {wire} for version tag {tag} (expected wire 0)")
        if tag == 3 and wire != 2:
            raise ValueError(f"Wrong wire type {wire} for versionName tag {tag} (expected wire 2)")

        if wire == 0:  # varint
            val = 0
            shift = 0
            varint_bytes = 0
            found_end = False
            while idx < len(data):
                b = data[idx]
                idx += 1
                varint_bytes += 1
                val |= (b & 0x7F) << shift
                shift += 7
                if (b & 0x80) == 0:
                    found_end = True
                    break
                if varint_bytes > 10:
                    raise ValueError(f"Varint exceeds 10 bytes (malformed) for tag {tag}")
            if not found_end:
                raise ValueError(f"Truncated varint in protobuf data for tag {tag}")

            if val > MAX_VARINT_64:
                raise ValueError(f"Varint value exceeds 64-bit unsigned limit for tag {tag}")

            if tag == 2:  # version
                if tag in seen_tags:
                    raise ValueError(f"Conflicting duplicate or Duplicate critical field encountered: version (tag {tag})")
                seen_tags.add(tag)
                version = val

        elif wire == 2:  # length-delimited
            length = 0
            shift = 0
            varint_bytes = 0
            found_end = False
            while idx < len(data):
                b = data[idx]
                idx += 1
                varint_bytes += 1
                length |= (b & 0x7F) << shift
                shift += 7
                if (b & 0x80) == 0:
                    found_end = True
                    break
                if varint_bytes > 10:
                    raise ValueError(f"Varint length exceeds 10 bytes (malformed) for tag {tag}")
            if not found_end:
                raise ValueError(f"Truncated varint length for tag {tag}")

            if length > MAX_VARINT_64:
                raise ValueError(f"Length field exceeds 64-bit unsigned limit for tag {tag}")

            if length < 0 or idx + length > len(data):
                raise ValueError(
                    f"Protobuf length-delimited field exceeds remaining data: {length} > {len(data) - idx} (tag {tag})"
                )

            chunk = data[idx : idx + length]
            idx += length

            if tag == 1:  # name
                try:
                    decoded_name = chunk.decode("utf-8")  # strict mode, no replace!
                except UnicodeDecodeError as e:
                    raise ValueError(f"Malformed UTF-8 in package name for tag {tag}: {e}")
                if tag in seen_tags:
                    raise ValueError(f"Conflicting duplicate or Duplicate critical field encountered: package name (tag {tag})")
                seen_tags.add(tag)
                name = decoded_name

            elif tag == 3:  # versionName
                try:
                    decoded_version_name = chunk.decode("utf-8")
                except UnicodeDecodeError as e:
                    raise ValueError(f"Malformed UTF-8 in versionName for tag {tag}: {e}")
                if tag in seen_tags:
                    raise ValueError(f"Conflicting duplicate or Duplicate critical field encountered: versionName (tag {tag})")
                seen_tags.add(tag)
                version_name = decoded_version_name

        elif wire == 1:  # 64-bit
            if idx + 8 > len(data):
                raise ValueError(f"Truncated 64-bit field for tag {tag}")
            idx += 8

        elif wire == 5:  # 32-bit
            if idx + 4 > len(data):
                raise ValueError(f"Truncated 32-bit field for tag {tag}")
            idx += 4

    return name, version, version_name


def validate_package_name(name: str):
    if not name or not isinstance(name, str):
        raise ValueError("Package name is empty or not a string")
    if not re.match(r"^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$", name):
        raise ValueError(f"Package name '{name}' is not a valid Java/AOSP package identifier")


def _validate_json_manifest(j_bytes: bytes):
    try:
        j_str = j_bytes.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ValueError(f"Malformed UTF-8 in JSON manifest: {e}")
    try:
        j_data = json.loads(j_str)
    except json.JSONDecodeError as e:
        raise ValueError(f"Malformed JSON syntax in manifest: {e}")

    if not isinstance(j_data, dict):
        raise ValueError("JSON manifest root must be an object")

    name = j_data.get("name")
    version = j_data.get("version")
    if name is None or not isinstance(name, str) or not name.strip():
        raise ValueError("JSON manifest 'name' must be a non-empty string")
    if version is None or isinstance(version, bool) or not isinstance(version, int) or version <= 0:
        raise ValueError(f"JSON manifest 'version' must be a positive integer, got: {version}")

    version_name = j_data.get("versionName", "")
    if version_name is not None and not isinstance(version_name, str):
        raise ValueError(f"JSON manifest 'versionName' must be a string, got: {type(version_name).__name__}")
    if version_name is None:
        version_name = ""

    validate_package_name(name)
    return name, version, version_name


def extract_manifest_from_apex(apex_path: str):
    if not os.path.isfile(apex_path):
        raise FileNotFoundError(f"APEX archive not found: {apex_path}")

    file_size = os.path.getsize(apex_path)
    if file_size > MAX_APEX_FILE_SIZE:
        raise ValueError(f"APEX archive exceeds maximum size limit ({file_size} > {MAX_APEX_FILE_SIZE} bytes)")

    try:
        with zipfile.ZipFile(apex_path, "r") as z:
            namelist = z.namelist()
            if len(namelist) > MAX_ZIP_ENTRIES:
                raise ValueError(f"APEX archive entry count exceeds limit ({len(namelist)} > {MAX_ZIP_ENTRIES})")
            if len(namelist) != len(set(namelist)):
                raise ValueError("Suspicious duplicate directory entries detected in APEX archive")

            # 1. Direct protobuf manifest
            if "apex_manifest.pb" in namelist:
                info = z.getinfo("apex_manifest.pb")
                if info.file_size > MAX_MANIFEST_BYTES:
                    raise ValueError(f"apex_manifest.pb exceeds size limit ({info.file_size} > {MAX_MANIFEST_BYTES})")
                pb_data = z.read("apex_manifest.pb")
                name, version, version_name = parse_manifest_pb(pb_data)
                if name and version is not None:
                    if version <= 0:
                        raise ValueError(f"Version code must be positive, got {version}")
                    validate_package_name(name)
                    return name, version, version_name or ""

            # 2. Direct JSON manifest
            if "apex_manifest.json" in namelist:
                info = z.getinfo("apex_manifest.json")
                if info.file_size > MAX_MANIFEST_BYTES:
                    raise ValueError(f"apex_manifest.json exceeds size limit ({info.file_size} > {MAX_MANIFEST_BYTES})")
                j_bytes = z.read("apex_manifest.json")
                return _validate_json_manifest(j_bytes)

            # 3. Compressed APEX wrapping original_apex
            if "original_apex" in namelist:
                info = z.getinfo("original_apex")
                if info.file_size > MAX_ORIGINAL_APEX_BYTES:
                    raise ValueError(f"original_apex exceeds size limit ({info.file_size} > {MAX_ORIGINAL_APEX_BYTES})")
                orig_bytes = z.read("original_apex")
                with zipfile.ZipFile(io.BytesIO(orig_bytes), "r") as oz:
                    orig_namelist = oz.namelist()
                    if len(orig_namelist) > MAX_ZIP_ENTRIES:
                        raise ValueError("Nested original_apex contains excessive entries")
                    if len(orig_namelist) != len(set(orig_namelist)):
                        raise ValueError("Suspicious duplicate entries detected in nested original_apex")

                    if "apex_manifest.pb" in orig_namelist:
                        oinfo = oz.getinfo("apex_manifest.pb")
                        if oinfo.file_size > MAX_MANIFEST_BYTES:
                            raise ValueError(f"Nested apex_manifest.pb exceeds size limit")
                        name, version, version_name = parse_manifest_pb(oz.read("apex_manifest.pb"))
                        if name and version is not None:
                            if version <= 0:
                                raise ValueError(f"Version code must be positive, got {version}")
                            validate_package_name(name)
                            return name, version, version_name or ""

                    if "apex_manifest.json" in orig_namelist:
                        oinfo = oz.getinfo("apex_manifest.json")
                        if oinfo.file_size > MAX_MANIFEST_BYTES:
                            raise ValueError("Nested apex_manifest.json exceeds size limit")
                        return _validate_json_manifest(oz.read("apex_manifest.json"))

    except (zipfile.BadZipFile, zlib.error) as e:
        raise ValueError(f"Invalid or corrupted ZIP archive in {apex_path}: {e}")

    raise ValueError(f"No valid apex_manifest.pb or apex_manifest.json found in {apex_path}")


def main():
    parser = argparse.ArgumentParser(description="Extract and validate APEX manifest metadata.")
    parser.add_argument("--apex", required=True, help="Path to input .apex file")
    parser.add_argument("--expect-package", help="Expected package name (e.g. com.android.runtime)")
    parser.add_argument("--version-only", action="store_true", help="Print only version code to stdout")
    parser.add_argument("--name-only", action="store_true", help="Print only package name to stdout")
    parser.add_argument("--json", action="store_true", help="Output metadata as JSON")
    parser.add_argument("--output-version", help="Path to write version string")
    parser.add_argument("--output-name", help="Path to write package name string")

    args = parser.parse_args()

    try:
        name, version, version_name = extract_manifest_from_apex(args.apex)
    except Exception as e:
        sys.stderr.write(f"ERROR: Failed to extract manifest from {args.apex}: {e}\n")
        sys.exit(1)

    if not name:
        sys.stderr.write(f"ERROR: Extracted package name is empty in {args.apex}!\n")
        sys.exit(1)

    if version is None or version <= 0:
        sys.stderr.write(f"ERROR: Extracted invalid version '{version}' (must be positive integer) in {args.apex}!\n")
        sys.exit(1)

    if args.expect_package:
        # Allow exact match or canonical AOSP / Google variant match
        expected = args.expect_package
        expected_norm = expected.replace("com.google.android.", "com.android.")
        actual_norm = name.replace("com.google.android.", "com.android.")

        if name != expected and actual_norm != expected_norm:
            sys.stderr.write(
                f"ERROR: Package name mismatch! Expected '{expected}' (or '{expected_norm}'), got '{name}'\n"
            )
            sys.exit(1)

    if args.output_version:
        with open(args.output_version, "w") as f:
            f.write(f"{version}\n")

    if args.output_name:
        with open(args.output_name, "w") as f:
            f.write(f"{name}\n")

    if args.version_only:
        print(version)
    elif args.name_only:
        print(name)
    elif args.json:
        print(json.dumps({"package": name, "version": version, "versionName": version_name}, indent=2))
    else:
        print(f"Package: {name}")
        print(f"Version: {version}")
        print(f"VersionName: {version_name}")

    sys.exit(0)


if __name__ == "__main__":
    main()
