"""Meaning search's model folder (docs/plans/2026-10-28-meaning-search.md), run by make_model.sh in its throwaway venv.

    meaning.py convert SOURCES OUT FIXTURES   bge-small-en-v1.5 to Core ML at half and full precision, plus vocab.txt;
                                              refused unless Core ML's numbers match the original's on the fixtures' texts
    meaning.py fixtures SOURCES REPO          rewrite the Swift tests' fixtures (MeaningTests) from the original, on
                                              made-up texts only

The original is the PyTorch model at the pinned revision; the trial showed its ONNX copy and Core ML agree to the sixth
place (docs/research/2026-10-28-mlx-evaluation.md, "The Core ML trial").
"""
import json
import os
import sys
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"

import numpy as np  # noqa: E402
import torch  # noqa: E402
from tokenizers import Tokenizer  # noqa: E402
from transformers import BertModel  # noqa: E402

SEARCH_PREFIX = "Represent this sentence for searching relevant passages: "
FIXTURES = "app/Meaning/Tests/MeaningSearchTests/Fixtures/meaning"
# How close Core ML's numbers must be to the original's (cosine): the trial's worst were 1.000000 and 0.999969
LEAST = {"fp32": 0.9999, "fp16": 0.999}
# Texts the splitter gets wrong first when a rule is missed: accents, punctuation, apostrophes, Chinese characters,
# emoji, control characters, a word over 100 characters, blank text
AWKWARD = ["Café, naïve résumé", "don't—stop… “now”", "日本語のテキスト", "🔥 fire 🔥", "tab\there\nnew line\r",
           "CO₂ at 3.5 mg/L (about 0.35%)", "911!!! #help @home", "x" * 120, "", "   ", "éclair​",
           "pre-K kids' first-aid kit", "ÀÉÎÕÜ ß æ ø"]


class Embedder(torch.nn.Module):
    def __init__(self, sources):
        super().__init__()
        self.bert = BertModel.from_pretrained(sources, attn_implementation="eager", add_pooling_layer=False).eval()

    def forward(self, input_ids, attention_mask):
        # the additive mask built here, not by transformers' masking helpers, which coremltools can't convert
        x = self.bert.embeddings(input_ids=input_ids, token_type_ids=torch.zeros_like(input_ids))
        mask = (1.0 - attention_mask[:, None, None, :].to(x.dtype)) * -10000.0
        h = self.bert.encoder(x, attention_mask=mask).last_hidden_state[:, 0]
        return torch.nn.functional.normalize(h, dim=-1)


def splitter(sources):
    tok = Tokenizer.from_file(f"{sources}/tokenizer.json")
    tok.enable_truncation(512)
    return tok


def original(model, tok, text):
    ids = torch.tensor([tok.encode(text).ids], dtype=torch.int32)
    with torch.no_grad():
        return model(ids, torch.ones_like(ids))[0].numpy()


def convert(sources, out, fixtures):
    import coremltools as ct

    out = Path(out)
    model, tok = Embedder(sources).eval(), splitter(sources)
    vocab = tok.get_vocab()
    words = sorted(vocab, key=vocab.get)
    assert [vocab[w] for w in words] == list(range(len(words))), "the vocabulary's ids aren't 0 to N-1"
    (out / "vocab.txt").write_text("\n".join(words) + "\n", encoding="utf-8")
    texts = [case["text"] for case in json.loads(Path(fixtures, "vectors.json").read_text())]
    traced = torch.jit.trace(model, (torch.ones(1, 16, dtype=torch.int32), torch.ones(1, 16, dtype=torch.int32)))
    seq = ct.RangeDim(lower_bound=1, upper_bound=512, default=16)
    for name, precision in (("fp32", ct.precision.FLOAT32), ("fp16", ct.precision.FLOAT16)):
        ml = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                        inputs=[ct.TensorType("input_ids", shape=(1, seq), dtype=np.int32),
                                ct.TensorType("attention_mask", shape=(1, seq), dtype=np.int32)],
                        outputs=[ct.TensorType("embedding")], compute_precision=precision)
        ml.short_description = "bge-small-en-v1.5 (BAAI, MIT), revision 5c38ec7c, CLS vector normalized"
        worst = 1.0
        for text in texts:
            ids = np.array([tok.encode(text).ids], dtype=np.int32)
            got = ml.predict({"input_ids": ids, "attention_mask": np.ones_like(ids)})["embedding"][0]
            want = original(model, tok, text)
            worst = min(worst, float(np.dot(got, want) / np.linalg.norm(got)))
        if worst < LEAST[name]:
            sys.exit(f"{name}: Core ML's numbers differ from the original's (worst cosine {worst:.6f}); nothing kept")
        ml.save(str(out / f"bge-small-{name}.mlpackage"))
        print(f"{name}: converted; worst cosine with the original {worst:.6f} over {len(texts)} texts")


# The fixtures' texts, all made up (the lead's review of the Unlisted plan's phase 6, 2026-11-23): the fixtures ship in
# the app's public source, so never a guide's title or brief, a page's text or a search from packer/searchcheck.toml.
# Titles in the library's shape (colons, apostrophes, numbers, dashes, a question), briefs a paragraph long.
TOPICS = ["rain barrels", "porch lights", "bike tires", "sourdough starters", "garden hoses", "space heaters",
          "wool socks", "canned soups", "car batteries", "solar lanterns", "hand-crank radios", "sump pumps",
          "window screens", "water filters", "dog food bins", "baby bottles", "insulin coolers", "reading glasses",
          "spare house keys", "folding cots", "chest freezers", "wheelbarrows", "rubber boots", "duct tape rolls",
          "tarps and rope", "extension cords", "pill organizers", "cat carriers", "N95 masks", "paper plates",
          "thermoses", "ice packs", "road flares", "jumper cables", "tire chains", "gas-free leaf blowers",
          "kitchen timers", "laundry lines", "board games", "seed packets"]
PATTERNS = ["{T}: what to check first", "Storing {t} through a long outage", "When {t} give out at night",
            "{T} 101 — a quick start", "Choosing {t} on a $50 budget", "Why {t} belong in a 72-hour kit",
            "Cleaning {t} after the basement floods", "A kids' guide to {t}"]
BRIEFS = [
    "Explain how a household keeps a rain barrel clean through the summer: a tight lid against mosquitoes, a screen "
    "on the inlet, rinsing it twice a year, and why the water is for the garden and not for drinking unless it is "
    "filtered and boiled first.",
    "Walk a reader through charging phones and a radio from a car battery without running the engine in a closed "
    "garage. Name the adapters people usually own, how long a charge takes, and the one mistake that drains the battery.",
    "Describe a week of meals that need no refrigerator: shelf-stable milk, peanut butter, crackers, canned fish and "
    "fruit. Say how to rotate them into everyday cooking so nothing expires on the shelf.",
    "Cover what to do when the sump pump stops during a storm: check the breaker, the float switch and the outlet, "
    "move valuables upstairs, and when it's time to call someone rather than wade in.",
    "Help a family plan who picks up the kids if the phones are down: a written card in each backpack, a meeting spot "
    "a short walk from school, and a friend out of town everyone calls to check in.",
    "Teach the basics of keeping a cooler cold for three days: pre-chill it, pack it full, keep it in the shade, open it "
    "as little as possible, and use a thermometer so nobody guesses whether the food is still safe.",
    "List the tools for a simple home repair kit (tape, tarps, a utility knife, zip ties, a flashlight) and explain how "
    "to cover a broken window until a glazier can come, without climbing a ladder alone.",
    "Explain how to keep pets calm and safe in a storm: a carrier they already know, two weeks of food, a copy of their "
    "shot records, and a recent photo in case one gets out.",
    "Describe how to stay warm in one room when the heat is out: close off the others, hang blankets over the doors, "
    "layer clothing, eat often, and never bring a grill or camp stove inside.",
    "Walk through checking on an elderly neighbor after a power cut: knock, ask about medicines that need cooling or "
    "power, offer a phone charge, and write down who else on the street can help.",
]
TYPED = ["how do i keep my phone charged with no power", "pet carrier checklist", "warm one room no heat",
         "what goes in a window repair kit", "meals without a fridge for a week", "sump pump stopped",
         "who gets the kids if phones are down", "cooler stays cold how long", "neighbor needs help after outage",
         "rain barrel safe to drink?"]


def fixtures(sources, repo):
    model, tok = Embedder(sources).eval(), splitter(sources)
    titles = [pattern.format(t=topic, T=topic[0].upper() + topic[1:]) for pattern in PATTERNS for topic in TOPICS]
    texts = titles + BRIEFS + TYPED + AWKWARD
    texts += [" ".join(BRIEFS * 2)]  # over 512 pieces: cut to 512
    if len(tok.encode(texts[-1]).ids) != 512:
        raise SystemExit("the long text must run past 512 pieces, to be cut to 512")
    out = Path(repo, FIXTURES)
    out.mkdir(parents=True, exist_ok=True)
    cases = [{"text": t, "ids": tok.encode(t).ids} for t in texts]
    lines = ",\n".join(json.dumps(case, ensure_ascii=False) for case in cases)  # one case a line
    (out / "wordpiece.json").write_text(f"[\n{lines}\n]\n", encoding="utf-8")
    picked = [f"{titles[0]}. {BRIEFS[0]}", SEARCH_PREFIX + TYPED[0], SEARCH_PREFIX + AWKWARD[0], texts[-1]]
    vectors = [{"text": t, "vector": [round(float(x), 6) for x in original(model, tok, t)]} for t in picked]
    (out / "vectors.json").write_text(json.dumps(vectors, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(cases)} splitter cases, {len(vectors)} reference vectors written to {FIXTURES}")


if __name__ == "__main__":
    command, *rest = sys.argv[1:]
    {"convert": convert, "fixtures": fixtures}[command](*rest)
