"""Gate mutations: source drift cannot silently replace the actual adapters.

Runs in the nightly memory-safety harness controls; no native build or model.
"""
import unittest
from cpu_callbacks import GGML, extract_adapters


class CallbackSourceControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (GGML / "src/ggml-cpu/ggml-cpu.c").read_text()

    def test_original_trait_cast_is_rejected(self):
        source = self.source.replace("= ggml_vec_dot_f32_adapter,",
                                     "= (ggml_vec_dot_t) ggml_vec_dot_f32,")
        self.assertNotEqual(source, self.source)
        with self.assertRaisesRegex(RuntimeError, "not directly assigned"):
            extract_adapters(source)

    def test_missing_conversion_assignment_is_rejected(self):
        source = self.source.replace("= ggml_cpu_fp32_to_i32_adapter,", "= NULL,")
        self.assertNotEqual(source, self.source)
        with self.assertRaisesRegex(RuntimeError, "not directly assigned"):
            extract_adapters(source)

    def test_ambiguous_adapter_is_rejected(self):
        adapters = extract_adapters(self.source)
        with self.assertRaisesRegex(RuntimeError, "ambiguous adapter"):
            extract_adapters(self.source + adapters)

    def test_missing_adapter_is_rejected(self):
        source = self.source.replace("static void ggml_vec_dot_f32_adapter(",
                                     "static void renamed_adapter(")
        self.assertNotEqual(source, self.source)
        with self.assertRaisesRegex(RuntimeError, "missing/ambiguous adapter"):
            extract_adapters(source)


if __name__ == "__main__":
    unittest.main()
