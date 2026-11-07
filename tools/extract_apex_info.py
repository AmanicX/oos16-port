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
    seen_tags = {}

    while idx < len(data):
        tag_wire = data[idx]
        idx += 1
        tag = tag_wire >> 3
        wire = tag_wire & 7

        if tag == 0:
            raise ValueError("Invalid protobuf tag 0")

        # Only standard proto3 wire types allowed: 0 (varint), 1 (64-bit), 2 (length-delimited), 5 (32-bit)
        if wire not in (0, 1, 2, 5):
            raise ValueError(f"Unsupported or malformed protobuf wire type {wire} for tag {tag}")

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

            if tag == 2:  # version
                if tag in seen_tags and seen_tags[tag] != val:
                    raise ValueError(f"Conflicting duplicate version field: {seen_tags[tag]} vs {val}")
                seen_tags[tag] = val
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
                if tag in seen_tags and seen_tags[tag] != decoded_name:
                    raise ValueError(f"Conflicting duplicate package name field: '{seen_tags[tag]}' vs '{decoded_name}'")
                seen_tags[tag] = decoded_name
                name = decoded_name

            elif tag == 3:  # versionName
                try:
                    version_name = chunk.decode("utf-8")
                except UnicodeDecodeError as e:
                    raise ValueError(f"Malformed UTF-8 in versionName for tag {tag}: {e}")

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


def extract_manifest_from_apex(apex_path: str):
    if not os.path.isfile(apex_path):
        raise FileNotFoundError(f"APEX archive not found: {apex_path}")

    try:
        with zipfile.ZipFile(apex_path, "r") as z:
            # 1. Direct protobuf manifest
            if "apex_manifest.pb" in z.namelist():
                pb_data = z.read("apex_manifest.pb")
                name, version, version_name = parse_manifest_pb(pb_data)
                if name and version is not None:
                    validate_package_name(name)
                    return name, version, version_name or ""

            # 2. Direct JSON manifest
            if "apex_manifest.json" in z.namelist():
                j_bytes = z.read("apex_manifest.json")
                try:
                    j_str = j_bytes.decode("utf-8")
                except UnicodeDecodeError as e:
                    raise ValueError(f"Malformed UTF-8 in apex_manifest.json: {e}")
                j_data = json.loads(j_str)
                name = j_data.get("name")
                version = j_data.get("version")
                if name and version is not None:
                    validate_package_name(name)
                    return name, version, j_data.get("versionName", "")

            # 3. Compressed APEX wrapping original_apex
            if "original_apex" in z.namelist():
                orig_bytes = z.read("original_apex")
                with zipfile.ZipFile(io.BytesIO(orig_bytes), "r") as oz:
                    if "apex_manifest.pb" in oz.namelist():
                        name, version, version_name = parse_manifest_pb(oz.read("apex_manifest.pb"))
                        if name and version is not None:
                            validate_package_name(name)
                            return name, version, version_name or ""
                    if "apex_manifest.json" in oz.namelist():
                        try:
                            j_str = oz.read("apex_manifest.json").decode("utf-8")
                        except UnicodeDecodeError as e:
                            raise ValueError(f"Malformed UTF-8 in nested apex_manifest.json: {e}")
                        j_data = json.loads(j_str)
                        name = j_data.get("name")
                        version = j_data.get("version")
                        if name and version is not None:
                            validate_package_name(name)
                            return name, version, j_data.get("versionName", "")
    except zipfile.BadZipFile as e:
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
