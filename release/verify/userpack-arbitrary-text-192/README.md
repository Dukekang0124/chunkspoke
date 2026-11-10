# 「随便粘的文本」压力测试 + 修复证据（落 1.9.2/4092）

日期：2026-11-10　分支：`dev/1.9.0-userpack`　范围：只碰解析器/文案/测试，不碰 codes.json、secret、承重墙、发布链两脚本。

## 一、测了什么

35 条「随便的文本」走 `parsePastedUserText` 打印式压力报告（`test/user_text_parser_stress_test.dart`），覆盖：

纯中文、中英混排、带序号/购物清单、显式对照（`|` / Tab / 箭头）、下一行中文配对、单个词、全大写、分号、BOM+CRLF、引号、小数、省略号、长标点段落、重复条目、空/纯空白、纯标点、JSON、CSV 表头、200 条上限、说话人对话（英/中）、URL、表情、时间戳。

## 二、测出并修掉的 5 个问题

| 编号 | 现象（修复前） | 根因 | 修复 |
| --- | --- | --- | --- |
| P0 | 逗号散文（`She likes tea, coffee, and juice.` 多行）被当「一份表格」，甩 CSV 黑话 | `_looksLikeTable` 只看逗号个数 | 加散文信号（句读 `.?!…` 或 `, ` 空格）即判否；钉测保留 `a,b,c\nd,e,f` 仍为 null |
| P1 | `Visit https://example.com for details.` 被当说话人，`https` 前段被切掉（数据损坏） | 说话人解析把 `label:` 后的 URL 当台词 | `http/https`/`//` 开头不做说话人切分 |
| P2 | 英文超长报「第 2 行超过 120」，粘贴用户看不懂 | 校验器错误文案直出 | `describeIssueForLearner` 对 `front 超过` 直出人话：「有句英文太长了…在中间加个句号分成两句」 |
| P3 | `I love you 😊` 尾巴表情被拆成单句 | 英文分句后残片仍入列 | 分句只收含拉丁字母的片段 |
| P4 | `1. Hello` / `00:12 Welcome` 时间戳/序号残留 | `_marker` 不认时间戳 | 正则补 `\d{1,2}:\d{2}(:\d{2})?`，`3.14 is pi.` 不受影响 |

## 三、门禁（修复后复跑）

| 闸门 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test`（全量） | **1090 All tests passed!**（原 1084 + 新增 6） |
| `bash tools/preflight_invariants.sh` | FAIL=1 WARN=0，唯一 FAIL 为已知结构性事实：「FAIL main 已含 user_package.dart（D 轮被合入，违反红线 3）」——该文件随 1.9.0/1.9.1 已上线，非本轮引入 |

## 四、模拟器实测（debug 包，720×1600）

| 文件 | 场景 | 看到什么算对 |
| --- | --- | --- |
| `01_comma_prose_result.png` | 逗号散文多行 | 「整理好了 · 一段英文」，不出现「一份表格」 |
| `02_comma_prose_sentences.png` | 同上，结果区 | 「可以了：2 句」并列出两句完整英文 |
| `03_long_sentence_hint.png` | 超长英文句 | 「有句英文太长了，一次学不下。在中间加个句号分成两句，再点「整理成句子」就好。」无行号、无 120 |
| `04_url_sentence.png` | 含网址句 | `Visit https://example.com for details.` 原样保留，2 句。（第二行为 adb 清场未净的输入残留，非应用行为） |

## 五、边界

- 未 commit、未 bump、未合 main、未上传——发版在下一步单独进行。
- 解析器只做结构整理，不翻译、不猜词义。
- 真机弹窗腿（4091→4092）不可代劳，需 arm64 实体机。
