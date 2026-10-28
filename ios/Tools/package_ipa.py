"""Create an IPA with stable permissions and uncompressed Info.plist entries."""
import argparse
from pathlib import Path
import plistlib
import zipfile


def package(app, output):
    app, output = Path(app), Path(output)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Expected an app bundle")
    if output.exists():
        raise FileExistsError("Refusing to replace existing IPA: " + str(output))
    executables = set()
    for info_path in app.rglob("Info.plist"):
        info = plistlib.loads(info_path.read_bytes())
        executable = info.get("CFBundleExecutable")
        if executable:
            if Path(executable).name != executable:
                raise ValueError("Unsafe executable path")
            executables.add(info_path.parent / executable)
    with zipfile.ZipFile(output, "x") as archive:
        for path in sorted(app.rglob("*")):
            if path.is_symlink():
                raise ValueError("Unexpected symlink in Ahna bundle")
            if not path.is_file():
                continue
            name = "Payload/" + app.name + "/" + path.relative_to(app).as_posix()
            item = zipfile.ZipInfo.from_file(path, arcname=name)
            item.create_system = 3
            item.external_attr = (0o100755 if path in executables else 0o100644) << 16
            # This also avoids relying on the signer's ZIP handling for plist hashes.
            compression = zipfile.ZIP_STORED if path.name == "Info.plist" else zipfile.ZIP_DEFLATED
            archive.writestr(item, path.read_bytes(), compress_type=compression)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("output")
    args = parser.parse_args()
    package(args.app, args.output)
