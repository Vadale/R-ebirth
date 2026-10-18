//! Build-only path/link controls, also tested without building the engine.

use std::io;
use std::path::{Path, PathBuf};

pub fn source_dir(path: &Path) -> io::Result<PathBuf> {
    let path = if cfg!(windows) {
        // canonicalize introduces a verbatim \\?\ prefix that MSYS Makefiles
        // cannot safely use as a prerequisite. Keep ordinary Windows syntax.
        std::path::absolute(path)?
    } else {
        path.canonicalize()?
    };
    if !path.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "native source directory is missing",
        ));
    }
    Ok(path)
}

pub fn windows_output_dir(out: &Path) -> io::Result<PathBuf> {
    // OUT_DIR = <target>/<optional triple>/<profile>/build/rebirth-llm-<hash>/out.
    // Keep both the profile and Cargo hash; unrelated build units must not share
    // a CMake cache. Everything remains owned by normal Cargo/R target cleanup.
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected Cargo OUT_DIR layout",
        )
    };
    let unit = out.parent().ok_or_else(invalid)?;
    let build = unit.parent().ok_or_else(invalid)?;
    let profile = build.parent().ok_or_else(invalid)?;
    let hash = unit
        .file_name()
        .and_then(|x| x.to_str())
        .and_then(|x| x.strip_prefix("rebirth-llm-"))
        .filter(|x| !x.is_empty() && x.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or_else(invalid)?;
    if out.file_name() != Some("out".as_ref()) || build.file_name() != Some("build".as_ref()) {
        return Err(invalid());
    }
    Ok(profile.join("n").join(hash))
}

pub fn link_libraries(stems: &[&str], target_os: &str, metal: bool) -> Vec<String> {
    // GNU links need archive back-references resolved in dependent Rust bins as
    // well as the R shared library. Do not bundle duplicate native archives into
    // librelm.a; Makevars links the same archives explicitly with --start-group.
    let gnu = matches!(target_os, "linux" | "windows");
    let mut flags: Vec<_> = stems
        .iter()
        .map(|stem| {
            if gnu {
                format!("static:+whole-archive,-bundle={stem}")
            } else {
                format!("static={stem}")
            }
        })
        .collect();
    if gnu {
        flags.push("dylib=stdc++".into());
        if target_os == "linux" {
            flags.extend(["dylib=m".into(), "dylib=dl".into()]);
        }
    } else {
        flags.extend(["dylib=c++".into(), "framework=Accelerate".into()]);
        if metal {
            flags.extend([
                "framework=Metal".into(),
                "framework=MetalKit".into(),
                "framework=Foundation".into(),
            ]);
        }
    }
    flags
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_source_uses_host_compatible_absolute_path() {
        let here = std::env::current_dir().unwrap();
        let source = source_dir(&here.join(".")).unwrap();
        assert!(source.is_absolute());
        assert!(source.is_dir());
        #[cfg(windows)]
        assert!(!source.components().any(|c| matches!(c,
            std::path::Component::Prefix(p) if p.kind().is_verbatim())));
        #[cfg(not(windows))]
        assert_eq!(source, here.canonicalize().unwrap());
    }

    #[test]
    fn existing_source_with_spaces_and_parent_components_is_usable() {
        let root = std::env::temp_dir().join(format!("relm native paths {}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(root.join("child")).unwrap();
        std::fs::write(root.join("CMakeLists.txt"), b"# path control\n").unwrap();
        let source = source_dir(&root.join("child/..")).unwrap();
        assert_eq!(
            std::fs::read(source.join("CMakeLists.txt")).unwrap(),
            b"# path control\n"
        );
        #[cfg(windows)]
        assert!(!source.components().any(|c| matches!(c,
            std::path::Component::Prefix(p) if p.kind().is_verbatim())));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_source_is_refused_before_cmake() {
        let absent = std::env::current_dir()
            .unwrap()
            .join(format!("relm-missing-native-source-{}", std::process::id()));
        assert!(!absent.exists());
        assert_eq!(
            source_dir(&absent).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
    }

    #[test]
    fn shortened_output_preserves_cargo_unit_profile_and_target() {
        for prefix in [
            "target/debug",
            "target/release",
            "target/x86_64-pc-windows-gnu/release",
        ] {
            let root = Path::new("package with spaces").join(prefix);
            let original = root.join("build/rebirth-llm-a3b0253357eabd3b/out");
            let output = windows_output_dir(&original).unwrap();
            assert_eq!(output, root.join("n/a3b0253357eabd3b"));
            assert!(output.starts_with(&root));
            assert!(output.as_os_str().len() < original.as_os_str().len());
            assert_ne!(
                output,
                windows_output_dir(&root.join("build/rebirth-llm-1234567890abcdef/out")).unwrap()
            );
        }
    }

    #[test]
    fn malformed_output_cannot_escape_owned_target() {
        for path in [
            "out",
            "target/release/build/other-crate-123/out",
            "target/release/build/rebirth-llm-/out",
            "target/release/build/rebirth-llm-../out",
            "target/release/not-build/rebirth-llm-123/out",
            "target/release/build/rebirth-llm-123/other",
        ] {
            assert_eq!(
                windows_output_dir(Path::new(path)).unwrap_err().kind(),
                io::ErrorKind::InvalidInput
            );
        }
    }

    #[test]
    fn windows_gnu_has_no_darwin_frameworks_or_unix_libraries() {
        assert_eq!(
            link_libraries(&["llama", "ggml"], "windows", false),
            [
                "static:+whole-archive,-bundle=llama",
                "static:+whole-archive,-bundle=ggml",
                "dylib=stdc++"
            ]
        );
    }

    #[test]
    fn linux_and_macos_link_plans_are_unchanged() {
        assert_eq!(
            link_libraries(&["llama"], "linux", false),
            [
                "static:+whole-archive,-bundle=llama",
                "dylib=stdc++",
                "dylib=m",
                "dylib=dl"
            ]
        );
        assert_eq!(
            link_libraries(&["llama"], "macos", false),
            ["static=llama", "dylib=c++", "framework=Accelerate"]
        );
        assert_eq!(
            link_libraries(&["llama"], "macos", true),
            [
                "static=llama",
                "dylib=c++",
                "framework=Accelerate",
                "framework=Metal",
                "framework=MetalKit",
                "framework=Foundation"
            ]
        );
    }
}
