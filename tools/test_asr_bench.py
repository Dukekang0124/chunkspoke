# -*- coding: utf-8 -*-
"""asr_bench.py 单测（合成样本，不需要模型、不需要音频）

跑法：
    python tools/test_asr_bench.py -v

覆盖五件事：
  1. WER / 容错 WER 的数值口径（手算可核）；
  2. 虚词命中率与实词命中率（弱读判效指标）的语义：丢虚词不塌、切实词塌；
  3. judgeSpeech 同源行为（通过 / lowCore / 拒判）；
  4. **口径漂移守卫**：Python 虚词表与混淆对必须与 `lib/services/speech_judge.dart` 逐项一致；
  5. **判定对拍**（1.5.9）：阈值同值 + `test/fixtures/judge_parity.json` 不得过期
     （Dart 侧由 `test/judge_parity_test.dart` 逐条断言同一结论）。
"""

import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import asr_bench  # noqa: E402

DART_JUDGE = os.path.join(ROOT, "lib", "services", "speech_judge.dart")
DART_PHONETICS = os.path.join(ROOT, "lib", "services", "phonetics.dart")


class WerTest(unittest.TestCase):
    def test_identical_is_zero(self):
        self.assertEqual(asr_bench.wer("I would like a cup of coffee.",
                                       "i would like a cup of coffee"), 0.0)

    def test_one_deletion(self):
        # 7 词参考，丢 1 词 → 1/7
        ref = "i would like a cup of coffee"
        hyp = "i would like cup of coffee"
        self.assertAlmostEqual(asr_bench.wer(ref, hyp), 1 / 7, places=4)

    def test_one_substitution(self):
        ref = "i would like a cup of coffee"
        hyp = "i would like a cap of coffee"
        self.assertAlmostEqual(asr_bench.wer(ref, hyp), 1 / 7, places=4)

    def test_close_wer_tolerates_one_edit(self):
        # cap vs cup 编辑距离 1 → 严格 WER 有错，容错 WER 为 0
        ref = "a cup of coffee"
        hyp = "a cap of coffee"
        self.assertGreater(asr_bench.wer(ref, hyp), 0.0)
        self.assertEqual(asr_bench.close_wer(ref, hyp), 0.0)

    def test_empty_ref_is_zero_not_crash(self):
        self.assertEqual(asr_bench.wer("", "anything"), 0.0)


class RecallTest(unittest.TestCase):
    def test_all_matched(self):
        fw, cw, fw_n, cw_n = asr_bench._recalls("i want to go to the park",
                                               "i want to go to the park")
        # want/go/park 是实词；i/to/to/the 是虚词（表里没有 want）
        self.assertEqual((fw, cw, fw_n, cw_n), (1.0, 1.0, 4, 3))

    def test_dropped_function_word_hurts_func_recall_only(self):
        # 丢一个虚词（to）→ 虚词命中率下降，实词仍全中
        fw, cw, _fw_n, _cw_n = asr_bench._recalls("i want to go to the park",
                                                 "i want go to the park")
        self.assertLess(fw, 1.0)
        self.assertEqual(cw, 1.0)

    def test_dropped_content_word_hurts_content_recall(self):
        # 丢实词（park）→ 实词命中率下降
        fw, cw, _fw_n, _cw_n = asr_bench._recalls("i want to go to the park",
                                                 "i want to go to the")
        self.assertLess(cw, 1.0)


class JudgeMirrorTest(unittest.TestCase):
    def test_exact_pass(self):
        self.assertTrue(asr_bench._judge("good morning", "good morning")["passed"])

    def test_content_error_rejected(self):
        # 核心词错音（snack→snake）必须被拦，这正是「虚词容错不等于乱放行」
        self.assertFalse(asr_bench._judge("I had a snack", "I had a snake")["passed"])

    def test_missing_article_still_passes(self):
        self.assertTrue(asr_bench._judge("I would like a cup of coffee",
                                         "I would like cup of coffee")["passed"])


class DriftGuardTest(unittest.TestCase):
    """Python 镜像与 Dart 真源必须一致——改一处不改另一处时这里红。"""

    @classmethod
    def setUpClass(cls):
        cls.dart = io.open(DART_JUDGE, encoding="utf-8").read()
        cls.phon = io.open(DART_PHONETICS, encoding="utf-8").read()

    def test_function_word_set_matches_dart(self):
        m = re.search(r"const Set<String> _functionWords = \{(.*?)\};", self.dart, re.S)
        self.assertIsNotNone(m, "speech_judge.dart 里找不到 _functionWords 定义")
        dart_words = set(re.findall(r"'([a-z]+)'", m.group(1)))
        py_words = set(asr_bench._J["FUNCTION_WORDS"])
        self.assertEqual(sorted(dart_words - py_words), [], "Dart 有、Python 缺")
        self.assertEqual(sorted(py_words - dart_words), [], "Python 有、Dart 缺")

    def test_confusion_pairs_match_dart(self):
        m = re.search(r"const Set<Set<String>> kConfusionPairs = \{(.*?)\};", self.dart, re.S)
        self.assertIsNotNone(m, "speech_judge.dart 里找不到 kConfusionPairs 定义")
        dart_pairs = {frozenset(re.findall(r"'([a-z]+)'", line))
                      for line in m.group(1).splitlines() if "{" in line}
        py_pairs = {frozenset(p) for p in asr_bench._J["CONFUSION_PAIRS"]}
        self.assertEqual(dart_pairs, py_pairs)

    # ── phonetics.dart ⇄ vosk_sim.py（ASR-211 增）──────────────────────────
    # 撇号缩合表这次两边各写一遍，写歪的那侧「案1」判成另一种结果，而对拍夹具
    # 里没有带撇号的句子就查不出来。表名/阈值在这里钉死，改一边立刻红。

    def test_phon_ratio_matches_dart(self):
        m = re.search(r"const double kPhonRatio = ([0-9.]+)\s*;", self.phon)
        self.assertIsNotNone(m, "phonetics.dart 里找不到 kPhonRatio 定义")
        self.assertAlmostEqual(float(m.group(1)), asr_bench._J["PHON_RATIO"], places=6,
                               msg="音素阈值漂移：同一句话两边判不一样")

    def _dart_str_map(self, decl):
        m = re.search(decl + r"\s*=\s*\{(.*?)\};", self.phon, re.S)
        self.assertIsNotNone(m, "phonetics.dart 里找不到 %s 定义" % decl)
        body = "\n".join(l for l in m.group(1).splitlines() if not l.strip().startswith("//"))
        out = {}
        for k, v in re.findall(r"['\"]([a-z']+)['\"]\s*:\s*['\"]([^'\"]+)['\"]", body):
            out[k] = v
        return out

    def test_exception_table_matches_dart(self):
        dart = self._dart_str_map(r"const Map<String, String> _exceptions")
        py = dict(asr_bench._J["EXCEPTIONS"])
        self.assertTrue(dart, "_exceptions 解析为空（Dart 写法变了，守卫失效）")
        self.assertEqual(sorted(k for k in dart if k not in py), [], "Dart 有、Python 缺")
        self.assertEqual(sorted(k for k in py if k not in dart), [], "Python 有、Dart 缺")
        self.assertEqual({k: v for k, v in dart.items() if py.get(k) != v}, {},
                         "同键不同音素")

    def test_contraction_table_matches_dart(self):
        m = re.search(r"const Map<String, List<String>> _spokenContractions\s*=\s*\{(.*?)\};",
                      self.phon, re.S)
        self.assertIsNotNone(m, "phonetics.dart 里找不到 _spokenContractions 定义")
        body = "\n".join(l for l in m.group(1).splitlines() if not l.strip().startswith("//"))
        dart = {}
        for k, inner in re.findall(r"['\"]([a-z']+)['\"]\s*:\s*\[([^\]]*)\]", body):
            dart[k] = re.findall(r"['\"]([a-z']+)['\"]", inner)
        py = {k: list(v) for k, v in asr_bench._J["CONTRACTIONS"].items()}
        # 缩合表是判卷归一的第一入口（ASR-211）：条数 + 键集合 + 展开结果三重核。
        self.assertGreaterEqual(len(dart), 40, "_spokenContractions 解析异常（条目过少）")
        self.assertEqual(sorted(set(dart) - set(py)), [], "Dart 有、Python 缺")
        self.assertEqual(sorted(set(py) - set(dart)), [], "Python 有、Dart 缺")
        self.assertEqual({k: (dart[k], py[k]) for k in dart if dart[k] != py[k]}, {},
                         "同键不同展开")

    # ── 阈值漂移（1.5.9 增）：词表之外，数字也必须同值 ──────────────────────
    # 表一致但阈值不同 = 同一句话两边判不一样，对拍等于白做。

    def _dart_const(self, name):
        m = re.search(name + r"\s*=\s*([0-9.]+)\s*;", self.dart)
        self.assertIsNotNone(m, "speech_judge.dart 里找不到常量 %s" % name)
        return float(m.group(1))

    def test_conf_threshold_matches_python_behavior(self):
        """Dart kConfThreshold 的两侧行为必须与 Python 在同一数上翻转。"""
        t, near = "i would like a cup of coffee", "would like a cup of coffee"
        c = self._dart_const("kConfThreshold")
        judge = asr_bench._J["judge_speech"]
        self.assertEqual(judge(t, near, c - 0.01)["reason"], "lowConf",
                         "低于 Dart 阈值应拒判，Python 却放行了")
        self.assertEqual(judge(t, near, c + 0.01)["reason"], "fuzzy",
                         "高于 Dart 阈值应通过，Python 却拒了")

    def test_min_duration_matches_python_behavior(self):
        t = "i would like a cup of coffee"
        d = self._dart_const("kMinDurationSec")
        judge = asr_bench._J["judge_speech"]
        self.assertEqual(judge(t, t, None, d - 0.01)["reason"], "tooShort")
        self.assertEqual(judge(t, t, None, d + 0.01)["reason"], "exact")

    def test_min_similarity_is_dart_only_floor(self):
        """kMinSimilarity 是 Dart 独有底线（Python 基准不算未加权）→ 必须是已知差。

        夹具里 divergence=noiseFloor 那条把差异钉住了；这里只守「它还在」，
        免得哪天有人把它删了，Dart 侧「噪声里凑词」的口子重新打开。
        """
        self.assertGreater(self._dart_const("kMinSimilarity"), 0.0)


class ParityFixtureTest(unittest.TestCase):
    """Dart ⇄ Python 对拍夹具不能过期（改判定就得重跑生成器）。"""

    def test_fixture_matches_python_side(self):
        import judge_parity
        self.assertEqual(judge_parity.main(["--check"]), 0,
                         "夹具过期：python tools/judge_parity.py")


class CliTest(unittest.TestCase):
    def test_score_only_report_marks_non_baseline(self):
        man = {
            "kind": "pipeline-smoke",
            "items": [
                {"id": "S-01", "ref": "I would like a cup of coffee.",
                 "hyp": "i would like a cup of coffee", "tags": ["normal"]},
                {"id": "S-02", "ref": "I want to go to the park.",
                 "hyp": "i wanna go to the park", "tags": ["fast"]},
            ],
        }
        with tempfile.TemporaryDirectory() as td:
            mp = os.path.join(td, "manifest.json")
            op = os.path.join(td, "out.json")
            io.open(mp, "w", encoding="utf-8").write(json.dumps(man, ensure_ascii=False))
            rc = asr_bench.main(["--manifest", mp, "--out", op, "--score-only", "--quiet"])
            self.assertEqual(rc, 0)
            rep = json.load(io.open(op, encoding="utf-8"))
        self.assertFalse(rep["baseline"])
        self.assertEqual(rep["kind"], "pipeline-smoke")
        self.assertEqual(rep["overall"]["n"], 2)
        # 第一条完全正确；第二条 wanna 合并 → WER > 0，故总体 WER 落在 (0, 1)
        by_id = {r["id"]: r for r in rep["items"]}
        self.assertEqual(by_id["S-01"]["wer"], 0.0)
        self.assertGreater(by_id["S-02"]["wer"], 0.0)
        self.assertEqual(set(rep["byTag"]), {"normal", "fast"})

    def test_missing_model_exits_3(self):
        man = {"kind": "baseline", "items": [{"id": "A", "ref": "hi", "wav": "nope.wav"}]}
        with tempfile.TemporaryDirectory() as td:
            mp = os.path.join(td, "m.json")
            io.open(mp, "w", encoding="utf-8").write(json.dumps(man))
            with self.assertRaises(SystemExit) as cm:
                asr_bench.main(["--manifest", mp, "--model", os.path.join(td, "no-model")])
        self.assertEqual(cm.exception.code, 3)

    def test_bad_manifest_exits_2_without_traceback(self):
        """manifest 坏/不存在时给一行人话 + 退出码 2，不抛栈。"""
        with tempfile.TemporaryDirectory() as td:
            bad = os.path.join(td, "bad.json")
            io.open(bad, "w", encoding="utf-8").write("{ not json")
            self.assertEqual(asr_bench.main(["--manifest", bad, "--score-only"]), 2)
            self.assertEqual(asr_bench.main(
                ["--manifest", os.path.join(td, "nope.json"), "--score-only"]), 2)

    def test_cli_runs_as_process(self):
        """冒烟：脚本能以子进程跑起来（防 import 期副作用/语法坏）。"""
        man = {"kind": "pipeline-smoke",
               "items": [{"id": "X", "ref": "hello there", "hyp": "hello there"}]}
        with tempfile.TemporaryDirectory() as td:
            mp = os.path.join(td, "m.json")
            io.open(mp, "w", encoding="utf-8").write(json.dumps(man))
            p = subprocess.run([sys.executable, os.path.join(HERE, "asr_bench.py"),
                                "--manifest", mp, "--score-only", "--quiet"],
                               capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("非基线", p.stdout)


if __name__ == "__main__":
    unittest.main()
