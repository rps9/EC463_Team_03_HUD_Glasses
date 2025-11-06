import argparse, json, statistics, time, pandas as pd
from comet import load_from_checkpoint
from translation_adapter import translate_to_english

def load_comet(model_name="Unbabel/wmt22-comet-da"):
    model = load_from_checkpoint(model_name)
    return model

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="data/dev_set.csv")
    ap.add_argument("--model", default="Unbabel/wmt22-comet-da")
    ap.add_argument("--out", default="reports/translation_eval.json")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    hyps, srcs, refs, lats = [], [], [], []

    for _, r in df.iterrows():
        s = str(r["src"])
        t0 = time.perf_counter()
        hyp = translate_to_english(s)
        lats.append((time.perf_counter() - t0) * 1000.0)
        hyps.append(hyp)
        srcs.append(s)
        refs.append(str(r["ref"]))

    model = load_comet(args.model)
    data = [{"src": s, "mt": h, "ref": r} for s, h, r in zip(srcs, hyps, refs)]
    comet_out = model.predict(data, batch_size=8, gpus=0)
    comet_score = float(comet_out.system_score)

    report = {
        "count": len(hyps),
        "comet": comet_score,
        "latency_ms": {
            "p50": statistics.median(lats),
            "p90": sorted(lats)[int(max(0, 0.9*len(lats)-1))],
            "p99": sorted(lats)[int(max(0, 0.99*len(lats)-1))],
        }
    }

    print(json.dumps(report, indent=2))
    import pathlib
    pathlib.Path("reports").mkdir(exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(report, f, indent=2)

if __name__ == "__main__":
    main()
