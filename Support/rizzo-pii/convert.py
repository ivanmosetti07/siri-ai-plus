"""Converte il modello rizzo-pii (ModernBERT/mmBERT, 0.3B, licenza MIT) in Core ML per Siri AI+.

Uso (una volta, solo per preparare il motore: Siri AI+ non usa Python):
    python convert.py <cartella-modello-hf> <cartella-uscita>

Nella cartella di uscita: RizzoPII.mlpackage (pesi fp16; 64, 128, 256 o 512 token), tokenizer.json e config.json.
Siri AI+ li cerca in ~/Library/Application Support/Siri AI+/Models/rizzo-pii/.

Il modello di transformers non si traccia così com'è (ricava batch e lunghezza dalle forme, e coremltools
non converte quei passaggi): `Export` rifà lo stesso calcolo con gli stessi pesi, con batch 1, posizioni
dalla maschera e maschere additive a -1e4 (sicure in fp16). `check` confronta le due versioni prima di convertire.
"""
import json
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn
from transformers import AutoModelForTokenClassification

SHAPES = [64, 128, 256, 512]
NEG = -1e4


def rotate_half(x):
    a, b = x.chunk(2, dim=-1)
    return torch.cat((-b, a), dim=-1)


class Export(nn.Module):
    """ModernBertForTokenClassification, stesso calcolo in forma tracciabile."""

    def __init__(self, hf):
        super().__init__()
        cfg = hf.config
        m = hf.model
        self.tok = m.embeddings.tok_embeddings
        self.emb_norm = m.embeddings.norm
        self.layers = m.layers
        self.final_norm = m.final_norm
        self.head = hf.head
        self.classifier = hf.classifier
        self.heads = cfg.num_attention_heads
        self.head_dim = cfg.hidden_size // cfg.num_attention_heads
        self.hidden = cfg.hidden_size
        self.window = cfg.local_attention // 2
        self.every = cfg.global_attn_every_n_layers
        self.register_buffer("inv_global", self.inv_freq(cfg.global_rope_theta), persistent=False)
        self.register_buffer("inv_local", self.inv_freq(cfg.local_rope_theta if cfg.local_rope_theta else cfg.global_rope_theta), persistent=False)

    def inv_freq(self, theta):
        return 1.0 / (theta ** (torch.arange(0, self.head_dim, 2, dtype=torch.float32) / self.head_dim))

    def rope(self, pos, inv):
        freqs = pos[..., None] * inv                     # 1, L, d/2
        emb = torch.cat((freqs, freqs), dim=-1)          # 1, L, d
        return emb.cos()[:, None], emb.sin()[:, None]    # 1, 1, L, d

    def forward(self, input_ids, attention_mask):
        mask = attention_mask.to(torch.float32)
        pos = torch.cumsum(mask, dim=-1) - 1.0           # posizioni 0…n-1 senza leggere la lunghezza
        glob = ((1.0 - mask) * NEG)[:, None, None, :]   # 1, 1, 1, L
        dist = torch.abs(pos[:, :, None] - pos[:, None, :])
        local = glob + (dist > self.window).to(torch.float32)[:, None] * NEG
        cos_g, sin_g = self.rope(pos, self.inv_global)
        cos_l, sin_l = self.rope(pos, self.inv_local)
        x = self.emb_norm(self.tok(input_ids))
        scale = self.head_dim ** -0.5
        for i, layer in enumerate(self.layers):
            is_global = i % self.every == 0
            h = layer.attn_norm(x)
            qkv = layer.attn.Wqkv(h).reshape(1, -1, 3, self.heads, self.head_dim).permute(2, 0, 3, 1, 4)
            q, k, v = qkv[0], qkv[1], qkv[2]              # 1, H, L, d
            cos, sin = (cos_g, sin_g) if is_global else (cos_l, sin_l)
            q = q * cos + rotate_half(q) * sin
            k = k * cos + rotate_half(k) * sin
            scores = torch.matmul(q, k.transpose(-1, -2)) * scale + (glob if is_global else local)
            out = torch.matmul(torch.softmax(scores, dim=-1), v).transpose(1, 2).reshape(1, -1, self.hidden)
            x = x + layer.attn.Wo(out)
            a, g = layer.mlp.Wi(layer.mlp_norm(x)).chunk(2, dim=-1)
            x = x + layer.mlp.Wo(layer.mlp.act(a) * g)
        x = self.final_norm(x)
        return self.classifier(self.head(x))


def check(hf, export):
    """Le due versioni devono dare gli stessi logit (anche con padding a destra)."""
    torch.manual_seed(0)
    for n in (17, 130, 300):
        ids = torch.randint(10, 250000, (1, n))
        full = torch.ones(1, n, dtype=torch.long)
        with torch.no_grad():
            ref = hf(input_ids=ids, attention_mask=full).logits
            out = export(ids, full)
            padded = export(torch.cat([ids, torch.zeros(1, 40, dtype=torch.long)], 1),
                            torch.cat([full, torch.zeros(1, 40, dtype=torch.long)], 1))[:, :n]
        print(f"n={n}: differenza massima {float((ref - out).abs().max()):.2e}, con padding {float((ref - padded).abs().max()):.2e},"
              f" stesse etichette {bool((ref.argmax(-1) == padded.argmax(-1)).all())}")


def main(source, target):
    source, target = Path(source), Path(target)
    target.mkdir(parents=True, exist_ok=True)
    hf = AutoModelForTokenClassification.from_pretrained(source, attn_implementation="eager", torch_dtype=torch.float32).eval()
    export = Export(hf).eval()
    check(hf, export)
    ids = torch.randint(10, 1000, (1, 128), dtype=torch.int32)
    mask = torch.ones(1, 128, dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(export, (ids, mask), check_trace=False)
    shape = ct.EnumeratedShapes(shapes=[[1, n] for n in SHAPES], default=[1, 128])
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    config = json.loads((source / "config.json").read_text())
    mlmodel.short_description = "rizzo-pii 0.3B (Rizzo AI Academy, MIT): riconoscimento di dati personali in italiano"
    mlmodel.user_defined_metadata["id2label"] = json.dumps(config["id2label"])
    mlmodel.save(str(target / "RizzoPII.mlpackage"))
    for name in ("tokenizer.json", "config.json"):
        shutil.copy(source / name, target / name)
    print("Salvato in", target)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
