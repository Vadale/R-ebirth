"""Maintained HF CPU environment smoke test; no downloaded/reference model replay.

Run in a fresh requirements-hf environment. A new tiny random checkpoint exercises
our actual frozen producer loader, without producing or comparing golden outputs.
"""
import importlib.metadata
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import torch
from tokenizers import Tokenizer
from tokenizers.models import WordLevel
from transformers import PreTrainedTokenizerFast, Qwen2Config, Qwen2ForCausalLM
import reference_forward_hf as reference


class EnvironmentControls(unittest.TestCase):
    def test_patched_torch_without_accelerate(self):
        self.assertEqual(importlib.metadata.version("torch").split("+")[0], "2.13.0")
        self.assertIsNone(importlib.util.find_spec("accelerate"))
        unit = torch.jit.CompilationUnit("def add_one(x: Tensor) -> Tensor:\n    return x + 1\n")
        self.assertTrue(torch.equal(unit.add_one(torch.tensor([1., 2.])), torch.tensor([2., 3.])))

    def test_actual_cpu_loader_without_accelerate(self):
        torch.manual_seed(21023)
        config = Qwen2Config(vocab_size=4, hidden_size=8, intermediate_size=16,
                             num_hidden_layers=1, num_attention_heads=2,
                             num_key_value_heads=1, max_position_embeddings=32)
        original = Qwen2ForCausalLM(config).eval()
        tokenizer = PreTrainedTokenizerFast(tokenizer_object=Tokenizer(
            WordLevel({"[UNK]": 0, "a": 1, "b": 2, "c": 3}, unk_token="[UNK]")),
            unk_token="[UNK]")
        with tempfile.TemporaryDirectory() as tmp:
            original.save_pretrained(tmp, safe_serialization=True)
            tokenizer.save_pretrained(tmp)
            with patch("huggingface_hub.snapshot_download", return_value=tmp) as download:
                _, _, loaded, path = reference._load()
                download.assert_called_once_with(reference.MODEL_ID)
            self.assertEqual(path, tmp)
            self.assertFalse(loaded.training)
            self.assertEqual(next(loaded.parameters()).device.type, "cpu")
            self.assertEqual(next(loaded.parameters()).dtype, torch.float32)
            self.assertEqual(set(original.state_dict()), set(loaded.state_dict()))
            for name, expected in original.state_dict().items():
                self.assertTrue(torch.equal(expected, loaded.state_dict()[name]), name)
        self.assertNotIn("accelerate", __import__("sys").modules)
        print("HF_ENV_OK synthetic_checkpoint_loads=1 reference_forwards=0 model_downloads=0")


if __name__ == "__main__":
    unittest.main()
