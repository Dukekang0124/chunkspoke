# asr_bench.py —— ASR 基准测量（#248④ / #249）

把一批 WAV 跑一遍 Vosk，用**与 App 完全同源的判定口径**算数。发布门对拍认这四列，
不认手感：

| 指标 | 含义 | 谁用 |
|---|---|---|
| `wer` | 严格词错率（编辑距离 / 参考词数） | 横向对比、报数 |
| `funcRecall` | **虚词命中率** | 1.5.8.2「弱读是否被听清」的判效指标 |
| `contentRecall` | 实词命中率 | 核心词有没有听错（snack→snake 这类） |
| `judgePassRate` | `judgeSpeech` 通过率 | 用户实际会不会被判「没听清」 |

外加 `decodeSec` / `audioSec` / `rtf`（解码耗时、音频时长、实时率），供选型与性能回归。

## 一、口径单一真源（别在本文件里改判定）

判定逻辑**不在本脚本里重写**。`asr_bench.py` 启动时读取 `tools/vosk_sim.py` 的源码前缀
（`# ---------- 识别` 之前的部分）并 `exec` 执行，用一个 stub 顶掉模块级 `Model()` 构造，
于是 `normalize_speech` / `word_close` / `is_function` / `weighted_align` / `judge_speech`
**与发版门禁脚本逐字同一份**。

`vosk_sim.py` 自己声明那份 Python 是 `lib/services/speech_judge.dart` 的镜像。
`tools/test_asr_bench.py` 里的 `DriftGuardTest` 会从 Dart 源码里正则抽出
`_functionWords` 与 `kConfusionPairs`，和 Python 侧逐项比对——任一边单独改都会红。

改判定的正确姿势：`speech_judge.dart` 与 `vosk_sim.py` 两处同改 → 跑
`python tools/test_asr_bench.py` → 重生成对拍夹具 → 再跑基准。

## 一·补、判定对拍（1.5.9 · §30.2）

`DriftGuardTest` 只守**词表和阈值数字**，不守行为。行为对拍是另一条链：

| 件 | 作用 |
|---|---|
| `tools/judge_parity.py` | 用 Python 侧判定跑固定用例表，生成夹具（`--check` 只比对） |
| `test/fixtures/judge_parity.json` | 100 条：目标 / 识别文本 / 置信度 / 时长 / Python 期望结论 |
| `test/judge_parity_test.dart` | Dart 侧逐条断言同判（`flutter test` 跑） |

```bash
python tools/judge_parity.py            # 改判定后重生成
python tools/judge_parity.py --check    # 过期返回 5
python tools/test_asr_bench.py -v       # 词表 + 阈值 + 夹具新鲜度
flutter test test/judge_parity_test.dart
```

规矩：**变异后与目标同词不写入**（防「漏虚词 = 完全一致」的假用例）；
七分支（`exact/fuzzy/lowCore/lowSim/lowConf/empty/tooShort`）少一条生成器就退出码 6。
夹具里带 `divergence` 字段的是**已知差**——Dart 独有的未加权底线 `kMinSimilarity=0.5`，
Python 基准不承担这条产品规则；差异方向由 Dart 侧断言钉住。

> 为什么不直接 `import vosk_sim`：它模块级就 `Model(MODEL_DIR)` 并跑主流程，
> import 即执行。为不惊动发版门禁，改用「执行源码前缀」的办法，零重复、零改动。

## 二、Manifest 格式

```json
{
  "kind": "pipeline-smoke",
  "items": [
    {"id": "N-01", "ref": "I would like a cup of coffee.",
     "wav": "wav/N-01.wav", "tags": ["normal"], "speaker": "Zira"},
    {"id": "N-02", "ref": "She went to the park.", "tags": ["fast"],
     "hyp": "she went to the park", "audioSec": 2.1}
  ]
}
```

- `ref` 必填，目标文本（可以带标点，比较前会规范化）。
- 二选一：`wav`（路径相对 manifest 所在目录）走解码；`hyp` 直接给识别文本只算分。
- `tags` 参与分组汇总（例如 `normal` / `fast` / `weak` / `device-oppo`）。
- `kind`：`baseline` 之外的一切值都按非基线处理（见第四节红线）。

## 三、用法

```bash
# 解码 + 算分
python tools/asr_bench.py --manifest bench/manifest.json \
    --model D:\tmp\vosk-model\vosk-model-small-en-us-0.15 --out bench/out.json

# 只算分（条目自带 hyp，不需要模型）
python tools/asr_bench.py --manifest bench/manifest.json --score-only

# 诊断：带目标短语词表（缩小搜索空间；只用于定位，不可用于基线）
python tools/asr_bench.py --manifest bench/manifest.json --grammar target

# 单元测试（合成样本，不需要模型）
python tools/test_asr_bench.py
```

退出码：`0` 正常；`2` manifest 空；`3` 模型目录不存在。

模型准备（本机）：
- 有网：`python tools/fetch_vosk_model.py`（存 `assets/…zip`）再解压；
- 无网/慢网：从 `dist/models/vosk-model-small-en-us-0.15/parts/model.part*` 顺序拼接成 zip
  再解压（`split_model.py` 只是按 15 MiB 切块，拼回来就是原 zip）；
- 最终模型目录里有 `am/ conf/ graph/ ivector/ README` 即完整。

## 四、红线：非基线数字不许当证据

`kind != "baseline"` 时：

- 脚本开头打印「非基线」横幅，报告 `"baseline": false`、`"note": "非基线：仅验证管道"`；
- **数字不得写入 DDS §20.5.1**，**不得作为 1.5.8.2 发布门（基准对拍）证据**；
- 真实基线必须用 #253 B 段回收的真机录音，manifest 标 `"kind": "baseline"`。

样本音频只留本机，**不进仓**。仓库里只有脚本与文档。

## 五、合成素材冒烟（只证明链路通）

合成素材用 SAPI 造（`tools/gen_wavs.ps1`，16 kHz / 单声道 / 16 bit），manifest：

```bash
powershell -File tools/gen_wavs.ps1 -OutDir D:\tmp\asr_smoke\wav -Manifest D:\tmp\asr_smoke\sent.json
python tools/asr_bench.py --manifest D:\tmp\asr_smoke\manifest.json --model <模型目录>
```

2026-10-29 本机实际跑过一遍（6 句 × 2 音色 × 2 语速 = 24 条，`kind=pipeline-smoke`）：
WAV → Vosk → 判定口径 → JSON 报告 全链路通，`grammar=none` 与 `grammar=target` 两路都能出数，
`rtf` 两列均有值。

**这组数不叫基线**，README 也不抄它的具体值。它唯一的作用是证明：解码循环、manifest 解析、
分组汇总、报告落盘、非基线横幅这五件事是通的。

顺带暴露一件真事（供 #248 参考，不是结论）：`meeting` 被识别成 `meetings` 时，严格
`wer` 计错、`closeWer` 计 0——`wordClose` 的「短词为长词前缀且长度差 ≤1」规则把屈折变化
算作同词。做基线时要同时看这两列，否则会把「词形容错」读成「识别错误」。

## 六、已知限制

- 解码按 4000 帧一块喂，**不取词级时间戳**（词级 `confidence` 需识别器另开，Vosk
  `getFinalResult()` 顶层没有该字段——见 `speech_judge.dart` 文件头）；
- `--grammar target` 会把识别强制拼进目标词表，**必然抬高通过率**，只用于定位「是识别
  问题还是判定问题」，不得进发布门；
- `rtf` 与主机性能强相关，跨机不可比，同机跨版本可比；
- 本脚本只输出数字与文本，不做音频分析、不做对齐可视化。
