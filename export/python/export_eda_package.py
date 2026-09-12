#!/usr/bin/env python3
"""Collect EDA adapter output into a portable, offline DSNCheck package.

This is an export-layer orchestrator, not a DSN parser. An EDA-specific
adapter (for example Capture Tcl/Dbo) first writes an export directory; this
tool copies the supported artifacts, records SHA-256 hashes and capabilities,
and deliberately excludes Cadence DRC reports.
"""

from __future__ import print_function

import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone


EXCLUDED_DIRS = {"native_drc", "drc", "__pycache__"}
EXCLUDED_SUFFIXES = (".drc", ".drc.log")
KNOWN_ROOTS = ("native", "dbo", "netlist")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def is_excluded(relative_path):
    parts = relative_path.replace("\\", "/").split("/")
    if any(part.lower() in EXCLUDED_DIRS for part in parts[:-1]):
        return True
    return parts[-1].lower().endswith(EXCLUDED_SUFFIXES)


def iter_files(root):
    for current, directories, files in os.walk(root):
        directories[:] = sorted(d for d in directories if d.lower() not in EXCLUDED_DIRS)
        for name in sorted(files):
            absolute = os.path.join(current, name)
            relative = os.path.relpath(absolute, root)
            if not is_excluded(relative):
                yield relative, absolute


def copy_exports(source, target):
    copied = []
    excluded = []
    for relative, absolute in iter_files(source):
        if is_excluded(relative):
            excluded.append(relative)
            continue
        destination = os.path.join(target, relative)
        parent = os.path.dirname(destination)
        if not os.path.isdir(parent):
            os.makedirs(parent)
        shutil.copy2(absolute, destination)
        copied.append({
            "path": relative.replace("\\", "/"),
            "size": os.path.getsize(destination),
            "sha256": sha256_file(destination),
        })
    return copied, excluded


def detect_capabilities(files):
    paths = {item["path"] for item in files}
    return {
        "iscf": "native/design.iscf" in paths,
        "dbo_objects": "dbo/objects.jsonl" in paths,
        "dbo_properties": "dbo/properties.jsonl" in paths,
        "logical_netlist": any(path.startswith("netlist/") and path.endswith(".jsonl") for path in paths),
        "pspice_netlist": any(path.lower().endswith(".cir") for path in paths),
        "pcb_netlist": any(os.path.basename(path).lower() in ("pstxnet.dat", "pstxprt.dat", "pstchip.dat") for path in paths),
        "geometry": "dbo/objects.jsonl" in paths,
        "cadence_drc": False,
    }


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Collect EDA export files into an offline DSNCheck package")
    parser.add_argument("input", help="EDA adapter export directory")
    parser.add_argument("-o", "--output", help="output package directory; default: <input>_package")
    parser.add_argument("--eda", default="unknown", help="source EDA name, e.g. cadence_capture, kicad, altium")
    parser.add_argument("--format", dest="source_format", default="adapter_export", help="source adapter/export format")
    parser.add_argument("--overwrite", action="store_true", help="allow replacing files in an existing output directory")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv or sys.argv[1:])
    source = os.path.abspath(args.input)
    if not os.path.isdir(source):
        raise RuntimeError("Input export directory was not found: %s" % source)
    output = os.path.abspath(args.output or source.rstrip("\\/") + "_package")
    if os.path.exists(output) and not args.overwrite:
        existing = os.listdir(output)
        if existing:
            raise RuntimeError("Output directory is not empty; use --overwrite: %s" % output)
    if not os.path.isdir(output):
        os.makedirs(output)

    files, excluded = copy_exports(source, output)
    manifest = {
        "schema_version": "1.0",
        "package_type": "DSNCheck offline export package",
        "source_eda": args.eda,
        "source_format": args.source_format,
        "source_directory": source,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "files": files,
        "excluded_files": excluded,
        "capabilities": detect_capabilities(files),
        "drc_reports_included": False,
    }
    manifest_path = os.path.join(output, "export_layer_manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as stream:
        json.dump(manifest, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
    print("Export package ready: %s" % output)
    print("files=%d; capabilities=%s" % (len(files), json.dumps(manifest["capabilities"], ensure_ascii=False, sort_keys=True)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print("Export failed: %s" % error, file=sys.stderr)
        sys.exit(2)
