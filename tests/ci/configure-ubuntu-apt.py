"""Select Ubuntu's direct HTTPS archive on the ephemeral Ubuntu 24.04 CI runner."""

from pathlib import Path
import re
import sys

MIRROR = b"mirror+file:/etc/apt/apt-mirrors.txt"
ARCHIVE = b"https://archive.ubuntu.com/ubuntu/"
SECURITY = b"https://security.ubuntu.com/ubuntu/"
URI_LINE = re.compile(rb"^(URIs:[ \t]*)([^\r\n]*)(\r?)$", re.MULTILINE)


def configure(path):
    original = path.read_bytes()
    fields = list(URI_LINE.finditer(original))
    values = [field[2].strip() for field in fields]
    # Fail before writing if the hosted image no longer has the expected layout.
    # Multiple Ubuntu stanzas are valid; suites/components/signing keys stay exact.
    if not fields or any(value not in (MIRROR, ARCHIVE, SECURITY) for value in values):
        raise ValueError("Unexpected Ubuntu sources URIs; inspect the runner image")
    if not any(value in (MIRROR, ARCHIVE) for value in values):
        raise ValueError("Ubuntu sources contain no main archive")
    updated = URI_LINE.sub(
        lambda match: match[1] + ARCHIVE + match[3]
        if match[2].strip() == MIRROR else match[0],
        original,
    )
    if updated != original:
        path.write_bytes(updated)
    print("Ubuntu APT: direct HTTPS archive; suites, components and signing keys preserved")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: configure-ubuntu-apt.py <ubuntu.sources>")
    configure(Path(sys.argv[1]))
