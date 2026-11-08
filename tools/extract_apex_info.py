#!/usr/bin/env python3
"""
tools/extract_apex_info.py - Extract and validate APEX manifest metadata.
Target: OxygenOS 16 APEX modules on OnePlus 7T (HD1901)

Parses apex_manifest.pb (or apex_manifest.json) from APEX packages
(including compressed APEX archives containing original_apex).
Strictly validates protobuf tags, wire types, lengths, UTF-8 strings,
and package identifiers without silent fallback or error suppression.
Generates and validates AOSP-compliant apex-info-list.xml according to
Android 16 ApexInfoList.xsd schema.
"""

import argparse
import io
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib

MAX_VARINT_64 = (1 << 64) - 1
MAX_APEX_FILE_SIZE = 500 * 1024 * 1024       # 500 MB archive limit
MAX_ZIP_ENTRIES = 1000                       # Max directory members
MAX_MANIFEST_BYTES = 10 * 1024 * 1024        # 10 MB manifest limit
MAX_ORIGINAL_APEX_BYTES = 500 * 1024 * 1024  # 500 MB nested payload limit

VALID_PARTITIONS = {"SYSTEM", "SYSTEM_EXT", "PRODUCT", "VENDOR", "ODM"}
ALLOWED_APEX_INFO_ATTRIBUTES = {
    "moduleName",
    "modulePath",
    "preinstalledModulePath",
    "versionCode",
    "versionName",
    "isFactory",
    "isActive",
    "provideSharedApexLibs",
    "partition",
    "lastUpdateMillis",
}


def parse_manifest_pb(data: bytes, include_extended: bool = False):
    """
    Parses AOSP apex_manifest.pb protobuf payload with strict validation.
    Fields:
      1 (length-delimited): string name
      2 (varint): int64 version
      3 (length-delimited): string versionName
      11 (varint): bool provideSharedApexLibs
    """
    if not data:
        raise ValueError("Protobuf manifest payload is empty")

    idx = 0
    name = None
    version = None
    version_name = None
    provide_shared_apex_libs = False
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
        if tag == 11 and wire != 0:
            raise ValueError(f"Wrong wire type {wire} for provideSharedApexLibs tag {tag} (expected wire 0)")

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
            elif tag == 11:  # provideSharedApexLibs
                if tag in seen_tags:
                    raise ValueError(f"Conflicting duplicate or Duplicate critical field encountered: provideSharedApexLibs (tag {tag})")
                seen_tags.add(tag)
                provide_shared_apex_libs = (val != 0)

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

    if include_extended:
        return name, version, version_name, provide_shared_apex_libs
    return name, version, version_name


def validate_package_name(name: str):
    if not name or not isinstance(name, str):
        raise ValueError("Package name is empty or not a string")
    if not re.match(r"^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$", name):
        raise ValueError(f"Package name '{name}' is not a valid Java/AOSP package identifier")


def _validate_json_manifest(j_bytes: bytes, include_extended: bool = False):
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

    provide_shared_apex_libs = bool(j_data.get("provideSharedApexLibs", False))

    validate_package_name(name)
    if include_extended:
        return name, version, version_name, provide_shared_apex_libs
    return name, version, version_name


def extract_manifest_from_apex(apex_path: str, include_extended: bool = False):
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
                res = parse_manifest_pb(pb_data, include_extended=include_extended)
                name, version, version_name = res[0], res[1], res[2]
                if name and version is not None:
                    if version <= 0:
                        raise ValueError(f"Version code must be positive, got {version}")
                    validate_package_name(name)
                    if include_extended:
                        return name, version, version_name or "", res[3]
                    return name, version, version_name or ""

            # 2. Direct JSON manifest
            if "apex_manifest.json" in namelist:
                info = z.getinfo("apex_manifest.json")
                if info.file_size > MAX_MANIFEST_BYTES:
                    raise ValueError(f"apex_manifest.json exceeds size limit ({info.file_size} > {MAX_MANIFEST_BYTES})")
                j_bytes = z.read("apex_manifest.json")
                return _validate_json_manifest(j_bytes, include_extended=include_extended)

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
                        res = parse_manifest_pb(oz.read("apex_manifest.pb"), include_extended=include_extended)
                        name, version, version_name = res[0], res[1], res[2]
                        if name and version is not None:
                            if version <= 0:
                                raise ValueError(f"Version code must be positive, got {version}")
                            validate_package_name(name)
                            if include_extended:
                                return name, version, version_name or "", res[3]
                            return name, version, version_name or ""

                    if "apex_manifest.json" in orig_namelist:
                        oinfo = oz.getinfo("apex_manifest.json")
                        if oinfo.file_size > MAX_MANIFEST_BYTES:
                            raise ValueError("Nested apex_manifest.json exceeds size limit")
                        return _validate_json_manifest(oz.read("apex_manifest.json"), include_extended=include_extended)

    except (zipfile.BadZipFile, zlib.error) as e:
        raise ValueError(f"Invalid or corrupted ZIP archive in {apex_path}: {e}")

    raise ValueError(f"No valid apex_manifest.pb or apex_manifest.json found in {apex_path}")


def get_apex_manifest_info(apex_path: str) -> dict:
    """Returns complete dictionary of APEX manifest metadata."""
    name, version, version_name, provide_shared_apex_libs = extract_manifest_from_apex(apex_path, include_extended=True)
    return {
        "package": name,
        "version": version,
        "versionName": version_name,
        "provideSharedApexLibs": provide_shared_apex_libs,
    }


def validate_apex_info_xml(xml_source: str, active_mounts=None):
    """
    Strictly validates apex-info-list.xml against Android 16 ApexInfoList.xsd schema.
    xml_source: file path or XML string.
    active_mounts: iterable of active mountpoints, or path to /proc/mounts.
    """
    if os.path.isfile(xml_source):
        with open(xml_source, "r", encoding="utf-8") as f:
            xml_text = f.read()
    else:
        xml_text = xml_source

    if not xml_text or not xml_text.strip():
        raise ValueError("APEX info XML content is empty")

    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as e:
        raise ValueError(f"Malformed XML syntax in apex-info-list: {e}")

    # Strip XML namespace if present
    root_tag = root.tag.split("}")[-1] if "}" in root.tag else root.tag
    if root_tag != "apex-info-list":
        raise ValueError(f"Invalid root XML element '{root.tag}' (expected 'apex-info-list')")

    if root.attrib:
        raise ValueError(f"Disallowed attributes on apex-info-list root element: {list(root.attrib.keys())}")

    active_mount_set = None
    if active_mounts:
        if isinstance(active_mounts, str) and os.path.isfile(active_mounts):
            active_mount_set = set()
            with open(active_mounts, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        active_mount_set.add(parts[1])
        else:
            active_mount_set = set(active_mounts)

    seen_modules = set()
    children = list(root)
    if not children:
        raise ValueError("apex-info-list has no apex-info child elements")

    for idx, child in enumerate(children):
        tag = child.tag.split("}")[-1] if "}" in child.tag else child.tag
        if tag != "apex-info":
            raise ValueError(f"Disallowed child element '{child.tag}' at index {idx} (expected 'apex-info')")

        attribs = child.attrib
        unknown_attrs = set(attribs.keys()) - ALLOWED_APEX_INFO_ATTRIBUTES
        if unknown_attrs:
            raise ValueError(f"Disallowed attributes {list(unknown_attrs)} on apex-info at index {idx}")

        # Required: moduleName
        module_name = attribs.get("moduleName")
        if not module_name:
            raise ValueError(f"Missing required attribute 'moduleName' on apex-info at index {idx}")
        validate_package_name(module_name)
        if module_name in seen_modules:
            raise ValueError(f"Duplicate moduleName '{module_name}' in apex-info-list")
        seen_modules.add(module_name)

        # Required: modulePath
        module_path = attribs.get("modulePath")
        if not module_path or not module_path.startswith("/"):
            raise ValueError(f"Invalid or missing 'modulePath' ('{module_path}') on module '{module_name}' (must be absolute path)")

        # Optional: preinstalledModulePath
        preinstalled_path = attribs.get("preinstalledModulePath")
        if preinstalled_path is not None and not preinstalled_path.startswith("/"):
            raise ValueError(f"Invalid 'preinstalledModulePath' ('{preinstalled_path}') on module '{module_name}' (must be absolute path)")

        # Required: versionCode (xs:long, positive)
        ver_str = attribs.get("versionCode")
        if ver_str is None or not re.match(r"^[0-9]+$", ver_str):
            raise ValueError(f"Invalid or missing 'versionCode' ('{ver_str}') on module '{module_name}' (must be positive integer)")
        ver_int = int(ver_str)
        if ver_int <= 0:
            raise ValueError(f"versionCode on module '{module_name}' must be positive, got {ver_int}")

        # Required: versionName
        ver_name = attribs.get("versionName")
        if ver_name is None:
            raise ValueError(f"Missing required attribute 'versionName' on module '{module_name}'")

        # Required: isFactory
        is_factory = attribs.get("isFactory")
        if is_factory not in ("true", "false"):
            raise ValueError(f"Invalid or missing 'isFactory' ('{is_factory}') on module '{module_name}' (must be 'true' or 'false')")

        # Required: isActive
        is_active = attribs.get("isActive")
        if is_active not in ("true", "false"):
            raise ValueError(f"Invalid or missing 'isActive' ('{is_active}') on module '{module_name}' (must be 'true' or 'false')")

        # Optional: provideSharedApexLibs
        shared_libs = attribs.get("provideSharedApexLibs")
        if shared_libs is not None and shared_libs not in ("true", "false"):
            raise ValueError(f"Invalid 'provideSharedApexLibs' ('{shared_libs}') on module '{module_name}' (must be 'true' or 'false')")

        # Optional: partition
        partition = attribs.get("partition")
        if partition is not None and partition not in VALID_PARTITIONS:
            raise ValueError(f"Invalid 'partition' ('{partition}') on module '{module_name}' (must be one of {sorted(VALID_PARTITIONS)})")

        # Optional: lastUpdateMillis
        last_update = attribs.get("lastUpdateMillis")
        if last_update is not None:
            if not re.match(r"^[0-9]+$", last_update):
                raise ValueError(f"Invalid 'lastUpdateMillis' ('{last_update}') on module '{module_name}' (must be non-negative integer)")

        # Active mount verification
        if active_mount_set is not None and is_active == "true":
            # An active APEX must be mounted at modulePath or /apex/${moduleName}
            canonical_active = f"/apex/{module_name}"
            # Account for sysroot prefix if mounts are recorded from root namespace
            found = False
            for cand in [module_path, canonical_active, f"/mnt/sysroot{module_path}", f"/mnt/sysroot{canonical_active}"]:
                if cand in active_mount_set:
                    found = True
                    break
            if not found:
                raise ValueError(
                    f"Active APEX '{module_name}' (path: '{module_path}') is NOT present in active filesystem mounts!"
                )

    return True


def generate_apex_info_xml(entries: list, output_path: str = None) -> str:
    """
    Generates AOSP-compliant apex-info-list.xml from list of APEX entry dicts.
    Validates generated XML against validate_apex_info_xml before returning or saving.
    """
    root = ET.Element("apex-info-list")
    for entry in entries:
        elem = ET.SubElement(root, "apex-info")
        # Write attributes in canonical order
        for attr in [
            "moduleName",
            "modulePath",
            "preinstalledModulePath",
            "versionCode",
            "versionName",
            "isFactory",
            "isActive",
            "provideSharedApexLibs",
            "partition",
            "lastUpdateMillis",
        ]:
            if attr in entry and entry[attr] is not None:
                val = entry[attr]
                if isinstance(val, bool):
                    elem.set(attr, "true" if val else "false")
                else:
                    elem.set(attr, str(val))

    ET.indent(root, space="  ")
    xml_str = '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding="utf-8").decode("utf-8") + "\n"

    # Validate generated XML
    validate_apex_info_xml(xml_str)

    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(xml_str)

    return xml_str


def main():
    parser = argparse.ArgumentParser(description="Extract and validate APEX manifest metadata.")
    parser.add_argument("--apex", help="Path to input .apex file")
    parser.add_argument("--expect-package", help="Expected package name (e.g. com.android.runtime)")
    parser.add_argument("--version-only", action="store_true", help="Print only version code to stdout")
    parser.add_argument("--name-only", action="store_true", help="Print only package name to stdout")
    parser.add_argument("--all-meta", action="store_true", help="Print all metadata to stdout")
    parser.add_argument("--json", action="store_true", help="Output metadata as JSON")
    parser.add_argument("--output-version", help="Path to write version string")
    parser.add_argument("--output-name", help="Path to write package name string")
    parser.add_argument("--output-version-name", help="Path to write versionName string")
    parser.add_argument("--output-shared-libs", help="Path to write provideSharedApexLibs ('true'/'false')")
    parser.add_argument("--validate-xml", help="Path to apex-info-list.xml to validate")
    parser.add_argument("--active-mounts", help="Comma-separated list of active mountpoints")
    parser.add_argument("--active-mounts-from", help="File containing active mounts (e.g. /proc/mounts)")
    parser.add_argument("--generate-xml", help="Generate apex-info-list.xml at path")
    parser.add_argument("--xml-spec", help="JSON string or file containing array of apex-info entry dicts")

    args = parser.parse_args()

    # Mode 1: Validate XML
    if args.validate_xml:
        mounts = None
        if args.active_mounts_from:
            mounts = args.active_mounts_from
        elif args.active_mounts:
            mounts = [m.strip() for m in args.active_mounts.split(",") if m.strip()]
        try:
            validate_apex_info_xml(args.validate_xml, active_mounts=mounts)
            print(f"APEX XML validation passed: {args.validate_xml} is strictly compliant with ApexInfoList.xsd")
            sys.exit(0)
        except Exception as e:
            sys.stderr.write(f"ERROR: APEX XML validation failed for {args.validate_xml}: {e}\n")
            sys.exit(1)

    # Mode 2: Generate XML
    if args.generate_xml:
        if not args.xml_spec:
            sys.stderr.write("ERROR: --xml-spec is required when using --generate-xml\n")
            sys.exit(1)
        try:
            if os.path.isfile(args.xml_spec):
                with open(args.xml_spec, "r", encoding="utf-8") as f:
                    spec_data = json.load(f)
            else:
                spec_data = json.loads(args.xml_spec)
            if not isinstance(spec_data, list):
                raise ValueError("XML spec must be a list of entry objects")
            generate_apex_info_xml(spec_data, output_path=args.generate_xml)
            print(f"Generated {args.generate_xml} successfully.")
            sys.exit(0)
        except Exception as e:
            sys.stderr.write(f"ERROR: Failed to generate {args.generate_xml}: {e}\n")
            sys.exit(1)

    # Mode 3: APEX Manifest Extraction
    if not args.apex:
        sys.stderr.write("ERROR: --apex is required when not using --validate-xml or --generate-xml\n")
        sys.exit(1)

    try:
        name, version, version_name, provide_shared_libs = extract_manifest_from_apex(args.apex, include_extended=True)
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

    if args.output_version_name:
        with open(args.output_version_name, "w") as f:
            f.write(f"{version_name}\n")

    if args.output_shared_libs:
        with open(args.output_shared_libs, "w") as f:
            f.write("true\n" if provide_shared_libs else "false\n")

    if args.version_only:
        print(version)
    elif args.name_only:
        print(name)
    elif args.all_meta:
        print(f"Package: {name}")
        print(f"Version: {version}")
        print(f"VersionName: {version_name}")
        print(f"ProvideSharedApexLibs: {'true' if provide_shared_libs else 'false'}")
    elif args.json:
        print(json.dumps({
            "package": name,
            "version": version,
            "versionName": version_name,
            "provideSharedApexLibs": provide_shared_libs,
        }, indent=2))
    else:
        print(f"Package: {name}")
        print(f"Version: {version}")
        print(f"VersionName: {version_name}")

    sys.exit(0)


if __name__ == "__main__":
    main()
