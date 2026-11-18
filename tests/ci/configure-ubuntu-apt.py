"""Select Ubuntu's direct HTTPS archive on the ephemeral Ubuntu 24.04 CI runner."""

from pathlib import Path
import re
import platform
import subprocess
import tempfile
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
# Cloud-init may keep an official EC2 origin before image mirror normalization.
# R-devel repair accepts these exact hosts without changing ordinary R routing.
REPAIR_MAIN_URIS = set(MAIN_URIS)
for region in (b"us-east-2", b"us-west-2"):
    for scheme in (b"http://", b"https://"):
        origin = scheme + region + b".ec2.archive.ubuntu.com/ubuntu"
        REPAIR_MAIN_URIS.update((origin, origin + b"/"))
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



def restore_noble(path, release, architecture, keyring):
    """Restore only signed Ubuntu24 amd64 indices on an ephemeral CI runner."""
    if (release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "24.04"
            or release.get("VERSION_CODENAME") != "noble" or architecture != "amd64"):
        raise ValueError("Ubuntu source repair requires the Ubuntu24 amd64 runner")
    if not keyring.is_file() or keyring.stat().st_size == 0:
        raise ValueError("Ubuntu archive signing keyring is missing")
    if path.is_symlink():
        raise ValueError("Ubuntu source repair refuses a symbolic link")
    original = path.read_bytes() if path.exists() else b""
    allowed_fields = {
        b"Types", b"URIs", b"Suites", b"Components", b"Signed-By",
        b"Enabled", b"Architectures",
    }
    suites = {b"noble", b"noble-updates", b"noble-security", b"noble-backports"}
    components = {b"main", b"restricted", b"universe", b"multiverse"}
    before = []
    for paragraph in re.split(rb"(?:\r?\n){2,}", original):
        fields = {}
        for line in paragraph.splitlines():
            if not line.strip() or line.lstrip().startswith(b"#"):
                continue
            name, separator, value = line.partition(b":")
            if not separator or name not in allowed_fields or name in fields:
                raise ValueError("Unexpected Ubuntu source fields or trust settings")
            fields[name] = value.strip()
        if not fields:
            continue
        if not {b"Types", b"URIs", b"Suites", b"Components", b"Signed-By"} <= fields.keys():
            raise ValueError("Incomplete Ubuntu source identity; inspect the runner")
        if (not fields[b"Types"].split()
                or not set(fields[b"Types"].split()) <= {b"deb", b"deb-src"}
                or not fields[b"URIs"].split()
                or not set(fields[b"URIs"].split()) <= REPAIR_MAIN_URIS | SECURITY_URIS
                or not fields[b"Suites"].split()
                or not set(fields[b"Suites"].split()) <= suites
                or not set(fields[b"Components"].split()) <= components
                or fields[b"Signed-By"] != str(keyring).encode()
                or fields.get(b"Enabled", b"yes") not in {b"yes", b"no"}
                or (b"Architectures" in fields and b"amd64" not in fields[b"Architectures"].split())):
            raise ValueError("Unexpected Ubuntu source origin, release or signing key")
        before.append(fields)

    # Log only validated Ubuntu fields; unrelated repository credentials stay private.
    print("Ubuntu APT before repair:", before if before else "no Ubuntu stanzas")
    updated = (
        "Types: deb\n"
        "URIs: https://archive.ubuntu.com/ubuntu/\n"
        "Suites: noble noble-updates noble-backports\n"
        "Components: main restricted universe multiverse\n"
        f"Signed-By: {keyring}\n\n"
        "Types: deb\n"
        "URIs: https://security.ubuntu.com/ubuntu/\n"
        "Suites: noble-security\n"
        "Components: main restricted universe multiverse\n"
        f"Signed-By: {keyring}\n"
    ).encode()
    if updated != original:
        # Atomic replacement prevents a partial sources file after an interrupted write.
        with tempfile.TemporaryDirectory(prefix=".relm-apt-", dir=path.parent) as directory:
            temporary = Path(directory) / path.name
            temporary.write_bytes(updated)
            temporary.chmod(0o644)
            temporary.replace(path)
    print("Ubuntu APT: signed Noble main, updates, backports and security indices enabled")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--restore-noble":
        restore_noble(
            Path(sys.argv[2]), platform.freedesktop_os_release(),
            subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip(),
            Path("/usr/share/keyrings/ubuntu-archive-keyring.gpg"),
        )
    elif len(sys.argv) == 2:
        configure(Path(sys.argv[1]))
    else:
        sys.exit("Usage: configure-ubuntu-apt.py [--restore-noble] <ubuntu.sources>")
