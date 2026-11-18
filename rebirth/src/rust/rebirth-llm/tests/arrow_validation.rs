// Runs in the ordinary R-free engine job. No model or native fixture is needed.
#![cfg(feature = "spill")]

use arrow_array::types::Int32Type;
use arrow_array::{Array, Float32Array, Int32Array, RunArray};

#[test]
fn run_end_encoded_data_refuses_a_slice_beyond_the_last_run() {
    let ends = Int32Array::from(vec![1, 3]);
    let values = Float32Array::from(vec![1.5, 2.5]);
    let data = RunArray::<Int32Type>::try_new(&ends, &values)
        .expect("the two runs cover exactly three values")
        .to_data();

    // The final run ends at 3. Both the whole length and offset + length
    // must fit, before any typed reader can access a child value.
    for (offset, length) in [(0, 4), (2, 2)] {
        let result = data
            .clone()
            .into_builder()
            .offset(offset)
            .len(length)
            .build();
        assert!(
            result.is_err(),
            "accepted an out-of-bounds run slice, offset={offset}, length={length}"
        );
    }

    for (offset, length) in [(0, 3), (1, 2), (4, 0)] {
        data.clone()
            .into_builder()
            .offset(offset)
            .len(length)
            .build()
            .expect("a valid or empty run slice remains supported");
    }
}
