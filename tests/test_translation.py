import sys, os
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
import re, time, pandas as pd
import pytest
from dotenv import load_dotenv

# Load environment variables (including OPENAI_API_KEY)
load_dotenv()

# Import translation adapter (lazy import in adapter means this won't initialize OpenAI client)
from translation_adapter import translate_to_english

# COMET model loading (cached to avoid reloading)
_comet_model = None

def load_comet_model(model_name="Unbabel/wmt22-comet-da"):
    """Load COMET model (cached for performance)."""
    global _comet_model
    if _comet_model is None:
        try:
            from comet import load_from_checkpoint
            _comet_model = load_from_checkpoint(model_name)
        except ImportError:
            raise ImportError("COMET library not installed. Install with: pip install unbabel-comet")
        except Exception as e:
            raise RuntimeError(f"Failed to load COMET model: {str(e)}")
    return _comet_model

@pytest.fixture(scope="session")
def comet_model():
    """Pytest fixture to load COMET model (cached across tests)."""
    try:
        return load_comet_model()
    except (ImportError, RuntimeError) as e:
        pytest.skip(str(e))

# Simple "no native script" guard (disallow CJK blocks)
CJK = re.compile(r"[\u3400-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]")

def is_plain_english_line(s: str) -> bool:
    if not s or "\n" in s or "\r" in s:
        return False
    if s.strip().lower().startswith(("translation:", "result:", "output:")):
        return False
    if CJK.search(s):
        return False
    return True  # allow normal punctuation, digits, spaces

def test_output_format_plain_english():
    """Test that translation output is plain English without labels or native scripts."""
    out = translate_to_english("你好")
    assert is_plain_english_line(out), f"Bad format: {out!r}"

def test_latency_p90_budget_approx():
    """Test that p90 latency is under 1000ms."""
    # Run multiple times to approximate a p90 check locally
    samples_ms = []
    for _ in range(10):
        t0 = time.perf_counter()
        _ = translate_to_english("dónde está el baño")
        ms = (time.perf_counter() - t0) * 1000
        samples_ms.append(ms)
    samples_ms.sort()
    p90 = samples_ms[int(max(0, 0.9*len(samples_ms)-1))]
    assert p90 < 1000, f"p90 too slow: {p90:.1f} ms"

def test_translation_component_basic():
    """Component test: Verify translation function works for basic inputs."""
    test_cases = [
        ("hola", "hello"),
        ("bonjour", "hello"),
        ("你好", "hello"),
    ]
    
    for src, expected_keyword in test_cases:
        result = translate_to_english(src)
        assert result, f"Translation returned empty for input: {src}"
        assert isinstance(result, str), f"Translation should return string, got {type(result)}"
        assert is_plain_english_line(result), f"Output not plain English: {result!r}"
        # Check that result contains expected keyword (case-insensitive)
        assert expected_keyword.lower() in result.lower(), \
            f"Translation '{result}' should contain '{expected_keyword}' for input '{src}'"

def test_translation_component_dev_set():
    """Component test: Test all translations from dev_set.csv."""
    csv_path = os.path.join(os.path.dirname(__file__), '..', 'data', 'dev_set.csv')
    assert os.path.exists(csv_path), f"dev_set.csv not found at {csv_path}"
    
    df = pd.read_csv(csv_path)
    assert len(df) > 0, "dev_set.csv is empty"
    
    results = []
    for idx, row in df.iterrows():
        src = str(row["src"])
        ref = str(row["ref"])
        
        # Translate
        result = translate_to_english(src)
        
        # Validate basic properties
        assert result, f"Translation returned empty for input: {src}"
        assert isinstance(result, str), f"Translation should return string, got {type(result)}"
        assert is_plain_english_line(result), f"Output not plain English: {result!r}"
        
        # Store for reporting
        results.append({
            "src": src,
            "ref": ref,
            "hyp": result,
            "passed": True
        })
    
    # All translations should have passed basic validation
    assert len(results) == len(df), "Not all test cases were processed"
    assert all(r["passed"] for r in results), "Some translations failed validation"

def test_translation_comet_score(comet_model):
    """Component test: Evaluate translation quality using COMET metric."""
    csv_path = os.path.join(os.path.dirname(__file__), '..', 'data', 'dev_set.csv')
    assert os.path.exists(csv_path), f"dev_set.csv not found at {csv_path}"
    
    df = pd.read_csv(csv_path)
    assert len(df) > 0, "dev_set.csv is empty"
    
    # Collect translations
    hyps, srcs, refs = [], [], []
    for idx, row in df.iterrows():
        src = str(row["src"])
        ref = str(row["ref"])
        hyp = translate_to_english(src)
        
        hyps.append(hyp)
        srcs.append(src)
        refs.append(ref)
    
    # Compute COMET score
    data = [{"src": s, "mt": h, "ref": r} for s, h, r in zip(srcs, hyps, refs)]
    comet_out = comet_model.predict(data, batch_size=8, gpus=0)
    comet_score = float(comet_out.system_score)
    
    # Print COMET score for visibility
    print(f"\nCOMET Score: {comet_score:.4f} (threshold: > 0.3)")
    
    # COMET scores typically range from -1 to 1, with higher being better
    # A score above 0.5 is generally considered good quality
    # Adjust threshold based on your requirements
    assert comet_score > 0.3, f"COMET score {comet_score:.4f} is below minimum threshold of 0.3"
    
    # Also check individual scores (optional - can be used for debugging)
    individual_scores = comet_out.scores
    assert len(individual_scores) == len(df), "Number of individual scores should match test cases"
    
    # Print individual scores for debugging (optional)
    if len(individual_scores) <= 10:  # Only print if small number of test cases
        print("\nIndividual COMET scores:")
        for i, (src, ref, hyp, score) in enumerate(zip(srcs, refs, hyps, individual_scores)):
            print(f"  {i+1}. {src} -> {hyp} (ref: {ref}) | Score: {score:.4f}")

def test_translation_component_edge_cases():
    """Component test: Test edge cases and error handling."""
    # Empty string - should return string (may be empty)
    result = translate_to_english("")
    assert isinstance(result, str), "Should return string even for empty input"
    
    # Very short input
    result = translate_to_english("a")
    assert isinstance(result, str), "Should handle single character input"
    if result:  # Only check format if non-empty
        assert is_plain_english_line(result), "Output should be plain English"
    
    # Input with special characters
    result = translate_to_english("¿dónde está el baño?")
    assert result, "Should handle special characters"
    assert is_plain_english_line(result), "Output should be plain English"
    
    # Long sentence
    result = translate_to_english("我昨天在波士頓買了兩杯咖啡")
    assert result, "Should handle longer sentences"
    assert is_plain_english_line(result), "Output should be plain English"

def test_translation_component_consistency():
    """Component test: Verify translations are consistent (same input -> similar output)."""
    test_input = "hola"
    results = []
    
    # Run translation multiple times
    for _ in range(3):
        result = translate_to_english(test_input)
        results.append(result.lower().strip())
    
    # All results should be non-empty and in English
    assert all(r for r in results), "All translations should be non-empty"
    assert all(is_plain_english_line(r) for r in results), "All outputs should be plain English"
    
    # Results should be similar (at least contain common words like "hello")
    # This is a soft check since LLM outputs can vary
    common_words = ["hello", "hi", "greeting"]
    assert any(any(word in r for word in common_words) for r in results), \
        f"At least one translation should contain common greeting words. Got: {results}"
