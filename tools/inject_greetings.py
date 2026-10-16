"""重拆首场景「打招呼」为词块拼装体系示范件（v1.2.0）。
将 assets/content_pack.json 的 levels[0] 替换为：
- 12 个词块（2~5 词预制件）
- 14 个目标句（每句标注由哪些词块拼成，chunkIds 顺序）
其余场景保持不变。模型对缺省 `sentence` 的 Chunk 会回退为词块文本本身。
"""
import json
import os

ROOT = r'd:\写作工具\知识管理\01-Projects-项目\求职与作品集\03-作品集\chunkspoke\chunkspoke-flutter'
PATH = os.path.join(ROOT, 'assets', 'content_pack.json')

# —— 12 个词块 ——
CHUNKS = [
    ("a01", "Good morning", "greeting", "早上好"),
    ("a02", "Good evening", "greeting", "晚上好"),
    ("a03", "I'm fine", "content", "我很好"),
    ("a04", "thank you", "function", "谢谢"),
    ("a05", "my name is", "content", "我的名字是"),
    ("a06", "what's your name", "content", "你叫什么名字"),
    ("a07", "nice to meet you", "content", "很高兴认识你"),
    ("a08", "see you", "content", "再见"),
    ("a09", "take care", "content", "保重"),
    ("a10", "Excuse me", "function", "打扰一下"),
    ("a11", "everyone", "content", "大家"),
    ("a12", "tomorrow", "timeplace", "明天"),
]

# —— 14 个目标句（chunkIds 顺序拼装）——
SENTENCES = [
    ("s01", "Good morning everyone", "大家早上好", ["a01", "a11"]),
    ("s02", "Good evening everyone", "大家晚上好", ["a02", "a11"]),
    ("s03", "I'm fine thank you", "我很好，谢谢", ["a03", "a04"]),
    ("s04", "Excuse me thank you", "打扰一下，谢谢", ["a10", "a04"]),
    ("s05", "nice to meet you thank you", "很高兴认识你，谢谢", ["a07", "a04"]),
    ("s06", "see you tomorrow", "明天见", ["a08", "a12"]),
    ("s07", "take care everyone", "大家保重", ["a09", "a11"]),
    ("s08", "Good morning I'm fine", "早上好，我很好", ["a01", "a03"]),
    ("s09", "Good evening I'm fine", "晚上好，我很好", ["a02", "a03"]),
    ("s10", "what's your name my name is", "你叫什么名字，我的名字是", ["a06", "a05"]),
    ("s11", "Excuse me see you", "打扰一下，再见", ["a10", "a08"]),
    ("s12", "take care see you", "保重，再见", ["a09", "a08"]),
    ("s13", "Good morning take care", "早上好，保重", ["a01", "a09"]),
    ("s14", "Good evening thank you", "晚上好，谢谢", ["a02", "a04"]),
]


def main():
    with open(PATH, 'r', encoding='utf-8') as f:
        data = json.load(f)

    new_level = {
        "id": "A",
        "theme": "Greetings",
        "sceneImage": "scene_a.png",
        "chunks": [
            {"id": cid, "text": txt, "type": typ, "meaningCN": cn}
            for (cid, txt, typ, cn) in CHUNKS
        ],
        "sentences": [
            {"id": sid, "text": txt, "meaningCN": cn, "chunkIds": ids}
            for (sid, txt, cn, ids) in SENTENCES
        ],
    }

    # 校验：每个 chunkIds 中的 id 必须存在；每个 chunk 至少出现一次。
    chunk_ids = {c[0] for c in CHUNKS}
    for (sid, _t, _c, ids) in SENTENCES:
        for i in ids:
            assert i in chunk_ids, f"句 {sid} 引用了不存在的词块 {i}"
    used = set()
    for (_s, _t, _c, ids) in SENTENCES:
        used.update(ids)
    missing = chunk_ids - used
    assert not missing, f"有词块从未出现在任何句中：{missing}"

    data["levels"][0] = new_level

    with open(PATH, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    print(f"OK: levels[0] 重写为 {len(CHUNKS)} 词块 / {len(SENTENCES)} 目标句")


if __name__ == '__main__':
    main()
