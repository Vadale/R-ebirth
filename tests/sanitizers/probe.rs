//! Isolated nightly control, linked to instrumented C and C++ objects.
extern "C" {
    fn c_probe(mode: i32) -> i32;
    fn cpp_probe(mode: i32) -> i32;
}
fn main() {
    let mode = std::env::args().nth(1).expect("probe mode");
    unsafe {
        match mode.as_str() {
            "safe" => {
                assert_eq!(c_probe(0), 42);
                assert_eq!(cpp_probe(0), 42);
                println!("mixed-language safe control executed");
            }
            "c-asan" => {
                std::hint::black_box(c_probe(1));
            }
            "cpp-asan" => {
                std::hint::black_box(cpp_probe(1));
            }
            "cpp-ubsan" => {
                std::hint::black_box(cpp_probe(2));
            }
            "rust-asan" => {
                // A raw load is deliberate: a bounds-check panic is not ASan proof.
                let values = [0_u64; 4];
                let index = std::hint::black_box(4);
                std::hint::black_box(std::ptr::read_volatile(values.as_ptr().add(index)));
            }
            _ => panic!("unknown probe mode"),
        }
    }
}
