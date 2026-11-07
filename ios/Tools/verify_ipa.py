"""Offline checks for Ahna's signing input, using only Python's standard library.

This checks signature structure, executable flags and local hashes. It does not
validate an Apple certificate chain or replace a launch test after re-signing.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import zipfile


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def commands(data):
    require(len(data) >= 32, "Truncated Mach-O header")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    require(magic == 0xFEEDFACF and cpu == 0x100000C and kind == 2,
            "Expected a thin arm64 executable")
    require(count <= 1024 and 32 + size <= len(data), "Invalid load command region")
    offset = 32
    result = []
    for _ in range(count):
        require(offset + 8 <= 32 + size, "Truncated load command")
        command, length = struct.unpack_from("<2I", data, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= 32 + size,
                "Invalid load command length")
        result.append((command, offset, length))
        offset += length
    require(offset == 32 + size, "Load command sizes do not match header")
    return result


def text_sections(data):
    """Used to confirm packaging never changes the compiled application sections."""
    result = {}
    for command, offset, length in commands(data):
        if command != 0x19 or data[offset + 8:offset + 24].rstrip(b"\0") != b"__TEXT":
            continue
        count = struct.unpack_from("<I", data, offset + 64)[0]
        require(72 + count * 80 <= length, "Truncated text sections")
        for index in range(count):
            start = offset + 72 + index * 80
            name = data[start:start + 16].rstrip(b"\0").decode("ascii")
            size, file_offset = struct.unpack_from("<QI", data, start + 40)
            require(file_offset + size <= len(data), "Text section outside file")
            result[name] = data[file_offset:file_offset + size]
    require(result, "Missing text sections")
    return result


def verify_binary(data, info_data, resources_data):
    items = commands(data)
    text = None
    signature = None
    linkedit = None
    for command, offset, length in items:
        if command == 0x19:
            require(length >= 72, "Truncated segment")
            name, _, _, file_offset, file_size, maximum, initial, _, _ = struct.unpack_from("<16s4Q4I", data, offset + 8)
            name = name.rstrip(b"\0")
            require(file_offset + file_size <= len(data), "Segment extends outside file")
            if name == b"__TEXT":
                require(maximum == 5 and initial == 5, "Text segment must be read/execute")
                text = (file_offset, file_size)
            if name == b"__LINKEDIT":
                linkedit = (file_offset, file_size)
        if command == 0x1D:
            require(signature is None and length == 16, "Invalid signature load command")
            signature = struct.unpack_from("<2I", data, offset + 8)
    require(text is not None and linkedit is not None, "Missing required segments")
    require(signature is not None, "Missing LC_CODE_SIGNATURE: prepare signatures before packaging")
    start, allocation = signature
    require(linkedit[0] <= start and start + allocation <= sum(linkedit), "Signature outside linkedit")
    require(allocation >= 12 and start + allocation <= len(data), "Invalid signature range")
    magic, size, count = struct.unpack_from(">3I", data, start)
    require(magic == 0xFADE0CC0 and 12 + count * 8 <= size <= allocation, "Invalid signature superblob")
    blobs = {}
    for index in range(count):
        slot, relative = struct.unpack_from(">2I", data, start + 12 + index * 8)
        require(slot not in blobs and 12 + count * 8 <= relative <= size - 8, "Invalid signature blob index")
        bp = start + relative
        blob_magic, length = struct.unpack_from(">2I", data, bp)
        require(length >= 8 and relative + length <= size, "Truncated signature blob")
        blobs[slot] = (blob_magic, data[bp:bp + length])
    require(0 in blobs and blobs[0][0] == 0xFADE0C02, "Missing primary CodeDirectory")
    directories = [(slot, blob) for slot, (magic, blob) in blobs.items() if magic == 0xFADE0C02]
    verified = []
    for slot, cd in directories:
        require(len(cd) >= 88, "CodeDirectory is too short for executable metadata")
        version, flags, hash_offset, ident_offset, special_count, page_count, limit = struct.unpack_from(">7I", cd, 8)
        require(version >= 0x20400, "CodeDirectory lacks executable segment fields")
        hash_size, hash_type, _, exponent = struct.unpack_from("4B", cd, 36)
        require(hash_type == 2 and hash_size == 32, "Expected SHA-256 code hashes")
        require(12 <= exponent <= 16, "Unsupported hash page size")
        page_size = 1 << exponent
        require(limit == start and page_count == (limit + page_size - 1) // page_size,
                "Code hash coverage differs from signed executable length")
        require(special_count >= 3 and hash_offset - special_count * hash_size >= 88 and
                hash_offset + page_count * hash_size <= len(cd), "Invalid hash table bounds")
        require(88 <= ident_offset < hash_offset - special_count * hash_size, "Invalid signing identifier")
        ident_end = cd.find(b"\0", ident_offset, hash_offset - special_count * hash_size)
        require(ident_end >= 0, "Unterminated signing identifier")
        identifier = cd[ident_offset:ident_end].decode("utf-8")
        info = plistlib.loads(info_data)
        require(identifier == info["CFBundleIdentifier"], "Signing identifier differs from bundle identifier")
        base, size, exec_flags = struct.unpack_from(">3Q", cd, 64)
        require((base, size) == text, "Executable segment bounds differ from Mach-O")
        require(exec_flags & 1, "Executable is missing CS_EXECSEG_MAIN_BINARY")
        require(not exec_flags & (0x80 | 0x100 | 0x200), "Unexpected executable policy flags")
        for page in range(page_count):
            expected = cd[hash_offset + page * hash_size:hash_offset + (page + 1) * hash_size]
            actual = hashlib.sha256(data[page * page_size:min((page + 1) * page_size, limit)]).digest()
            require(expected == actual, "Code page hash mismatch at page " + str(page))
        special_data = {1: info_data, 3: resources_data}
        for blob_slot in (2, 5, 7):
            if blob_slot in blobs:
                special_data[blob_slot] = blobs[blob_slot][1]
        for special_slot, content in special_data.items():
            require(special_slot <= special_count, "Missing special hash slot")
            expected = cd[hash_offset - special_slot * hash_size:hash_offset - (special_slot - 1) * hash_size]
            require(hashlib.sha256(content).digest() == expected, "Special slot hash mismatch: " + str(special_slot))
        verified.append({"slot": slot, "identifier": identifier, "codePages": page_count,
                         "execSegFlags": exec_flags, "adHoc": bool(flags & 2),
                         "cdhash": hashlib.sha256(cd).digest()[:20].hex()})
    return verified


def verify_files(files):
    info_paths = sorted(name for name in files if name.endswith(".app/Info.plist") or name.endswith(".appex/Info.plist"))
    apps = [name for name in info_paths if name.endswith(".app/Info.plist")]
    extensions = [name for name in info_paths if name.endswith(".appex/Info.plist")]
    require(len(apps) == 1 and len(extensions) == 1, "Expected one app and one share extension")
    host = plistlib.loads(files[apps[0]])
    output = []
    for name in sorted(info_paths, key=len, reverse=True):
        info = plistlib.loads(files[name])
        require(info.get("CFBundleVersion") == host.get("CFBundleVersion") and
                info.get("CFBundleShortVersionString") == host.get("CFBundleShortVersionString"),
                "App and extension versions differ")
        if name in extensions:
            require(info["CFBundleIdentifier"].startswith(host["CFBundleIdentifier"] + "."), "Extension identifier is not nested under host")
            require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.share-services", "Wrong extension type")
        executable = info.get("CFBundleExecutable", "")
        require(executable and PurePosixPath(executable).name == executable, "Unsafe executable name")
        prefix = name[:-len("Info.plist")]
        binary_name = prefix + executable
        seal_name = prefix + "_CodeSignature/CodeResources"
        require(binary_name in files and seal_name in files, "Missing executable or resource seal")
        directories = verify_binary(files[binary_name], files[name], files[seal_name])
        seal = plistlib.loads(files[seal_name])
        checked = 0
        for table_name, default_digest in (("files", hashlib.sha1), ("files2", hashlib.sha256)):
            for relative, value in seal.get(table_name, {}).items():
                require(not PurePosixPath(relative).is_absolute() and ".." not in PurePosixPath(relative).parts, "Unsafe sealed resource path")
                content = files.get(prefix + relative)
                if isinstance(value, bytes):
                    require(content is not None and default_digest(content).digest() == value, "Resource hash mismatch: " + relative)
                    checked += 1
                elif isinstance(value, dict):
                    for key, digest in (("hash", hashlib.sha1), ("hash2", hashlib.sha256)):
                        if key in value:
                            require(content is not None and digest(content).digest() == value[key], "Resource hash mismatch: " + relative)
                            checked += 1
                    if "cdhash" in value:
                        nested = next((bundle for bundle in output if bundle["bundle"] == (prefix + relative).rstrip("/")), None)
                        require(nested is not None, "Missing nested bundle seal: " + relative)
                        require(bytes.fromhex(nested["directories"][0]["cdhash"]) == value["cdhash"], "Nested bundle code hash mismatch: " + relative)
                        checked += 1
        output.append({"bundle": prefix.rstrip("/"), "version": info["CFBundleShortVersionString"],
                       "build": info["CFBundleVersion"], "directories": directories, "resourceHashes": checked})
    return {"success": True, "scope": "Offline structure and hash verification only; Apple trust and post-Sideloadly launch not verified", "bundles": output}


def load_files(path):
    path = Path(path)
    if path.is_dir():
        require(path.suffix == ".app", "Directory input must be an app bundle")
        files = {}
        for item in path.rglob("*"):
            require(not item.is_symlink(), "Symbolic links are not expected in Ahna")
            if item.is_file():
                files[path.name + "/" + item.relative_to(path).as_posix()] = item.read_bytes()
        return files
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "Corrupted ZIP entry")
        files = {}
        names = set()
        for item in archive.infolist():
            name = item.filename
            require(not PurePosixPath(name).is_absolute() and ".." not in PurePosixPath(name).parts and "\\" not in name, "Unsafe ZIP path")
            require(name.casefold() not in names, "Duplicate ZIP entry")
            names.add(name.casefold())
            require((item.external_attr >> 16) & 0o170000 != 0o120000, "ZIP symbolic link is not allowed")
            if not item.is_dir():
                files[name] = archive.read(item)
        return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa_or_app")
    parser.add_argument("--report")
    args = parser.parse_args()
    try:
        report = verify_files(load_files(args.ipa_or_app))
    except (ValueError, KeyError, struct.error, OSError, zipfile.BadZipFile) as error:
        report = {"success": False, "error": str(error)}
    text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.report:
        Path(args.report).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0 if report["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
