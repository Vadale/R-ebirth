# F6b integration compile failure: no product tests executed

Source manifest: acf1878bea7f0128a4b88aa3ca3633f09fb52d18241379b49a6d6e14791cd86e.
Format passed. The enlarged-error lint is no longer reported. Compilation then
found three integration mismatches: the existing async_synthetic fixture lacked
the new model_invalidated field; the included FFI file imported ModelMetadata
already present in its parent module; and shape preflight expected u64 values
where FFI supplied usize. No functional test ran. Correct only these mechanical
interfaces, preserve the failed run and run the still-unexecuted affected gates.
The independent review's probe/R allocation corrections are source-reviewed,
not yet execution acceptance. No warning suppression or threshold change.
