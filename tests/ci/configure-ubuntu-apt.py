"""Select Ubuntu's direct HTTPS archive on the ephemeral Ubuntu 24.04 CI runner."""

from pathlib import Path
import re
import sys

MIRROR = b"mirror+file:/etc/apt/apt-mirrors.txt"
ARCHIVE = b"https://archive.ubuntu.com/ubuntu/"
SECURITY = b"https://security.ubuntu.com/ubuntu/"
# Azure and cloud-init can leave the stock Ubuntu URIs in the image.
MAIN_URIS = {MIRROR, ARCHIVE}
SECURITY_URIS = {SECURITY}
for origin in (b"http://archive.ubuntu.com", b"http://azure.archive.ubuntu.com",
               b"https://azure.archive.ubuntu.com", b"https://archive.ubuntu.com"):
    MAIN_URIS.update((origin + b"/ubuntu", origin + b"/ubuntu/"))
for origin in (b"http://security.ubuntu.com", b"https://security.ubuntu.com"):
    SECURITY_URIS.update((origin + b"/ubuntu", origin + b"/ubuntu/"))
URI_LINE = re.compile(rb"^(URIs:[ \t]*)([^\r\n]*)(\r?)$", re.MULTILINE)


def configure(path):
    original = path.read_bytes()
    fields = list(URI_LINE.finditer(original))
    values = [field[2].strip() for field in fields]
    # Fail before writing if the hosted image no longer has the expected layout.
    # Multiple Ubuntu stanzas are valid; suites/components/signing keys stay exact.
    if not fields or any(value not in MAIN_URIS and value not in SECURITY_URIS for value in values):
        raise ValueError("Unexpected Ubuntu sources URIs; inspect the runner image")
    if not any(value in MAIN_URIS for value in values):
        raise ValueError("Ubuntu sources contain no main archive")
    updated = URI_LINE.sub(
        lambda match: match[1] + (
            ARCHIVE if match[2].strip() in MAIN_URIS else SECURITY
        ) + match[3],
        original,
    )
    if updated != original:
        path.write_bytes(updated)
    print("Ubuntu APT: direct HTTPS archive; suites, components and signing keys preserved")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: configure-ubuntu-apt.py <ubuntu.sources>")
    configure(Path(sys.argv[1]))
