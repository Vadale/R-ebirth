//! Rust PR CI, CPU/download-free: actual pinned decoder, exhaustive rewrite
//! comparison, adversarial UTF-8/stops, and bounded retained capacities.

use super::*;
use std::ffi::CString;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A tiny vocabulary-only GGUF. No tensors, model inference, golden mutations,
/// Python package or download is needed to call the actual pinned detokenizer.
struct Vocab {
    model: *mut ffi::llama_model,
    vocab: *const ffi::llama_vocab,
    path: PathBuf,
}

fn gguf_string(output: &mut Vec<u8>, text: &str) {
    output.extend_from_slice(&(text.len() as u64).to_le_bytes());
    output.extend_from_slice(text.as_bytes());
}

fn gguf_key(output: &mut Vec<u8>, key: &str, kind: u32) {
    gguf_string(output, key);
    output.extend_from_slice(&kind.to_le_bytes());
}

impl Vocab {
    fn new(add_space: bool) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "relm-stream-vocab-{}-{}.gguf",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut bytes = b"GGUF".to_vec();
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&0u64.to_le_bytes()); // no tensors
        bytes.extend_from_slice(&9u64.to_le_bytes()); // metadata pairs
        for (key, value) in [
            ("general.architecture", "llama"),
            ("tokenizer.ggml.model", "gpt2"),
            ("tokenizer.ggml.pre", "default"),
        ] {
            gguf_key(&mut bytes, key, 8);
            gguf_string(&mut bytes, value);
        }
        gguf_key(&mut bytes, "tokenizer.ggml.tokens", 9);
        bytes.extend_from_slice(&8u32.to_le_bytes());
        bytes.extend_from_slice(&259u64.to_le_bytes());
        let mut extra = 0u32;
        for byte in 0u32..256 {
            // GPT-2's lossless byte alphabet (the tokenizer's public format).
            let scalar = if (33..=126).contains(&byte) || (161..=172).contains(&byte) || byte >= 174
            {
                byte
            } else {
                extra += 1;
                255 + extra
            };
            gguf_string(&mut bytes, &char::from_u32(scalar).unwrap().to_string());
        }
        for token in ["<|endoftext|>", "<special>", "user-defined"] {
            gguf_string(&mut bytes, token);
        }
        gguf_key(&mut bytes, "tokenizer.ggml.token_type", 9);
        bytes.extend_from_slice(&5u32.to_le_bytes());
        bytes.extend_from_slice(&259u64.to_le_bytes());
        for id in 0..259 {
            let kind: i32 = match id {
                256 | 257 => 3,
                258 => 4,
                _ => 1,
            };
            bytes.extend_from_slice(&kind.to_le_bytes());
        }
        gguf_key(&mut bytes, "tokenizer.ggml.merges", 9);
        bytes.extend_from_slice(&8u32.to_le_bytes());
        bytes.extend_from_slice(&0u64.to_le_bytes());
        for key in ["tokenizer.ggml.bos_token_id", "tokenizer.ggml.eos_token_id"] {
            gguf_key(&mut bytes, key, 4);
            bytes.extend_from_slice(&256u32.to_le_bytes());
        }
        gguf_key(&mut bytes, "tokenizer.ggml.add_space_prefix", 7);
        bytes.push(u8::from(add_space));
        bytes.resize(bytes.len().div_ceil(32) * 32, 0);
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        file.write_all(&bytes).unwrap();
        drop(file);
        let name = CString::new(path.to_str().unwrap()).unwrap();
        // SAFETY: the file and C string live through load; vocab_only needs no
        // backend/tensors. Tests own the process-wide native execution guard.
        let (model, vocab) = unsafe {
            let mut params = ffi::llama_model_default_params();
            params.vocab_only = true;
            params.n_gpu_layers = 0;
            params.load_mode = ffi::LLAMA_LOAD_MODE_NONE;
            let model = ffi::llama_model_load_from_file(name.as_ptr(), params);
            assert!(!model.is_null(), "tiny vocabulary must load");
            (model, ffi::llama_model_get_vocab(model))
        };
        assert_eq!(decoder_flags(vocab), (add_space, true));
        Self { model, vocab, path }
    }

    fn decode(&self, ids: &[i32]) -> Vec<u8> {
        let mut bytes = vec![0u8; ids.len() * 16 + 16];
        // SAFETY: fixture ids are in range; the engine writes at most capacity.
        let n = unsafe {
            ffi::llama_detokenize(
                self.vocab,
                ids.as_ptr(),
                ids.len() as i32,
                bytes.as_mut_ptr().cast(),
                bytes.len() as i32,
                false,
                false,
            )
        };
        assert!(n >= 0);
        bytes.truncate(n as usize);
        bytes
    }

    fn piece(&self, id: i32, first: bool) -> Vec<u8> {
        let mut bytes = vec![0u8; 32];
        let lstrip = i32::from(first && decoder_flags(self.vocab).0);
        // SAFETY: the fixture vocabulary is live, id is in range, and all its
        // decoded pieces fit this explicitly sized buffer.
        let n = unsafe {
            ffi::llama_token_to_piece(
                self.vocab,
                id,
                bytes.as_mut_ptr().cast(),
                bytes.len() as i32,
                lstrip,
                false,
            )
        };
        assert!(n >= 0);
        bytes.truncate(n as usize);
        bytes
    }
}

impl Drop for Vocab {
    fn drop(&mut self) {
        // SAFETY: the fixture uniquely owns the model; vocabulary dies with it.
        unsafe { ffi::llama_model_free(self.model) };
        std::fs::remove_file(&self.path).unwrap();
    }
}

#[test]
fn pinned_detokenize_source_requires_revalidation_on_vendor_changes() {
    let source = include_str!("../../../../llama.cpp/src/llama-vocab.cpp");
    let body = source
        .split("int32_t llama_vocab::impl::detokenize(\n")
        .nth(1)
        .unwrap()
        .split("\nvoid llama_vocab::impl::print_info()")
        .next()
        .unwrap();
    // Exact body-byte pin, including the deliberate no-op 't/'d/'ll branches.
    assert_eq!(
        body,
        include_str!("../../tests/fixtures/stream/b10828-detokenize.txt"),
        "revalidate the streaming proof before changing the decoder pin"
    );
}

#[test]
fn cleanup_transducers_match_actual_pinned_decoder_exhaustively() {
    let _native = crate::NativeGuard::try_acquire("stream decoder fixture").unwrap();
    let vocab = Vocab::new(false);
    // All words of length <= 7 over representatives of every interacting byte
    // class. '?'/'!'/',', 'm', and 'v' have identical predicates to '.', 's',
    // and 'r'; separate adversarial fixtures exercise those concrete bytes.
    let alphabet = b" '.srex";
    let mut words = 0usize;
    for len in 0..=7u32 {
        for mut index in 0..alphabet.len().pow(len) {
            let mut ids = vec![0; len as usize];
            for id in &mut ids {
                *id = i32::from(alphabet[index % alphabet.len()]);
                index /= alphabet.len();
            }
            let expected = vocab.decode(&ids);
            let mut cleanup = Cleanup::new();
            let mut stable = Vec::new();
            for &id in &ids {
                stable.extend_from_slice(cleanup.push(id as u8).as_slice());
                assert!(expected.starts_with(&stable), "irrevocable prefix: {ids:?}");
                assert!(cleanup.punctuation.len <= 1);
                assert!(cleanup.apostrophe.len <= 2);
                assert!(cleanup.contractions.len <= 3);
            }
            stable.extend_from_slice(cleanup.finish().as_slice());
            assert_eq!(stable, expected, "full cleanup: {ids:?}");
            words += 1;
        }
    }
    assert_eq!(words, 960800);
}

fn stream_ids(vocab: &Vocab, ids: &[i32], stops: &[String]) -> (String, usize) {
    let mut stream = TextStream::new(true, false, 4096, stops);
    let mut emitted = String::new();
    for (index, &id) in ids.iter().enumerate() {
        let snapshot = String::from_utf8_lossy(&vocab.decode(&ids[..=index])).into_owned();
        let stop = stops
            .iter()
            .filter(|s| !s.is_empty())
            .filter_map(|s| snapshot.find(s.as_str()))
            .min();
        if let Some(cut) = stop {
            emitted.push_str(stream.finish(&snapshot[..cut]).unwrap());
            assert_eq!(emitted, snapshot[..cut]);
            return (emitted, index + 1);
        }
        emitted.push_str(stream.push(&vocab.piece(id, index == 0)).unwrap());
        assert!(snapshot.starts_with(&emitted));
    }
    let final_text = String::from_utf8_lossy(&vocab.decode(ids)).into_owned();
    emitted.push_str(stream.finish(&final_text).unwrap());
    assert_eq!(emitted, final_text);
    (emitted, ids.len())
}

#[test]
fn actual_decoder_covers_cleanup_utf8_empty_special_and_stop_boundaries() {
    let _native = crate::NativeGuard::try_acquire("stream adversarial fixture").unwrap();
    for add_space in [false, true] {
        let vocab = Vocab::new(add_space);
        for raw in [
            b"  hello ? ! . , ' world 's 'm 're 've 't 'd 'll".as_slice(),
            b" ' '  '  're   've 's 'm".as_slice(),
            " è 😀 \u{fffd} end".as_bytes(),
            &[b'x', 0xf0, 0x9f, 0x98],
            &[b'x', 0xff, 0xe2, b'a', 0x80, 0xc0, 0xed, 0xa0, 0x80],
        ] {
            let mut ids: Vec<i32> = raw.iter().map(|&byte| i32::from(byte)).collect();
            // Empty pieces at every boundary defeat adjacent-snapshot LCP.
            ids = ids.into_iter().flat_map(|id| [id, 257, 256]).collect();
            stream_ids(&vocab, &ids, &[]);
        }
        assert!(vocab.piece(257, false).is_empty());
        assert!(vocab.piece(256, false).is_empty());
        assert_eq!(vocab.piece(258, false), b"user-defined");
        // A first empty piece consumes the leading-space flag, as native does.
        assert_eq!(stream_ids(&vocab, &[257, 32, 97], &[]).0, " a");
        assert_eq!(stream_ids(&vocab, &[], &[]).0, "");
        assert_eq!(stream_ids(&vocab, &[258], &[]).0, "user-defined");
        for (raw, stops, expected, sampled) in [
            (b"abcSTOPtail".as_slice(), vec!["STOP", "TOP"], "abc", 7),
            (b"xababatail".as_slice(), vec!["ababa", "baba"], "x", 6),
            (b"hi 'retail".as_slice(), vec!["'re"], "hi", 6),
            (&[b'a', 0xe2, 0x82, 0xac], vec!["\u{fffd}"], "a", 2),
            (&[b'a', 0xe2, 0x82, 0xac], vec!["a\u{fffd}"], "", 2),
            ("é😀end".as_bytes(), vec!["😀"], "é", 6),
        ] {
            let ids: Vec<i32> = raw.iter().map(|&byte| i32::from(byte)).collect();
            let stops: Vec<String> = stops.into_iter().map(str::to_owned).collect();
            assert_eq!(
                stream_ids(&vocab, &ids, &stops),
                (expected.to_owned(), sampled)
            );
        }
    }
}

#[test]
fn utf8_prefix_matches_rust_lossy_and_keeps_incomplete_characters() {
    // Enumerate all byte pairs plus targeted 3/4-byte sequences. This checks
    // Rust's maximal invalid-subsequence grouping, not per-token conversion.
    for first in 1..=255u8 {
        for second in 1..=255u8 {
            let raw = [first, second];
            let mut stream = TextStream::new(false, false, 12, &[]);
            let mut emitted = String::new();
            for byte in raw {
                emitted.push_str(stream.push(&[byte]).unwrap());
                assert!(String::from_utf8_lossy(&raw).starts_with(&emitted));
            }
            let authority = String::from_utf8_lossy(&raw);
            emitted.push_str(stream.finish(&authority).unwrap());
            assert_eq!(emitted, authority);
        }
    }
    let mut stream = TextStream::new(false, false, 16, &[]);
    assert_eq!(stream.push(&[0xf0, 0x9f]).unwrap(), "");
    assert_eq!(stream.push(&[]).unwrap(), "");
    assert_eq!(stream.push(&[0x98, 0x80]).unwrap(), "😀");
    assert_eq!(stream.finish("😀").unwrap(), "");
}

#[test]
fn structured_stream_preserves_raw_spaces_and_rejects_invalid_text() {
    let raw = "{\"s\":\" a 's ? 😀\"}";
    let mut stream = TextStream::new(false, true, 128, &[]);
    let mut emitted = String::new();
    for &byte in raw.as_bytes() {
        emitted.push_str(stream.push(&[byte]).unwrap());
    }
    emitted.push_str(stream.finish(raw).unwrap());
    assert_eq!(emitted, raw);
    assert!(
        matches!(stream.finish("different"), Err(RebirthError::Stream { reason, .. }) if reason == "invariant")
    );
    for strict in [false, true] {
        let mut stream = TextStream::new(false, strict, 16, &[]);
        assert!(
            matches!(stream.push(b"a\0"), Err(RebirthError::Stream { reason, .. }) if reason == "encoding")
        );
        assert!(
            matches!(stream.finish("a\0"), Err(RebirthError::Stream { reason, .. }) if reason == "encoding")
        );
    }
    let mut strict = TextStream::new(false, true, 16, &[]);
    assert!(
        matches!(strict.push(&[0xff]), Err(RebirthError::Stream { reason, .. }) if reason == "encoding")
    );
}

#[test]
fn stream_storage_is_bounded_and_text_arrives_before_finish() {
    let mut stream = TextStream::new(true, false, 64, &[]);
    assert_eq!(stream.push(b"hello ").unwrap(), "hello");
    assert_eq!(stream.push(b"world E").unwrap(), " world E");
    assert!(stream.text.capacity() <= 64);
    assert!(std::mem::size_of::<TextStream>() < 1024);
    let mut stream = TextStream::new(false, false, 3, &[]);
    assert_eq!(stream.push(b"abc").unwrap(), "abc");
    assert!(matches!(stream.push(b"d"), Err(RebirthError::Oom { .. })));
    assert!(stream.text.capacity() <= 3);
}

#[test]
fn stop_holdback_is_constant_work_for_a_maximum_size_near_match() {
    let size = crate::async_job::ASYNC_MAX_OUTPUT_BYTES;
    let half = "a".repeat(size / 2);
    // This legal stop and text forced the former suffix matcher to compare
    // quadratically many bytes: every candidate nearly matches a long prefix.
    let stops = [format!("{half}b{half}")];
    let mut stream = TextStream::new(false, false, size, &stops);
    assert_eq!(stream.stop_holdback, size);
    // Populate the existing committed-text buffer directly to isolate the
    // matcher regression from per-byte decoding/allocation work.
    stream.text = "a".repeat(size);
    assert_eq!(stream.push(b"").unwrap(), "");
    assert_eq!(stream.text.capacity(), size);
    assert_eq!(stream.finish(&stream.text).unwrap().len(), size);
    // Stops are not retained or copied by the decoder; only one usize is kept.
    drop(stops);
    assert_eq!(stream.stop_holdback, size);
}

#[test]
fn stop_holdback_rounds_back_to_utf8_and_ignores_empty_stops() {
    let stops = [String::new(), "END".to_owned(), "xx".to_owned()];
    let mut stream = TextStream::new(false, false, 32, &stops);
    assert_eq!(stream.stop_holdback, 2);
    // Six bytes minus two points inside the four-byte emoji: keep the whole
    // character, then release it as soon as two following bytes are available.
    assert_eq!(stream.push("a😀x".as_bytes()).unwrap(), "a");
    assert_eq!(stream.push(b"y").unwrap(), "😀");
    assert_eq!(stream.finish("a😀xy").unwrap(), "xy");
    let mut empty = TextStream::new(false, false, 8, &[String::new()]);
    assert_eq!(empty.stop_holdback, 0);
    assert_eq!(empty.push(b"ready").unwrap(), "ready");
}
