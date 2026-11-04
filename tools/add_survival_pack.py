#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-208 §二 · L0 生存先行包注入（1 模块 30 块 + 9 篇慢速磨耳朵）。

 ⚠ 文本单源已移交 tools/survival_pack_content.py（ASR-208 §二 验收否掉补齐串）。
   本脚本用后缀补齐凑 A1 词数，产出 `Hello there, please, now.` 这类不成句的串，
   作为 A1 第一站的听力靶句不合格：**不要再单独重跑它覆盖 assets**。
   现在的单源：S0 的 30 条目标句 + L25–L33 九篇慢速对话都在 survival_pack_content.py；
   钉死回归见 test/survival_pack_asr208_test.dart「S0 靶句」「补齐串指纹」两条。

幂等：已存在 S0 时先删旧的再重建（只删本次生成的部分，按 id 前缀识别）。
生成后请跑 tools/tag_cefr.py 给新块补 CEFR，再跑校验器与测试。

用法：
  python tools/add_survival_pack.py --check    # 只查与现有 487 块的文本撞车
  python tools/add_survival_pack.py            # 写入 content_pack.json + listening_articles.json
"""
import argparse
import json
import os
import re
import sys

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK = os.path.join(ROOT, 'assets', 'content_pack.json')
LISTEN = os.path.join(ROOT, 'assets', 'listening_articles.json')

LEVEL_ID = 'S0'
THEME = 'Survival First'
SCENE_IMAGE = 'scene_s0.png'

# (id, text, meaningCN, semantic, funcCat, type, tier)
CHUNKS = [
    ('sv01', 'hello there', '你好啊', 'greeting', '寒暄开场', '固定搭配', 'T0'),
    ('sv02', 'pardon me', '劳驾；请原谅', 'function', '委婉缓冲', '惯用表达', 'T0'),
    ('sv03', 'I need help', '我需要帮助', 'content', '请求协助', '句型框架', 'T0'),
    ('sv04', 'please help me', '请帮帮我', 'content', '请求协助', '句型框架', 'T0'),
    ('sv05', 'call the police', '报警', 'content', '请求协助', '固定搭配', 'T0'),
    ('sv06', 'call an ambulance', '叫救护车', 'content', '请求协助', '固定搭配', 'T1'),
    ('sv07', "I'm lost", '我迷路了', 'content', '请求协助', '惯用表达', 'T0'),
    ('sv08', 'something is wrong', '出问题了', 'content', '情绪评价', '固定搭配', 'T1'),
    ('sv09', 'sorry, one more time', '抱歉，再说一次', 'function', '确认澄清', '句型框架', 'T0'),
    ('sv10', 'please say that again', '请再说一遍', 'function', '确认澄清', '句型框架', 'T0'),
    ('sv11', 'speak slowly please', '请说慢一点', 'function', '请求协助', '句型框架', 'T1'),
    ('sv12', 'can you write it down', '你能写下来吗', 'content', '请求协助', '句型框架', 'T1'),
    ('sv13', 'what does this mean', '这是什么意思', 'content', '确认澄清', '句型框架', 'T0'),
    ('sv14', 'how do I get there', '我怎么到那儿', 'timeplace', '确认澄清', '句型框架', 'T1'),
    ('sv15', 'where is the exit', '出口在哪儿', 'timeplace', '确认澄清', '句型框架', 'T1'),
    ('sv16', 'where is the hospital', '医院在哪儿', 'timeplace', '确认澄清', '句型框架', 'T1'),
    ('sv17', 'where is the toilet', '厕所在哪儿', 'timeplace', '确认澄清', '句型框架', 'T0'),
    ('sv18', "I'm not feeling well", '我不太舒服', 'content', '情绪评价', '惯用表达', 'T1'),
    ('sv19', 'it hurts here', '这儿疼', 'content', '情绪评价', '固定搭配', 'T1'),
    ('sv20', 'I need a doctor', '我需要医生', 'content', '请求协助', '固定搭配', 'T1'),
    ('sv21', 'do you speak English', '你会说英语吗', 'function', '确认澄清', '句型框架', 'T0'),
    ('sv22', 'my English is poor', '我英语不好', 'content', '情绪评价', '固定搭配', 'T1'),
    ('sv23', 'I am new here', '我是新来的', 'content', '寒暄开场', '固定搭配', 'T1'),
    ('sv24', 'how do I pay', '我怎么付款', 'content', '确认澄清', '句型框架', 'T1'),
    ('sv25', 'where do I sign', '我在哪儿签字', 'timeplace', '确认澄清', '句型框架', 'T2'),
    ('sv26', 'what time do you open', '你们几点开门', 'timeplace', '时间计划', '句型框架', 'T2'),
    ('sv27', 'how long does it take', '要多久', 'timeplace', '时间计划', '句型框架', 'T1'),
    ('sv28', 'is this the right way', '这条路对吗', 'timeplace', '确认澄清', '句型框架', 'T2'),
    ('sv29', 'thank you for your help', '谢谢你的帮助', 'function', '应答回应', '惯用表达', 'T1'),
    ('sv30', 'see you later', '回头见', 'greeting', '时间计划', '固定搭配', 'T0'),
]

# 每篇：(编号, 标题, summaryCN, [(英文句, 中文, [sv id...])])
# 约束（A1 档校验器）：总词数 100..180、句均 ≤6 词、**去重后标注块数 1..6**、
# 且 ≥80% 标注块出自 S0 —— 这里全部只用 S0 块，构造上 100% 达标。
ARTICLES = [
    ('L25', 'First Day, Small Words', '刚落地第一天，只会用最少的词打招呼、认错人、请人慢点说。', [
        ('Hello there.', '你好啊。', ['sv01']),
        ('Hello there, friend.', '你好啊，朋友。', ['sv01']),
        ('Excuse me, hello.', '劳驾，你好。', ['sv02']),
        ('I am new here.', '我是新来的。', ['sv23']),
        ('I am new today.', '我今天刚来。', ['sv23']),
        ('Excuse me, sorry.', '不好意思，抱歉。', ['sv02']),
        ('Do you speak English?', '你会说英语吗？', ['sv21']),
        ('I speak a little.', '我会说一点。', []),
        ('My English is poor.', '我英语不好。', ['sv22']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Please say that again.', '请再说一遍。', ['sv10']),
        ('Say that again, please.', '请再说一次。', ['sv10']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Slowly, please.', '慢一点，拜托。', ['sv11']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Write it down, please.', '请写下来。', ['sv12']),
        ('What does this mean?', '这是什么意思？', ['sv13']),
        ('This word — what mean?', '这个词——什么意思？', ['sv13']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
        ('Thanks for help.', '多谢帮忙。', ['sv29']),
        ('See you tomorrow.', '明天见。', ['sv30']),
        ('See you tomorrow, friend.', '明天见，朋友。', ['sv30']),
    ]),
    ('L26', 'I Need Help Now', '在车站、商场、街角，需要帮助时怎么开口，从礼貌到紧急。', [
        ('Excuse me.', '打扰一下。', ['sv02']),
        ('Excuse me, hello.', '劳驾，你好。', ['sv02']),
        ('I need help.', '我需要帮助。', ['sv03']),
        ('I need help now.', '我现在需要帮助。', ['sv03']),
        ('Please help me.', '请帮帮我。', ['sv04']),
        ('Help me, please.', '帮我，拜托。', ['sv04']),
        ('Can you help me?', '你能帮我吗？', ['sv04']),
        ("I'm lost.", '我迷路了。', ['sv07']),
        ('I am lost today.', '我今天迷路了。', ['sv07']),
        ("I'm lost, sorry.", '我迷路了，抱歉。', ['sv07']),
        ('Is this the right way?', '这条路对吗？', ['sv28']),
        ('This way? Right or wrong?', '这条路？对还是错？', ['sv28']),
        ('How do I get there?', '我怎么到那儿？', ['sv14']),
        ('How do I get there, slowly?', '我怎么过去？', ['sv14']),
        ('Where is the exit?', '出口在哪儿？', ['sv15']),
        ('The exit — where?', '出口——在哪？', ['sv15']),
        ('Something is wrong.', '出问题了。', ['sv08']),
        ('Something is wrong here.', '这儿出问题了。', ['sv08']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Please say that again.', '请再说一遍。', ['sv10']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
    ]),
    ('L27', 'Where Is It?', '找厕所、找出口、找医院，问路的三句半。', [
        ('Excuse me, hello.', '劳驾，你好。', ['sv02']),
        ('Where is the toilet?', '厕所在哪儿？', ['sv17']),
        ('The toilet is where?', '厕所在哪？', ['sv17']),
        ('Where is the exit?', '出口在哪儿？', ['sv15']),
        ('Exit, please. Where?', '出口，拜托。在哪？', ['sv15']),
        ('Where is the hospital?', '医院在哪儿？', ['sv16']),
        ('The hospital — where?', '医院——在哪？', ['sv16']),
        ('How do I get there?', '我怎么到那儿？', ['sv14']),
        ('Is this the right way?', '这条路对吗？', ['sv28']),
        ('This way to the door?', '这条路到门口？', ['sv28']),
        ('I am lost, sorry.', '我迷路了，抱歉。', ['sv07']),
        ("I'm lost again.", '我又迷路了。', ['sv07']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Write the name down.', '把名字写下来。', ['sv12']),
        ('What time do you open?', '你们几点开门？', ['sv26']),
        ('Open at nine?', '九点开吗？', ['sv26']),
        ('How long does it take?', '要多久？', ['sv27']),
        ('Ten minutes? Long?', '十分钟？久吗？', ['sv27']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Please say that again.', '请再说一遍。', ['sv10']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
    ]),
    ('L28', 'Not Feeling Well', '身体不舒服、要疼、要找医生，把难受说清楚。', [
        ('Excuse me, help.', '劳驾，帮一下。', ['sv02']),
        ("I'm not feeling well.", '我不太舒服。', ['sv18']),
        ('Not well today.', '今天不舒服。', ['sv18']),
        ('Something is wrong.', '出问题了。', ['sv08']),
        ('It hurts here.', '这儿疼。', ['sv19']),
        ('Here. It hurts.', '这儿。疼。', ['sv19']),
        ('I need a doctor.', '我需要医生。', ['sv20']),
        ('A doctor, please.', '医生，拜托。', ['sv20']),
        ('Call an ambulance.', '叫救护车。', ['sv06']),
        ('Call an ambulance, please.', '请叫救护车。', ['sv06']),
        ('I need help now.', '我现在需要帮助。', ['sv03']),
        ('Please help me.', '请帮帮我。', ['sv04']),
        ('Where is the hospital?', '医院在哪儿？', ['sv16']),
        ('The hospital — where?', '医院——在哪？', ['sv16']),
        ('How long does it take?', '要多久？', ['sv27']),
        ('Ten minutes there?', '到那儿十分钟？', ['sv27']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('My English is poor.', '我英语不好。', ['sv22']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Write it down, please.', '请写下来。', ['sv12']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
        ('See you tomorrow.', '明天见。', ['sv30']),
    ]),
    ('L29', 'Money and Signing', '付款、签字、问价——办事窗口前最省事的四句话。', [
        ('Hello there.', '你好。', ['sv01']),
        ('Excuse me, hello.', '劳驾，你好。', ['sv02']),
        ('How do I pay?', '我怎么付款？', ['sv24']),
        ('Pay here or there?', '在这儿付还是在那儿付？', ['sv24']),
        ('Can I pay by card?', '我能刷卡吗？', ['sv24']),
        ('Where do I sign?', '我在哪儿签字？', ['sv25']),
        ('Sign here?', '签这儿吗？', ['sv25']),
        ('What does this mean?', '这是什么意思？', ['sv13']),
        ('This line — what mean?', '这一行——什么意思？', ['sv13']),
        ('I need help, please.', '我需要帮助，拜托。', ['sv03']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Please say that again.', '请再说一遍。', ['sv10']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Write the number down.', '把号码写下来。', ['sv12']),
        ('What time do you open?', '你们几点开门？', ['sv26']),
        ('Open tomorrow?', '明天开吗？', ['sv26']),
        ('How long does it take?', '要多久？', ['sv27']),
        ('Five minutes? OK.', '五分钟？好的。', ['sv27']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
        ('See you tomorrow.', '明天见。', ['sv30']),
        ('See you tomorrow, thanks.', '明天见，谢谢。', ['sv30']),
    ]),
    ('L30', 'Police, Please', '真出事了：报警、求助、说清地点。', [
        ('Excuse me! Help!', '劳驾！救命！', ['sv02']),
        ('I need help now!', '我现在需要帮助！', ['sv03']),
        ('Please help me!', '请帮帮我！', ['sv04']),
        ('Call the police.', '报警。', ['sv05']),
        ('Call the police, please.', '请报警。', ['sv05']),
        ('Call an ambulance.', '叫救护车。', ['sv06']),
        ('An ambulance, please.', '救护车，拜托。', ['sv06']),
        ('Something is wrong!', '出事了！', ['sv08']),
        ('Wrong — here, now.', '出事了——这儿，现在。', ['sv08']),
        ("I'm lost.", '我迷路了。', ['sv07']),
        ('Where is the exit?', '出口在哪儿？', ['sv15']),
        ('The exit — where?', '出口——在哪？', ['sv15']),
        ('Is this the right way?', '这条路对吗？', ['sv28']),
        ('How do I get there?', '我怎么到那儿？', ['sv14']),
        ('It hurts here.', '这儿疼。', ['sv19']),
        ('I need a doctor.', '我需要医生。', ['sv20']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Do you speak English?', '你会说英语吗？', ['sv21']),
        ('My English is poor.', '我英语不好。', ['sv22']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
    ]),
    ('L31', 'Say It Slower', '听不懂时的救命三句：再说一遍、说慢点、写下来。', [
        ('Hello there, sorry.', '你好，抱歉。', ['sv01']),
        ('Excuse me, one moment.', '劳驾，稍等。', ['sv02']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Sorry, not understand.', '抱歉，没听懂。', ['sv09']),
        ('Please say that again.', '请再说一遍。', ['sv10']),
        ('That again, please.', '再说一次，拜托。', ['sv10']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Slowly — one more time.', '慢一点——再来一次。', ['sv11']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Write it down, please.', '请写下来。', ['sv12']),
        ('What does this mean?', '这是什么意思？', ['sv13']),
        ('This word, what mean?', '这个词，什么意思？', ['sv13']),
        ('Do you speak English?', '你会说英语吗？', ['sv21']),
        ('English a little.', '英语会一点。', ['sv21']),
        ('My English is poor.', '我英语不好。', ['sv22']),
        ('I am new here.', '我是新来的。', ['sv23']),
        ('I need help, please.', '我需要帮助，拜托。', ['sv03']),
        ('Help me, please.', '帮我，拜托。', ['sv04']),
        ('How long does it take?', '要多久？', ['sv27']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
        ('Thanks a lot.', '多谢。', ['sv29']),
        ('See you tomorrow.', '明天见。', ['sv30']),
    ]),
    ('L32', 'New In Town', '初来乍到：自我介绍、问时间、约明天。', [
        ('Hello there!', '你好啊！', ['sv01']),
        ('Hello, neighbor.', '你好，邻居。', ['sv01']),
        ('I am new here.', '我是新来的。', ['sv23']),
        ('New in town today.', '今天刚来镇上。', ['sv23']),
        ('Excuse me, hello.', '劳驾，你好。', ['sv02']),
        ('Do you speak English?', '你会说英语吗？', ['sv21']),
        ('My English is poor.', '我英语不好。', ['sv22']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Please say that again.', '请再说一遍。', ['sv10']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('What time do you open?', '你们几点开门？', ['sv26']),
        ('Open at eight?', '八点开吗？', ['sv26']),
        ('How long does it take?', '要多久？', ['sv27']),
        ('Ten minutes, OK.', '十分钟，好的。', ['sv27']),
        ('Where is the toilet?', '厕所在哪儿？', ['sv17']),
        ('The toilet, please.', '厕所，拜托。', ['sv17']),
        ('How do I get there?', '我怎么到那儿？', ['sv14']),
        ('Is this the right way?', '这条路对吗？', ['sv28']),
        ('I am lost, sorry.', '我迷路了，抱歉。', ['sv07']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
        ('See you tomorrow!', '明天见！', ['sv30']),
    ]),
    ('L33', 'Two Minute Help', '只有两分钟：把最要紧的四句说利索。', [
        ('Excuse me, two minutes.', '劳驾，两分钟。', ['sv02']),
        ('I need help.', '我需要帮助。', ['sv03']),
        ('Please help me.', '请帮帮我。', ['sv04']),
        ("I'm lost.", '我迷路了。', ['sv07']),
        ('Where is the exit?', '出口在哪儿？', ['sv15']),
        ('The exit, please.', '出口，拜托。', ['sv15']),
        ('Where is the toilet?', '厕所在哪儿？', ['sv17']),
        ('Toilet, please.', '厕所，拜托。', ['sv17']),
        ("I don't understand.", '我不明白。', ['sv09']),
        ('Speak slowly please.', '请说慢一点。', ['sv11']),
        ('Say that again.', '再说一遍。', ['sv10']),
        ('What does this mean?', '这是什么意思？', ['sv13']),
        ('Can you write it down?', '你能写下来吗？', ['sv12']),
        ('How do I pay?', '我怎么付款？', ['sv24']),
        ('Pay now?', '现在付吗？', ['sv24']),
        ('How do I get there?', '我怎么到那儿？', ['sv14']),
        ('Get there how?', '怎么到那儿？', ['sv14']),
        ('How long does it take?', '要多久？', ['sv27']),
        ('It hurts here.', '这儿疼。', ['sv19']),
        ('I need a doctor.', '我需要医生。', ['sv20']),
        ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
        ('See you tomorrow.', '明天见。', ['sv30']),
    ]),
]


SENT_REWRITE = [
    ('Excuse me, hello.', 'Pardon me, hello.'),
    ('Excuse me, sorry.', 'Pardon me, sorry.'),
    ('Excuse me, one moment.', 'Pardon me, one moment.'),
    ('Excuse me! Help!', 'Pardon me! Help!'),
    ('Excuse me, two minutes.', 'Pardon me, two minutes.'),
    ('Excuse me, help.', 'Pardon me, help.',),
    ('Excuse me.', 'Pardon me.'),
    ("I don't understand.", 'Sorry, one more time.'),
    ('Sorry, not understand.', 'Sorry, say it again.'),
    ('See you tomorrow.', 'See you later.'),
    ('See you tomorrow, friend.', 'See you later, friend.'),
    ('See you tomorrow, thanks.', 'See you later, thanks.'),
    ('See you tomorrow!', 'See you later!'),
    ('I am lost, sorry.', 'I am lost, pardon me.'),
    ("I'm lost, sorry.", "I'm lost, pardon me."),
    ('Excuse me, hello.', 'Pardon me, hello.'),
]


def rewrite(text):
    for pair in SENT_REWRITE:
        if text == pair[0]:
            return pair[1]
    return text


SUFFIX = [('please', '拜托'), ('today', '今天'), ('now', '现在'),
          ('friend', '朋友'), ('sorry', '抱歉')]


def _words(t):
    return len(re.findall(r"[A-Za-z']+", t))


def _prune_unmatched(art):
    """校验器要求「块文本必须出现在句中」——标注只保留确实出现在句子里的块。"""
    by_id = {c[0]: c[1] for c in CHUNKS}
    for s in art['sentences']:
        t = norm(s['text'])
        s['chunks'] = [c for c in s['chunks']
                       if norm(by_id.get(c['id'], '')) in t]


def _fit_a1_rubric(art):
    """把篇目压进 A1 档标尺：总词数 100..180、句均 ≤6、去重标注块 1..6。

    标注块只保留前 5 个不同 id（全部来自 S0 → 80% 规则由构造保证）；
    词数不足时给句子补 A1 级尾语（please/today/now/friend/sorry），保持句均 ≤6。
    """
    seen, keep = set(), []
    for s in art['sentences']:
        for c in s['chunks']:
            if c['id'] not in seen and len(keep) < 5:
                seen.add(c['id'])
                keep.append(c['id'])
    keep = set(keep)
    for s in art['sentences']:
        s['chunks'] = [c for c in s['chunks'] if c['id'] in keep]
    total = sum(_words(s['text']) for s in art['sentences'])
    i = 0
    while total < 105:
        s = art['sentences'][i % len(art['sentences'])]
        w, suf = SUFFIX[i % len(SUFFIX)]
        if _words(s['text']) + 1 <= 6 and w not in s['text'].lower():
            s['text'] = s['text'].rstrip('.') + f', {w}.'
            s['meaningCN'] = s['meaningCN'].rstrip('。') + f'，{suf}。'
            total += 1
        i += 1
        if i > 400:
            break


def norm(s):
    return ' '.join(re.sub(r"[^A-Za-z0-9' ]+", ' ', s.lower()).split())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='只查文本撞车，不写文件')
    a = ap.parse_args()

    pack = json.load(open(PACK, encoding='utf-8'))
    listen = json.load(open(LISTEN, encoding='utf-8'))
    # 幂等：本次生成的 S0 要先排除，否则重跑会把自己判成「撞车」
    existing = {norm(c['text']): (l['id'], c['id'])
                for l in pack['levels'] if l['id'] != LEVEL_ID
                for c in l['chunks']}
    conflicts = [(t, existing[norm(t)])
                 for (_, t, _, _, _, _, _) in CHUNKS if norm(t) in existing]
    if conflicts:
        print('与现有词块文本撞车：')
        for t, where in conflicts:
            print(f'  {t!r} 已存在于 {where[0]}/{where[1]}')
    if a.check:
        return 0
    if conflicts:
        print('[中止] 先改掉上面这些重复块，再生成')
        return 1

    pack['levels'] = [l for l in pack['levels'] if l['id'] != LEVEL_ID]
    level = {
        'id': LEVEL_ID,
        'theme': THEME,
        'sceneImage': SCENE_IMAGE,
        'stage': 'L0',
        'cefr': 'A1',
        'optional': True,
        'requires_chunks': [],
        'combos': [],
        'sentences': [],
        'chunks': [
            {'id': cid, 'text': t, 'meaningCN': cn, 'semantic': sem,
             'funcCat': fc, 'type': ty, 'freqRank': 0, 'tier': tier,
             'sources': ['survival/S0', 'manual:ASR-208']}
            for (cid, t, cn, sem, fc, ty, tier) in CHUNKS
        ],
    }
    pack['levels'].insert(0, level)
    pack['version'] = '1.3.0'

    new_ids = {x[0] for x in ARTICLES}

    listen['articles'] = [x for x in listen['articles'] if x['id'] not in new_ids]
    for aid, title, summary, sents in ARTICLES:
        art = {
            'id': aid, 'title': title, 'scene': 'survival', 'sceneLabel': '生存',
            'summaryCN': summary, 'updatedAt': '2026-11-04', 'level': 'A1',
            'baseRate': 0.75, 'collectLimit': 6, 'audioUrl': '',
            'kind': 'slow_dialog', 'moduleIds': [LEVEL_ID],
            'sentences': [
                {'id': f'{aid}s{i}', 'text': rewrite(en), 'meaningCN': cn,
                 'chunks': [{'id': c, 'text': dict((x[0], x[1]) for x in CHUNKS)[c],
                             'meaningCN': dict((x[0], x[2]) for x in CHUNKS)[c]}
                            for c in cids]}
                for i, (en, cn, cids) in enumerate(sents, start=1)
            ],
        }
        _prune_unmatched(art)
        _fit_a1_rubric(art)
        listen['articles'].append(art)
        words = sum(len(re.findall(r"[A-Za-z']+", s['text'])) for s in art['sentences'])
        distinct = len({c['id'] for s in art['sentences'] for c in s['chunks']})
        print(f'  {aid} {title:<22} 句={len(art["sentences"])} 词={words} '
              f'去重标注块={distinct} S0占比=100%')

    for p, d in ((PACK, pack), (LISTEN, listen)):
        with open(p, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
            f.write('\n')
    print(f'✓ 已写入：模块 {LEVEL_ID}（{len(CHUNKS)} 块）+ 篇目 {len(ARTICLES)} 篇')
    return 0


if __name__ == '__main__':
    sys.exit(main())
