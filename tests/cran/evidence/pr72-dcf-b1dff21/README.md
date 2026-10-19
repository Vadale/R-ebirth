# PR72 packaged DESCRIPTION failure and correction

All six R jobs failed at configure on b1dff21. The five Rust/integrity job statuses
were successful. Original job logs are gzip-compressed losslessly; their raw
SHA256 values and exact job metadata are retained. Two original artifact ZIPs
were size/digest checked and their actual DESCRIPTION files and parser inspected.
The ZIPs/source tars stay LOCAL; no executable payload was loaded.

R CMD build folds `rustc >=` and `1.85.0` onto separate lines. The original parser
rejects that valid DCF field. Normalize whitespace before splitting requirements;
minimum declarations, version/error refusals and native code remain unchanged.

The final regression uses actual write.dcf/read.dcf serialization at widths72/60
and exact LF/CRLF bytes. It rejects the old parser and passes the new one in35
cases, including12 serialized-field cases. Its old-parser runner differs only in
the script path, and both hashes are recorded. Both original CI DESCRIPTION files
pass the corrected script with real local Rust/Cargo1.99.1. No model, native build
or relm installation was executed locally. Hosted acceptance remains pending.

An initial regression draft used widths48/80; it passed because neither broke
the version boundary. This non-triggering attempt is retained, not used as
regression proof. The interim text-mode writer was subsequently replaced by
explicit binary LF/CRLF to avoid Windows newline translation; final red/green
results correspond to this last test source.

Windows three-case and Linux four-case file controls passed in the original
matrix. Tidy5.6.0 was installed and incoming reported a new-submission NOTE, but
package tests and later HTML checks did not run after installation failed. The
whole six jobs remain failed. No ignored error, lower floor or retry is substituted
for the required automatic matrix on the corrected source.
