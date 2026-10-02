#!/usr/bin/env python3
"""Model-free lease controls against the actual native bridge. No engine build.

Run: python3 tests/spill-lifecycle/test-native.py LIBRARY
Uses only private temporary paths, real child processes, and stdlib ctypes.
"""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

LIBRARY = str(Path(sys.argv.pop(1)).resolve())

def bind():
    lib = ctypes.CDLL(LIBRARY)
    lib.relm_spill_lease_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.relm_spill_lease_create.restype = ctypes.c_void_p
    for name in ('release', 'cleanup', 'valid'):
        fun = getattr(lib, 'relm_spill_lease_' + name)
        fun.argtypes = [ctypes.c_void_p]
        fun.restype = None if name == 'release' else ctypes.c_int
    lib.relm_spill_lease_sweep.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_double]
    lib.relm_spill_lease_sweep.restype = ctypes.c_int
    lib.relm_spill_lease_open.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.relm_spill_lease_open.restype = ctypes.c_int
    return lib

lib = bind()

if '--owner' in sys.argv:
    root, leaf = sys.argv[-2:]
    lease = lib.relm_spill_lease_create(os.fsencode(root), os.fsencode(leaf))
    assert lease
    (Path(root)/leaf/'trace-child.arrow').write_bytes(b'live child bytes')
    print('READY', flush=True)
    sys.stdin.readline()
    lib.relm_spill_lease_release(lease)
    sys.exit(0)

class Leases(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='relm-lease-')
        self.root = Path(self.tmp.name).resolve()/'spill'
        self.addCleanup(self.tmp.cleanup)
        self.leases=[]
        self.addCleanup(lambda: [lib.relm_spill_lease_release(p) for p in self.leases])

    def create(self, leaf='owner'):
        p = lib.relm_spill_lease_create(os.fsencode(self.root), os.fsencode(leaf))
        self.assertTrue(p); self.leases.append(p)
        return p

    def release(self, p):
        lib.relm_spill_lease_release(p); self.leases.remove(p)

    def age(self, leaf='owner'):
        old=time.time()-9*86400
        os.utime(self.root/leaf,(old,old))

    def sweep(self, leaf='owner', root=None):
        return lib.relm_spill_lease_sweep(os.fsencode(root or self.root),os.fsencode(leaf),time.time()-7*86400)

    def test_live_child_and_crash(self):
        child=subprocess.Popen([sys.executable,__file__,LIBRARY,'--owner',str(self.root),'owner'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(),'READY')
            self.age(); self.assertEqual(self.sweep(),0)
            self.assertEqual((self.root/'owner/trace-child.arrow').read_bytes(),b'live child bytes')
            child.kill(); child.communicate(timeout=5)
            self.assertEqual(self.sweep(),1)
            self.assertFalse((self.root/'owner').exists())
        finally:
            if child.poll() is None: child.kill()
            child.communicate(timeout=5)

    def test_recent_orphan_retained(self):
        p=self.create(); self.release(p)
        self.assertEqual(self.sweep(),0)
        self.assertTrue((self.root/'owner').exists())

    def test_cleanup_and_idempotent_sweep(self):
        p=self.create(); (self.root/'owner/trace-ok.arrow').write_bytes(b'ok')
        self.assertEqual(lib.relm_spill_lease_cleanup(p),1)
        self.assertEqual(lib.relm_spill_lease_cleanup(p),0)
        self.assertFalse((self.root/'owner').exists())

    def test_legacy_missing_marker_preserved(self):
        (self.root/'owner').mkdir(parents=True)
        (self.root/'owner/trace-old.arrow').write_bytes(b'old')
        self.age(); self.assertEqual(self.sweep(),0)
        self.assertTrue((self.root/'owner/trace-old.arrow').exists())

    def test_malformed_marker_preserved(self):
        p=self.create();self.release(p)
        (self.root/'owner/.relm-owner').write_text('unknown format')
        self.age(); self.assertEqual(self.sweep(),0)
        self.assertTrue((self.root/'owner').exists())

    def test_denied_marker_preserved(self):
        self.assertNotEqual(os.geteuid(),0,'permission test requires an unprivileged process')
        p=self.create();self.release(p)
        marker=self.root/'owner/.relm-owner';marker.chmod(0)
        try:
            self.age();self.assertEqual(self.sweep(),0)
            self.assertTrue((self.root/'owner').exists())
        finally: marker.chmod(0o600)

    def test_root_symlink_rejected(self):
        p=self.create();self.release(p);self.age()
        alias=self.root.parent/'alias';alias.symlink_to(self.root,target_is_directory=True)
        self.assertEqual(self.sweep(root=alias),0)
        self.assertFalse(lib.relm_spill_lease_create(os.fsencode(alias),b'new'))
        self.assertTrue((self.root/'owner').exists())

    def test_candidate_symlink_rejected(self):
        p=self.create();self.release(p);self.age()
        (self.root/'alias').symlink_to(self.root/'owner',target_is_directory=True)
        self.assertEqual(self.sweep('alias'),0)
        self.assertTrue((self.root/'owner').exists())

    def test_replaced_candidate_preserves_both(self):
        p=self.create();original=self.root/'owner'; original.rename(self.root/'moved')
        original.mkdir();(original/'unrelated').write_bytes(b'keep')
        self.assertEqual(lib.relm_spill_lease_valid(p),0)
        self.assertEqual(lib.relm_spill_lease_cleanup(p),0)
        self.assertEqual((original/'unrelated').read_bytes(),b'keep')
        self.assertTrue((self.root/'moved/.relm-owner').exists())

    def test_unknown_nested_and_symlink_contents_preserved(self):
        p=self.create();target=self.root.parent/'outside';target.write_bytes(b'keep')
        (self.root/'owner/trace-link.arrow').symlink_to(target)
        self.assertEqual(lib.relm_spill_lease_cleanup(p),0)
        self.assertEqual(target.read_bytes(),b'keep')
        (self.root/'owner/trace-link.arrow').unlink()
        (self.root/'owner/nested').mkdir()
        self.assertEqual(lib.relm_spill_lease_cleanup(p),0)

    def test_second_owner_cannot_adopt(self):
        self.create();self.assertFalse(lib.relm_spill_lease_create(os.fsencode(self.root),b'owner'))

    def test_open_replacement_after_validation_cannot_redirect(self):
        p=self.create();original=self.root/'owner'
        (original/'trace-original.arrow').write_bytes(b'original')
        replacement=self.root.parent/'replacement';replacement.mkdir()
        (replacement/'sentinel').write_bytes(b'keep')
        callback_type=ctypes.CFUNCTYPE(None)
        lib.relm_spill_test_before_open.argtypes=[callback_type]
        def replace():
            original.rename(self.root/'moved')
            original.symlink_to(replacement,target_is_directory=True)
        callback=callback_type(replace)
        lib.relm_spill_test_before_open(callback)
        try:
            self.assertEqual(lib.relm_spill_lease_open(p,b'trace-new.arrow'),-1)
        finally:
            lib.relm_spill_test_before_open(callback_type())
        self.assertEqual(sorted(x.name for x in replacement.iterdir()),['sentinel'])
        self.assertEqual((replacement/'sentinel').read_bytes(),b'keep')
        self.assertEqual((self.root/'moved/trace-original.arrow').read_bytes(),b'original')

    def test_descriptor_open_is_exclusive(self):
        p=self.create();fd=lib.relm_spill_lease_open(p,b'trace-new.arrow')
        self.assertGreaterEqual(fd,0)
        os.write(fd,b'first');os.close(fd)
        self.assertEqual(lib.relm_spill_lease_open(p,b'trace-new.arrow'),-1)
        self.assertEqual(lib.relm_spill_lease_open(p,b'../trace-escape.arrow'),-1)
        self.assertEqual((self.root/'owner/trace-new.arrow').read_bytes(),b'first')

    def test_two_sweepers(self):
        p=self.create();(self.root/'owner/trace-ok.arrow').write_bytes(b'ok')
        self.release(p);self.age()
        code='import ctypes,os,sys,time; l=ctypes.CDLL(sys.argv[1]); f=l.relm_spill_lease_sweep; f.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_double]; print(f(os.fsencode(sys.argv[2]),b"owner",time.time()-7*86400))'
        children=[subprocess.Popen([sys.executable,'-c',code,LIBRARY,str(self.root)],stdout=subprocess.PIPE,text=True) for _ in range(2)]
        answers=[c.communicate(timeout=5)[0].strip() for c in children]
        self.assertEqual(sorted(answers),['0','1'])
        self.assertTrue(all(c.returncode==0 for c in children))

if __name__=='__main__': unittest.main(verbosity=2)
