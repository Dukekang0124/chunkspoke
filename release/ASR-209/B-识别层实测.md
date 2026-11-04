# ASR-209 B · 识别层候选实测与闸门结论

实测日期：2026-11-04 · 执行体：`tools/asr209_b_bench.py`（本次新增，可复跑）
原始数据：`B-识别层实测-517句-Zira.json`、`B-识别层实测-whisper紧卷边.json`（同目录）

## 一 样本与口径（不猜数，全部现算）

- 句子集：内容包全量 **517 句**（21 个 level 的 `sentences[].text`），不是抽样。
- 音频：Windows SAPI 合成，`Microsoft Zira Desktop`，16 kHz / 16-bit / 单声道，正常语速（rate 0）。
  合成脚本 `D:\tmp\asr209b\synth_zira.ps1`，清单 `D:\tmp\asr209b\manifest.json`；
  **音频不入库**（体积与隐私），只留数字与文本。
- 判定/评分：严格词错率 WER = 规范化后词级编辑距离 / 参考词数，**按词数加权汇总**
  （不用逐句平均，避免 2 词短句主导结论）。
- 三个引擎吃**同一份** WAV；每个引擎另记 RTF（解码墙钟 / 送入音频秒数，本机 CPU）。
- 卷边（前后静音）分两轮：
  - 第一轮统一 `前卷 2.0s / 后卷 0.5s`（给流式 zipformer 预热用）；
  - 第二轮 `前卷 0.2s / 后卷 0.3s`（给非流式 whisper 的公平配置）。
  两轮都同时跑 vosk 作基准，所以降幅是**同卷边内**比出来的。

## 二 体积与 sha256（实测，非文件页数）

| 引擎 | 形态 | 字节 | sha256（前 12 位） |
|---|---|---|---|
| vosk-model-small-en-us-0.15 | 官方 zip | 41,205,931 | 508fee6af9d8 |
| 同上 | 解包（14 个文件） | 70,898,967 | 分文件见 JSON |
| sherpa zipformer en-20M int8 | 四件解包 | 43,649,301 | encoder 3810755ce7c3 / decoder 21e2a2acd961 / joiner e085d73b593c / tokens 49e3c2646595 |
| 同上 | 自家打包 zip（可选下载包） | 38,312,950 | 340998d71b1c（分片 sha 见 `version.json` asrModel） |
| sherpa whisper tiny.en int8 | encoder 12,937,772 + decoder 89,853,865 + tokens 835,554 | **103,627,191** | 0ce578b827c9 / 06c0e6ff6348 / 306cd27f03c1 |
| 同上 | 官方 tar.bz2（含 fp32） | 118,071,777 | — |

whisper 单模型 ≈ **98.8 MiB**，比现在整个 App 还大，也远超 1.6.x 裁定过的「+40 MB」容忍线（ACCEPT-163）。

> 数据完整性说明：`B-识别层实测-517句-Zira.json` 里的 `models.vosk` 段只有 199 B，
> 那是当时 `dir_fingerprint()` 只扫顶层目录导致的统计漏（vosk 模型分在 `am/ graph/ ivector/` 子目录）。
> 表里的 70,898,967 B 用 `du -sb` 递归现算，脚本已改成递归；重跑即得一致数据。

## 三 WER / RTF 实测

统一卷边（前 2.0s / 后 0.5s，n=517）：

| 引擎 | WER | 整句全对 | 空结果 | RTF | 相对 vosk |
|---|---|---|---|---|---|
| vosk small（现线上） | **0.0327** | 89.9% | 0 | 0.107 | 基准 |
| zipformer 20M int8 | 0.3320 | 47.8% | 59 | 0.021 | **−915%（更差）** |
| zipformer 20M int8 + 目标热词 | 0.1698 | 50.3% | 0 | 0.025 | −419%（更差） |
| whisper tiny.en int8 | 0.2598 | 86.7% | 0 | 0.040 | −694%（更差） |

whisper 换紧卷边（前 0.2s / 后 0.3s，n=517）：

| 引擎 | WER | 整句全对 | 空结果 | RTF |
|---|---|---|---|---|
| vosk small | 0.0309 | 90.5% | 0 | 0.173 |
| whisper tiny.en int8 | 0.0827 | 89.0% | 0 | 0.052 |

whisper 紧卷边后差距缩到 2.7 倍，剩余误差集中在 L0 短句的**复读幻觉**
（"Feel the breeze." → 同一句重复 4–5 遍；同类 11 条，见 JSON `rows`），
这是 Whisper 在短音频上的已知失效形态，不是本仓库的接线问题。

## 四 闸门判定

指令 §四 的闸门：目标句集上 WER 相对 vosk small **下降 ≥50%** 且 RTF<1，才允许换。

| 候选 | WER 降幅 | RTF<1 | 结论 |
|---|---|---|---|
| zipformer 20M | −915% | 是 | **不通过** |
| zipformer 20M + 热词 | −419% | 是 | **不通过** |
| whisper tiny.en | −168%（紧卷边） | 是 | **不通过**，且体积超限 |

→ **线上引擎不换**（继续 vosk small-en-us-0.15）。本波不动默认识别链路，
不引入新模型下载，不发新可选包。

RTF 全线达标（0.02–0.17，均 <1）：**速度从来不是这个方案的瓶颈，准确率才是**。

## 五 实测里捞到的两件有用的事（已落地 / 已登记）

1. **热词注入可用，且已接进增强路径**（本轮实装，1.8.2）
   - sherpa-onnx 支持 `createStream(hotwords=...)`；App 侧 `SherpaAsrBackend` 早就把
     `hotwords` 参数传到 isolate，只是 `EnhancedAsrService.transcribeOpen()` 一直没用它。
   - 现在 ⑥ 开口/照读/替换的开放识别与 M1 降级重识，都把**目标句**作为热词下传
     （`asrHotwordsFrom()`：大写、纯字母、去重、上限 16；带标点会被 sherpa 整条丢弃）。
   - 实测收益：空结果 **59/517 → 0**，WER **0.332 → 0.170**。
     症状对应「只出后半句 / 句首丢词」，正是反馈里最常见的抱怨形态之一。
   - 只在用户**已下载并开启**增强包时生效；不开 = 行为与 1.8.1 完全一致。

2. **whisper 路线登记为「体积一票否决」**
   准确率能接近 vosk，但 98.8 MiB 不适合本 App 的分发模型（免费包 41 MB 已经是上限感）。
   若将来只做「云端/桌面旁证」而非端侧默认，可再议；端侧默认这条路上它出局。

## 六 结论的边界（别把这份数当终裁）

- 样本是**合成美音**，不是真人手持录音。Vosk 对 TTS 域更友好，zipformer（LibriSpeech 纯人声训练）
  可能被低估；真人样本集仍未回收（#248 语料基准集 / #253 B 段），这是本结论最大的不确定项。
- RTF 是本机 CPU 的数，低端 Android 需要真机复测（与 ASR-200-5 / #275 同一批欠账）。
- 因此：**本波不换引擎**是「按闸门执行」，不是「zipformer 以后再也不会赢」的终局判断；
  等 #248 真人样本回来，用同一脚本 `--only vosk,zipformer,zipformer-hw,whisper` 复跑即可换结论。

## 七 复现

```bash
# 1) 造音频（需 Windows SAPI + Zira 音色）
python - <<'PY'   # 生成清单
import io,json,os
j=json.load(io.open('assets/content_pack.json',encoding='utf-8'))
items=[{'id':l['id']+'_'+s['id'],'text':s['text'],'rates':[0]} for l in j['levels'] for s in l.get('sentences') or []]
os.makedirs(r'D:\tmp\asr209b',exist_ok=True)
io.open(r'D:\tmp\asr209b\manifest.json','w',encoding='utf-8').write(json.dumps(items,ensure_ascii=False,indent=1))
PY
powershell -NoProfile -ExecutionPolicy Bypass -File D:/tmp/asr209b/synth_zira.ps1

# 2) 三个候选同场对比
python tools/asr209_b_bench.py --wav-dir D:/tmp/asr209b/wav \
  --vosk-model D:/tmp/vosk-model/vosk-model-small-en-us-0.15 \
  --sherpa-model D:/tmp/spike/models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17 \
  --whisper-model D:/tmp/asr209b/models/sherpa-onnx-whisper-tiny.en \
  --out release/ASR-209/B-识别层实测-517句-Zira.json
```

退出码：任一候选过闸=0，全不过=1（本次=1，与「不通过」一致）。
