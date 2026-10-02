//! Irrevocable text prefixes for the pinned b10828 detokenizer (D-038).
//!
//! Each cleanup pass is a left-to-right, non-overlapping rewrite which deletes
//! only the leading space of a matching pattern (pass 2 also consumes its last
//! space). A pass retains exactly a proper pattern prefix, never a guessed
//! suffix of a cleaned snapshot. Its retained input is at most 1/2/3 bytes.
//! Forwarded bytes cannot participate in any future match, so composing the
//! three passes preserves this property. Empty token pieces cannot advance it.
//! See docs/wp10-text-decoder.md for the source correspondence and proof.

use crate::{ffi, RebirthError};

extern "C" {
    fn relm_stream_decoder_flags(vocab: *const ffi::llama_vocab) -> u32;
}

pub(crate) fn decoder_flags(vocab: *const ffi::llama_vocab) -> (bool, bool) {
    crate::domain::assert_current();
    // SAFETY: the caller borrows a live model vocabulary in the native domain.
    let flags = unsafe { relm_stream_decoder_flags(vocab) };
    (flags & 1 != 0, flags & 2 != 0)
}

const PUNCTUATION: &[&[u8]] = &[b" ?", b" !", b" .", b" ,"];
const APOSTROPHE: &[&[u8]] = &[b" ' "];
const CONTRACTIONS: &[&[u8]] = &[b" 's", b" 'm", b" 're", b" 've"];

#[derive(Default)]
struct Bytes {
    // One input byte can release the six retained bytes of the whole pipeline.
    bytes: [u8; 8],
    len: usize,
}

impl Bytes {
    fn push(&mut self, byte: u8) {
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    fn as_slice(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}

struct Rewrite {
    patterns: &'static [&'static [u8]],
    pending: [u8; 4],
    len: usize,
    strip_last: bool,
}

impl Rewrite {
    fn new(patterns: &'static [&'static [u8]], strip_last: bool) -> Self {
        Self {
            patterns,
            pending: [0; 4],
            len: 0,
            strip_last,
        }
    }

    fn push(&mut self, byte: u8) -> Bytes {
        self.pending[self.len] = byte;
        self.len += 1;
        let mut output = Bytes::default();
        while self.len != 0 {
            let pending = &self.pending[..self.len];
            if self.patterns.contains(&pending) {
                // The native apostrophe pass consumes both bordering spaces;
                // all other replacements consume just the leading space.
                let end = self.len - usize::from(self.strip_last);
                for &byte in &pending[1..end] {
                    output.push(byte);
                }
                self.len = 0;
            } else if self
                .patterns
                .iter()
                .any(|pattern| pattern.starts_with(pending))
            {
                break;
            } else {
                output.push(self.pending[0]);
                self.pending.copy_within(1..self.len, 0);
                self.len -= 1;
            }
        }
        output
    }

    #[cfg(test)]
    fn finish(&mut self) -> Bytes {
        let mut output = Bytes::default();
        for &byte in &self.pending[..self.len] {
            output.push(byte);
        }
        self.len = 0;
        output
    }
}

struct Cleanup {
    punctuation: Rewrite,
    apostrophe: Rewrite,
    contractions: Rewrite,
}

impl Cleanup {
    fn new() -> Self {
        Self {
            punctuation: Rewrite::new(PUNCTUATION, false),
            apostrophe: Rewrite::new(APOSTROPHE, true),
            contractions: Rewrite::new(CONTRACTIONS, false),
        }
    }

    fn push(&mut self, byte: u8) -> Bytes {
        let mut output = Bytes::default();
        for &byte in self.punctuation.push(byte).as_slice() {
            self.after_punctuation(byte, &mut output);
        }
        output
    }

    fn after_punctuation(&mut self, byte: u8, output: &mut Bytes) {
        for &byte in self.apostrophe.push(byte).as_slice() {
            for &byte in self.contractions.push(byte).as_slice() {
                output.push(byte);
            }
        }
    }

    #[cfg(test)]
    fn finish(&mut self) -> Bytes {
        let mut output = Bytes::default();
        for &byte in self.punctuation.finish().as_slice() {
            self.after_punctuation(byte, &mut output);
        }
        for &byte in self.apostrophe.finish().as_slice() {
            for &byte in self.contractions.push(byte).as_slice() {
                output.push(byte);
            }
        }
        for &byte in self.contractions.finish().as_slice() {
            output.push(byte);
        }
        output
    }
}

#[derive(Default)]
struct Utf8Prefix {
    pending: [u8; 4],
    len: usize,
}

impl Utf8Prefix {
    fn push(
        &mut self,
        byte: u8,
        strict: bool,
        text: &mut String,
        limit: usize,
    ) -> Result<(), RebirthError> {
        self.pending[self.len] = byte;
        self.len += 1;
        loop {
            match std::str::from_utf8(&self.pending[..self.len]) {
                Ok(valid) => {
                    append_bounded(text, valid, limit)?;
                    self.len = 0;
                    return Ok(());
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    // SAFETY: valid_up_to explicitly identifies a UTF-8 prefix.
                    let prefix = unsafe { std::str::from_utf8_unchecked(&self.pending[..valid]) };
                    append_bounded(text, prefix, limit)?;
                    let consumed = match error.error_len() {
                        Some(invalid) => {
                            if strict {
                                return Err(crate::async_job::stream_error("encoding"));
                            }
                            append_bounded(text, "\u{fffd}", limit)?;
                            valid + invalid
                        }
                        None => {
                            self.pending.copy_within(valid..self.len, 0);
                            self.len -= valid;
                            return Ok(());
                        }
                    };
                    self.pending.copy_within(consumed..self.len, 0);
                    self.len -= consumed;
                }
            }
        }
    }
}

fn append_bounded(text: &mut String, suffix: &str, limit: usize) -> Result<(), RebirthError> {
    if suffix.as_bytes().contains(&0) {
        return Err(crate::async_job::stream_error("encoding"));
    }
    let size = text
        .len()
        .checked_add(suffix.len())
        .ok_or_else(|| crate::async_job::output_budget_error(usize::MAX))?;
    if size > limit {
        return Err(crate::async_job::output_budget_error(size));
    }
    // No geometric allocation beyond the current prompt's remaining budget.
    text.reserve_exact(suffix.len());
    text.push_str(suffix);
    Ok(())
}

/// Holds one bounded committed-prefix string. `sent` separates delivered text
/// from a conservative stop suffix; only the maximum stop length is retained.
pub(crate) struct TextStream {
    cleanup: Option<Cleanup>,
    utf8: Utf8Prefix,
    strict: bool,
    text: String,
    sent: usize,
    limit: usize,
    stop_holdback: usize,
}

impl TextStream {
    pub(crate) fn new(clean_spaces: bool, strict: bool, limit: usize, stops: &[String]) -> Self {
        Self {
            cleanup: clean_spaces.then(Cleanup::new),
            utf8: Utf8Prefix::default(),
            strict,
            text: String::new(),
            sent: 0,
            limit,
            stop_holdback: stops
                .iter()
                .map(String::len)
                .max()
                .unwrap_or(0)
                .saturating_sub(1),
        }
    }

    /// Call only AFTER the authoritative whole-snapshot stop check. Bytes are
    /// native special=false pieces, with native first-token lstrip already used.
    pub(crate) fn push(&mut self, piece: &[u8]) -> Result<&str, RebirthError> {
        for &byte in piece {
            if let Some(cleanup) = &mut self.cleanup {
                for &byte in cleanup.push(byte).as_slice() {
                    self.utf8
                        .push(byte, self.strict, &mut self.text, self.limit)?;
                }
            } else {
                self.utf8
                    .push(byte, self.strict, &mut self.text, self.limit)?;
            }
        }
        // A newly completed stop can start at most max_stop_bytes - 1 bytes
        // before this boundary. This bound needs no text scan or matcher table.
        // Rounding backward inspects at most three UTF-8 continuation bytes.
        let mut end = self.text.len().saturating_sub(self.stop_holdback);
        while !self.text.is_char_boundary(end) {
            end -= 1;
        }
        if end < self.sent {
            return Err(crate::async_job::stream_error("invariant"));
        }
        let start = self.sent;
        self.sent = end;
        Ok(&self.text[start..end])
    }

    /// Terminal conversion is exclusively the unchanged Generation.text. In
    /// particular it decides whether an incomplete UTF-8 suffix becomes U+FFFD.
    pub(crate) fn finish<'a>(&self, authority: &'a str) -> Result<&'a str, RebirthError> {
        if authority.as_bytes().contains(&0) {
            return Err(crate::async_job::stream_error("encoding"));
        }
        if !authority.starts_with(&self.text[..self.sent]) {
            return Err(crate::async_job::stream_error("invariant"));
        }
        Ok(&authority[self.sent..])
    }
}

#[cfg(test)]
mod tests;
