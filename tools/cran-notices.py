#!/usr/bin/env python3
"""Install exact license/copyright texts for the locked Rust graph; no network/build."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'rebirth'
SUPPLEMENTS = ROOT / 'tools/cran-license-supplements'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def render():
    manifest = json.loads((PACKAGE / 'tools/bundled-sources.json').read_text())
    archive_path = PACKAGE / 'src/rust/vendor.tar.xz'
    assert digest(archive_path.read_bytes()) == manifest['bundles']['src/rust/vendor.tar.xz']['sha256']
    lock = (PACKAGE / 'src/rust/Cargo.lock').read_bytes()
    assert digest(lock) == manifest['cargo_lock_sha256']
    packages = [p for p in tomllib.loads(lock.decode())['package'] if 'source' in p]
    supplements = json.loads((SUPPLEMENTS / 'sources.json').read_text())
    texts, rows = {}, []
    with tarfile.open(archive_path) as archive:
        members = {m.name: m for m in archive.getmembers() if m.isfile()}
        for p in sorted(packages, key=lambda p: (p['name'], p['version'])):
            crate = p['name'] + '-' + p['version']
            prefix = 'vendor/' + crate + '/'
            metadata = tomllib.loads(archive.extractfile(prefix + 'Cargo.toml').read().decode())['package']
            notices = []
            for name in sorted(members):
                base = Path(name).name.upper()
                explicit = prefix + metadata.get('license-file', '')
                if name.startswith(prefix) and (base.startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'COPYRIGHT', 'AUTHORS')) or name == explicit):
                    data = archive.extractfile(name).read()
                    data.decode('utf-8')
                    sha = digest(data)
                    texts[sha] = data
                    notices.append({'source': name, 'sha256': sha})
            if crate in supplements:
                entry = supplements[crate]
                data = (SUPPLEMENTS / entry['file']).read_bytes()
                assert digest(data) == entry['sha256']
                vcs = json.loads(archive.extractfile(prefix + '.cargo_vcs_info.json').read())
                assert '/' + vcs['git']['sha1'] + '/' in entry['url']
                assert entry['url'].startswith(metadata['repository'].replace('github.com', 'raw.githubusercontent.com') + '/')
                texts[entry['sha256']] = data
                notices.append({'source': entry['url'], 'sha256': entry['sha256']})
            assert notices, 'No retained license text for ' + crate
            rows.append({'crate': crate, 'authors': metadata.get('authors', []),
                         'license': metadata.get('license', metadata.get('license-file')), 'notices': notices})
    header = ('Rust dependency notices for relm\n\n'
              'The inventory covers all 81 locked source crates, including platform-only and\n'
              'build dependencies. Inclusion does not assert that every crate is linked on\n'
              'every platform. Identical texts are included once, keyed by SHA256.\n'
              'All text bytes below are retained verbatim. Files absent from published\n'
              'crate archives are supplied from their exact recorded upstream revisions.\n\n')
    out = bytearray(header.encode())
    for row in rows:
        out.extend((row['crate'] + '\n  License expression: ' + row['license'] + '\n').encode())
        if row['authors']:
            out.extend(('  Authors: ' + '; '.join(row['authors']) + '\n').encode())
        else:
            out.extend(b'  Authors/copyrights: see the retained texts below.\n')
        for entry in row['notices']:
            out.extend(('  ' + entry['sha256'] + '  ' + entry['source'] + '\n').encode())
        out.extend(b'\n')
    for sha, data in sorted(texts.items()):
        out.extend(('\n===== SHA256 ' + sha + ' =====\n').encode())
        out.extend(data)
        out.extend(b'\n===== END =====\n')
    return bytes(out), rows


def main(write=False):
    data, rows = render()
    destination = PACKAGE / 'inst/RUST-NOTICES'
    if write:
        destination.write_bytes(data)
        manifest_path = PACKAGE / 'tools/bundled-sources.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['generated_files']['inst/RUST-NOTICES'] = digest(data)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    else:
        assert destination.read_bytes() == data, 'Installed Rust notices are stale'
    print(f'RUST_NOTICES_OK crates={len(rows)} texts={len({n["sha256"] for r in rows for n in r["notices"]})} bytes={len(data)}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    main(parser.parse_args().write)
