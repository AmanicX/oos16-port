#!/usr/bin/env python3
"""
tools/extract_apex_info.py - Extract and validate APEX manifest metadata.
Target: OxygenOS 16 APEX modules on OnePlus 7T (HD1901)

Parses apex_manifest.pb (or apex_manifest.json) from APEX packages
(including compressed APEX archives containing original_apex).
Extracts canonical package name and version code without silent fallback.
"""

import argparse
import io
import json
import os
import sys
import zipfile


def parse_manifest_pb(data: bytes):
    """
    Parses AOSP apex_manifest.pb protobuf payload.
    Fields:
      1 (length-delimited): string name
      2 (varint): int64 version
      3 (length-delimited): string versionName
    """
    idx = 0
    name = None
    version = None
    version_name = None

    while idx < len(data):
        tag_wire = data[idx]
        tag = tag_wire >> 3
        wire = tag_wire & 7
        idx += 1

        if wire == 0:  # varint
            val = 0
            shift = 0
            while idx < len(data):
                b = data[idx]
                idx += 1
                val |= (b & 0x7F) << shift
                shift += 7
                if (b & 0x80) == 0:
                    break
            if tag == 2:
                version = val
        elif wire == 2:  # length-delimited
            length = 0
            shift = 0
            while idx < len(data):
                b = data[idx]
                idx += 1
                length |= (b & 0x7F) << shift
                shift += 7
                if (b & 0x80) == 0:
                    break
            chunk = data[idx : idx + length]
            idx += length
            if tag == 1:
                name = chunk.decode("utf-8", "replace")
            elif tag == 3:
                version_name = chunk.decode("utf-8", "replace")
        elif wire == 1:  # 64-bit
            idx += 8
        elif wire == 5:  # 32-bit
            idx += 4
        else:
            break

    return name, version, version_name


def extract_manifest_from_apex(apex_path: str):
    if not os.path.isfile(apex_path):
        raise FileNotFoundError(f"APEX archive not found: {apex_path}")

    with zipfile.ZipFile(apex_path, "r") as z:
        # 1. Direct protobuf manifest
        if "apex_manifest.pb" in z.namelist():
            pb_data = z.read("apex_manifest.pb")
            name, version, version_name = parse_manifest_pb(pb_data)
            if name and version is not None:
                return name, version, version_name or ""

        # 2. Direct JSON manifest
        if "apex_manifest.json" in z.namelist():
            j_data = json.loads(z.read("apex_manifest.json").decode("utf-8"))
            return j_data.get("name"), j_data.get("version"), j_data.get("versionName", "")

        # 3. Compressed APEX wrapping original_apex
        if "original_apex" in z.namelist():
            with zipfile.ZipFile(io.BytesIO(z.read("original_apex")), "r") as oz:
                if "apex_manifest.pb" in oz.namelist():
                    name, version, version_name = parse_manifest_pb(oz.read("apex_manifest.pb"))
                    if name and version is not None:
                        return name, version, version_name or ""
                if "apex_manifest.json" in oz.namelist():
                    j_data = json.loads(oz.read("apex_manifest.json").decode("utf-8"))
                    return j_data.get("name"), j_data.get("version"), j_data.get("versionName", "")

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
