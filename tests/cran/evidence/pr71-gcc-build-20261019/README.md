# PR71 GCC and build correction evidence

The original six CI failures remain failed. Five stopped on the same build-script
Clippy error; Windows lost the CMake path backslashes before native compilation.
R-devel was still running at the last snapshot and is not classified here.

The original complete loader translation unit reproduces the GCC16/LTO warning.
The one-condition correction compiles/links without it under the retained flags
and -Werror=stringop-overread. Original/corrected actual-template controls match
eight explicit expected cases and logs. The exact new CI control passes -Werror.
These are focused translation-unit/template tests, not a complete engine or R
package execution. Full package acceptance remains pending.

The optional sanitizer build failed before execution in unrelated libstdc++ regex
code; its command/log remain failed. The first special-path configuration control
failed on shell/make dollar-escaping order; corrected configure and real make/sh
round trips passed without model/native execution. No suppression was added.

See owner.json for exact current source bindings, scope, bundle changes and local
compiled-file hashes. Compiled outputs stay outside the repository. The manifest
covers every retained archive file except the manifest itself. No old tests,
models, installation, inference or numerical experiment was replayed.
