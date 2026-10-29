# -*- coding: utf-8 -*-
"""asr_bench.py 单测（合成样本，不需要模型、不需要音频）

跑法：
    python tools/test_asr_bench.py -v

覆盖四件事：
  1. WER / 容错 WER 的数值口径（手算可核）；
  2. 虚词命中率与实词命中率（弱读判效指标）的语义：丢虚词不塌、切实词塌；
  3. judgeSpeech 同源行为（通过 / lowCore / 拒判）；
  4. **口径漂移守卫**：Python 虚词表与混淆对必须与 `lib/services/speech_judge.dart` 逐项一致。
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
