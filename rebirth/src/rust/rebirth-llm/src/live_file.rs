//! Ownership of an exclusively created live spill file, independent of Arrow.
use std::fs::File;
use std::path::Path;
#[cfg(unix)]
use std::path::PathBuf;

/// Unix removes an unpublished file only while its identity still matches.
/// Other platforms retain caller-managed files: there is no portable stable
/// file-identity check here, so deleting by pathname alone would be unsafe.
#[derive(Debug)]
pub(crate) struct OwnedLiveFile {
    #[cfg(unix)]
    path: PathBuf,
    #[cfg(unix)]
    metadata: std::fs::Metadata,
    retained: bool,
}

impl OwnedLiveFile {
    pub(crate) fn new(path: &Path, file: &File) -> std::io::Result<Self> {
        // Keep the metadata failure boundary on every platform, even where
        // automatic cleanup is unavailable and no identity needs to be stored.
        let metadata = file.metadata()?;
        #[cfg(not(unix))]
        let _ = (path, metadata);
        Ok(Self {
            #[cfg(unix)]
            path: path.to_owned(),
            #[cfg(unix)]
            metadata,
            retained: false,
        })
    }

    pub(crate) fn retain(&mut self) {
        self.retained = true;
    }
}

impl Drop for OwnedLiveFile {
    fn drop(&mut self) {
        if self.retained {
            return;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if let Ok(current) = std::fs::symlink_metadata(&self.path) {
                if current.is_file()
                    && current.dev() == self.metadata.dev()
                    && current.ino() == self.metadata.ino()
                {
                    let _ = std::fs::remove_file(&self.path);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    // Standalone rustc tests run before native compilation in Windows CPU and
    // Linux R-devel CI. No engine, model, Arrow or R installation is needed.
    fn fixture() -> (std::path::PathBuf, File) {
        let path = std::env::temp_dir().join(format!(
            "relm-live-owner-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let file = File::options()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        (path, file)
    }

    #[test]
    fn delivery_retains_file() {
        let (path, file) = fixture();
        let mut owner = OwnedLiveFile::new(&path, &file).unwrap();
        owner.retain();
        drop(file);
        drop(owner);
        assert!(path.is_file());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn unpublished_file_respects_platform_cleanup_policy() {
        let (path, file) = fixture();
        let owner = OwnedLiveFile::new(&path, &file).unwrap();
        drop(file);
        drop(owner);
        #[cfg(unix)]
        assert!(!path.exists());
        #[cfg(not(unix))]
        {
            assert!(path.is_file());
            std::fs::remove_file(path).unwrap();
        }
    }

    #[test]
    fn replaced_file_survives() {
        let (path, file) = fixture();
        let owner = OwnedLiveFile::new(&path, &file).unwrap();
        drop(file);
        // Keep the original inode allocated, rather than permitting inode reuse.
        let moved = path.with_extension("original");
        std::fs::rename(&path, &moved).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        drop(owner);
        assert_eq!(std::fs::read(&path).unwrap(), b"replacement");
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(moved).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn replacement_symlink_and_its_target_survive() {
        let (path, file) = fixture();
        let owner = OwnedLiveFile::new(&path, &file).unwrap();
        drop(file);
        let moved = path.with_extension("original");
        std::fs::rename(&path, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &path).unwrap();
        drop(owner);
        assert!(path.is_symlink());
        assert!(moved.is_file());
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(moved).unwrap();
    }
}
