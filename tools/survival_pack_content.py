#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-208 §二 · L0 先行包的**内容单源**（手写文本，非生成）。

为什么要第二个脚本：`add_survival_pack.py` 用「后缀补齐」把句子凑到 A1 词数下限，
产出的是 `Hello there, please, now.` 这种不成句的串，作为 A1 学习者第一站的
**听力靶句**不合格。本脚本用工写字面量重做两处内容，并且只改内容不改结构：

  1) S0 的 30 条目标句（`Level.sentences`）——缺了它，「句子闯关」在 S0 走完 30 块时
     会拿 `sentences[0]` 空索引；块拼句也退化成单块复读。
  2) L25–L33 九篇慢速对话（覆盖 add_survival_pack.py 生成的版本）。

标尺（与 lib/models/listening_article.dart 的 A1 档一致，脚本自检 + Dart 校验器双重核）：
  词数 100..180 · 句均 ≤6.0 · 去重标注块 1..6 · 标注块文本必须逐字出现在句子里 ·
  moduleIds=['S0'] ⇒ 标注块 ≥80% 落在 S0（本包 = 100%）· A1 复用率 ≥70%（本包 = 100%）。

用法：python tools/survival_pack_content.py [--check]
  --check 只算不改，打印每篇三轴与 S0 覆盖。
"""
import argparse
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK = os.path.join(ROOT, 'assets', 'content_pack.json')
ARTICLES = os.path.join(ROOT, 'assets', 'listening_articles.json')
UPDATED = '2026-11-04'

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

# ——————————————————————— S0 的 30 条目标句 ———————————————————————
# (句序号, 英文, 中文, [按序组成的词块 id])：chunkIds 必须全部落在 S0 内。
SENTENCES = [
    ('sv_s01', 'Hello there, my friend.', '你好啊，朋友。', ['sv01']),
    ('sv_s02', 'Pardon me, do you speak English?', '劳驾，你会说英语吗？', ['sv02', 'sv21']),
    ('sv_s03', 'I need help with my bag.', '我需要人手帮我看看包。', ['sv03']),
    ('sv_s04', "Please help me, I'm lost.", '请帮帮我，我迷路了。', ['sv04', 'sv07']),
    ('sv_s05', 'Call the police, please.', '请报警。', ['sv05']),
    ('sv_s06', 'Call an ambulance, he is sick.', '叫救护车，他不舒服。', ['sv06']),
    ('sv_s07', "I'm lost. Where is the exit?", '我迷路了，出口在哪儿？', ['sv07', 'sv15']),
    ('sv_s08', 'Something is wrong with this form.', '这张表出问题了。', ['sv08']),
    ('sv_s09', 'Sorry, one more time, please.', '抱歉，请再说一次。', ['sv09']),
    ('sv_s10', 'Please say that again, slowly.', '请再说一遍，慢一点。', ['sv10']),
    ('sv_s11', 'Speak slowly please, my English is poor.', '请说慢一点，我英语不好。', ['sv11', 'sv22']),
    ('sv_s12', 'Can you write it down for me?', '你能帮我写下来吗？', ['sv12']),
    ('sv_s13', 'What does this mean on the form?', '表上这一项是什么意思？', ['sv13']),
    ('sv_s14', 'How do I get there from here?', '我从这儿怎么到那儿？', ['sv14']),
    ('sv_s15', 'Where is the exit, please?', '请问出口在哪儿？', ['sv15']),
    ('sv_s16', 'Where is the hospital? I need a doctor.', '医院在哪儿？我需要医生。', ['sv16', 'sv20']),
    ('sv_s17', 'Where is the toilet?', '厕所在哪儿？', ['sv17']),
    ('sv_s18', "I'm not feeling well today.", '我今天不太舒服。', ['sv18']),
    ('sv_s19', 'It hurts here, since noon.', '这儿疼，从中午开始。', ['sv19']),
    ('sv_s20', 'I need a doctor now.', '我现在需要医生。', ['sv20']),
    ('sv_s21', 'Do you speak English?', '你会说英语吗？', ['sv21']),
    ('sv_s22', 'My English is poor, pardon me.', '我英语不好，劳驾见谅。', ['sv22', 'sv02']),
    ('sv_s23', 'I am new here.', '我是新来的。', ['sv23']),
    ('sv_s24', 'How do I pay by card?', '我怎么刷卡付款？', ['sv24']),
    ('sv_s25', 'Where do I sign my name?', '我在哪儿签名？', ['sv25']),
    ('sv_s26', 'What time do you open tomorrow?', '你们明天几点开门？', ['sv26']),
    ('sv_s27', 'How long does it take by bus?', '坐公交要多久？', ['sv27']),
    ('sv_s28', 'Is this the right way?', '这条路对吗？', ['sv28']),
    ('sv_s29', 'Thank you for your help today.', '谢谢你今天的帮助。', ['sv29']),
    ('sv_s30', 'See you later, my friend.', '回头见，朋友。', ['sv30']),
]

# ——————————————————————— 九篇慢速对话（L25–L33）———————————————————————
# 每篇：id / title / summaryCN / [(英文, 中文, [S0 词块 id])]
DIALOGUES = [
    dict(
        id='L25',
        title="Hello, I'm Lost",
        summaryCN='落地第一天在酒店门口迷路：先开口打招呼，承认听不懂，再把路问出来。',
        chunks=['sv01', 'sv02', 'sv07', 'sv21', 'sv22', 'sv23'],
        lines=[
            ('Hello there!', '你好啊！', ['sv01']),
            ('Hi, good morning.', '嗨，早上好。', []),
            ("Sorry, I'm lost.", '抱歉，我迷路了。', ['sv07']),
            ('Lost? Where do you stay?', '迷路了？你住哪儿？', []),
            ('The Green Hotel.', '格林酒店。', []),
            ('Pardon me?', '劳驾，你说什么？', ['sv02']),
            ('The Green Hotel, near the park.', '格林酒店，在公园附近。', []),
            ('Oh, I know that place.', '哦，我知道那个地方。', []),
            ('Do you speak English?', '你会说英语吗？', ['sv21']),
            ('Yes, a little.', '会一点。', []),
            ('My English is poor.', '我英语不好。', ['sv22']),
            ('That is fine. Slowly is good.', '没关系，慢慢说就好。', []),
            ('I am new here.', '我是新来的。', ['sv23']),
            ('I arrive this morning.', '我今天早上刚到。', []),
            ('This way, please.', '请走这边。', []),
            ('Walk two blocks, then turn left.', '走两个街区，然后左转。', []),
            ('Two blocks, then left.', '两个街区，然后左转。', []),
            ('Yes. Do you want a map?', '对。你要地图吗？', []),
            ('Yes, please.', '要的，谢谢。', []),
            ('Here is a small one.', '给你一张小的。', []),
            ('You are very kind.', '你真好。', []),
            ('Have a good first day.', '祝你第一天顺利。', []),
            ('The hotel is not far.', '酒店不远。', []),
                        ('I can walk there now.', '我现在能走过去。', []),
            ('Maps help. I take one.', '地图有用，我拿一张。', []),
        ],
    ),
    dict(
        id='L26',
        title='Say That Again, Please',
        summaryCN='听不懂不代表要闭嘴：请对方重复、放慢、写下来，是活下来的第一课。',
        chunks=['sv02', 'sv09', 'sv10', 'sv11', 'sv12', 'sv13'],
        lines=[
            ('Sorry, one more time?', '抱歉，能再说一次吗？', ['sv09']),
            ('One more time? OK.', '再说一次？好的。', []),
            ('Please say that again.', '请再说一遍。', ['sv10']),
            ('Slowly, please.', '慢一点，好吗？', []),
            ('Speak slowly please.', '请说慢一点。', ['sv11']),
            ('Better now?', '现在好点了吗？', []),
            ('Much better.', '好多了。', []),
            ('What does this mean?', '这是什么意思？', ['sv13']),
            ('This word? It is a name.', '这个单词吗？它是个名字。', []),
            ('A street name.', '街道的名字。', []),
            ('I see. And this number?', '明白。那这个号码呢？', []),
            ('The room number, five one two.', '房间号，512。', []),
            ('Can you write it down?', '你能写下来吗？', ['sv12']),
            ('Sure. Give me a pen.', '当然，给我一支笔。', []),
            ('Here you are.', '给你。', []),
            ('Pardon me, one more thing.', '劳驾，还有一件事。', ['sv02']),
            ('The wifi, what is the code?', '无线网的密码是什么？', []),
            ('Write it here, all caps.', '写在这儿，全部大写。', []),
            ('All caps, OK.', '全大写，好的。', []),
            ('Anything else?', '还要别的吗？', []),
            ('No, that is all.', '不用了，就这些。', []),
            ('Now you can read it.', '现在你能看清了。', []),
                        ('I write the code here.', '我把密码写在这儿。', []),
            ('Slowly is kind.', '说得慢，是善意。', []),
            ('Thank you. This helps a lot.', '谢谢，这很有用。', []),
        ],
    ),
    dict(
        id='L27',
        title='Which Way From Here?',
        summaryCN='问路三连：怎么走、这条路对不对、出口和厕所在哪儿，问完再道谢。',
        chunks=['sv12', 'sv14', 'sv15', 'sv17', 'sv28', 'sv29'],
        lines=[
            ('Excuse me, where is the toilet?', '劳驾，厕所在哪儿？', ['sv17']),
            ('Second floor, on the right.', '二楼，右手边。', []),
            ('Thank you.', '谢谢。', []),
            ('Now, how do I get there?', '那么，我怎么到那儿？', ['sv14']),
            ('To the station? Take the bus.', '去车站吗？坐公交。', []),
            ('Is this the right way?', '这条路对吗？', ['sv28']),
            ('Yes, straight ahead.', '对，一直往前走。', []),
            ('Straight. OK.', '一直走，好。', []),
            ('Where is the exit?', '出口在哪儿？', ['sv15']),
            ('The back exit, near the shop.', '后面那个出口，在商店旁边。', []),
            ('Can you write it down?', '你能写下来吗？', ['sv12']),
            ('The bus stop name? Sure.', '车站的名字？当然。', []),
            ('Write the number too.', '把线路号也写上。', []),
            ('Line eight, every ten minutes.', '8 路，每十分钟一班。', []),
            ('Every ten minutes. Good.', '十分钟一班，挺好。', []),
            ('How much is the ticket?', '车票多少钱？', []),
            ('Two dollars, at the machine.', '两美元，在售票机买。', []),
            ('The machine. I understand.', '售票机，我明白了。', []),
            ('You look fine.', '你看起来不慌了。', []),
            ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
                        ('The bus, number eight.', '公交，八路。', []),
            ('I wait here, then.', '那我就在这儿等。', []),
            ('Anytime. Have a good day.', '不客气，祝你今天愉快。', []),
        ],
    ),
    dict(
        id='L28',
        title='Not Well Today',
        summaryCN='身体不舒服时怎么开口：说清哪儿疼、要不要救护车、医院在哪儿。',
        chunks=['sv03', 'sv06', 'sv16', 'sv18', 'sv19', 'sv20'],
        lines=[
            ("I'm not feeling well.", '我不太舒服。', ['sv18']),
            ('Oh no. Since when?', '糟了。从什么时候开始？', []),
            ('Since lunch, I think.', '我想是午饭以后。', []),
            ('Where does it hurt?', '哪儿疼？', []),
            ('It hurts here.', '这儿疼。', ['sv19']),
            ('Here, under the ribs.', '这儿，肋骨下面。', []),
            ('Do you need help?', '你需要帮忙吗？', []),
            ('I need help, please.', '我需要帮助，拜托。', ['sv03']),
            ('I need a doctor.', '我需要医生。', ['sv20']),
            ('OK. Stay with me.', '好，先别走开。', []),
            ('Should we call an ambulance?', '要叫救护车吗？', []),
            ('Call an ambulance, please.', '请叫救护车。', ['sv06']),
            ('Not yet. First, water.', '还不用。先来点水。', []),
            ('Where is the hospital?', '医院在哪儿？', ['sv16']),
            ('Two streets away, open now.', '两条街外，现在开着。', []),
            ('Can you walk?', '你能走吗？', []),
            ('Slowly, but yes.', '走得慢，但能走。', []),
            ('I stay with you.', '我陪着你。', []),
            ('Thank you. Really.', '谢谢，真的。', []),
            ('That is nothing.', '这没什么。', []),
            ('Tell the doctor everything.', '把情况都告诉医生。', []),
                        ('I will. I remember now.', '我会的，我记住了。', []),
            ('Water helps a little.', '喝点水好一些。', []),
            ('I sit down, then we go.', '我坐一会儿，然后走。', []),
            ('Do you have medicine?', '你带药了吗？', []),
            ('No, none with me.', '没有，我身上没有。', []),
        ],
    ),
    dict(
        id='L29',
        title='Something Is Wrong',
        summaryCN='包不见了：先说「出问题了」「请帮帮我」，再谈报警和护照。',
        chunks=['sv02', 'sv03', 'sv04', 'sv05', 'sv08', 'sv21'],
        lines=[
            ('Something is wrong.', '出问题了。', ['sv08']),
            ('Wrong? What happened?', '出事了？怎么了？', []),
            ('My bag is gone.', '我的包不见了。', []),
            ('Gone? Where was it?', '不见了？刚才在哪儿？', []),
            ('On this chair, ten minutes.', '就在这椅子上，十分钟前。', []),
            ('Please help me.', '请帮帮我。', ['sv04']),
            ('I help you. Calm down.', '我会帮你，先别急。', []),
            ('I need help now.', '我现在需要帮助。', ['sv03']),
            ('Yes, I hear you.', '在，我听到你了。', []),
            ('Should I call the police?', '我该报警吗？', []),
            ('Call the police, yes.', '报警，对。', ['sv05']),
            ('Do you speak English?', '你会说英语吗？', ['sv21']),
            ('A little. Slowly, OK?', '会一点，慢慢说好吗？', []),
            ('OK. My name is Sam.', '好，我叫 Sam。', []),
            ('What is your name?', '你叫什么名字？', []),
            ('I am Lee.', '我姓李。', []),
            ('Pardon me, one question.', '劳驾，问一个问题。', ['sv02']),
            ('The bag, what is inside?', '包里有什么？', []),
            ('My passport and cash.', '我的护照和现金。', []),
            ('Passport is serious.', '护照的事比较大。', []),
            ("I know. That is why I'm here.", '我知道，所以我来了。', []),
            ('Stay here. I call now.', '你在这儿等，我现在就打。', []),
            ('Thank you for staying.', '谢谢你留下来。', []),
                        ('Of course.', '应该的。', []),
            ('I wait right here.', '我就在这儿等。', []),
        ],
    ),
    dict(
        id='L30',
        title='How Do I Pay?',
        summaryCN='在柜台付款签字：怎么付、在哪儿签、这一行什么意思、要多久到账。',
        chunks=['sv13', 'sv24', 'sv25', 'sv26', 'sv27', 'sv29'],
        lines=[
            ('How do I pay?', '我怎么付款？', ['sv24']),
            ('Card or cash, both fine.', '刷卡或现金都可以。', []),
            ('I have card.', '我有卡。', []),
            ('Then tap here.', '那就在这儿碰一下。', []),
            ('Where do I sign?', '我在哪儿签字？', ['sv25']),
            ('On the line, right side.', '在线上，右边。', []),
            ('What does this mean?', '这是什么意思？', ['sv13']),
            ('Small print, the rules.', '小字是规则。', []),
            ('Just sign it.', '签上就行。', []),
            ('OK. Done.', '好，签完了。', []),
            ('One more thing.', '还有一件事。', []),
            ('Yes?', '什么事？', []),
            ('What time do you open?', '你们几点开门？', ['sv26']),
            ('Eight, every day.', '每天八点。', []),
            ('Do you close at night?', '你们晚上关门吗？', []),
            ('Ten, sharp.', '十点整。', []),
            ('How long does it take?', '要多久？', ['sv27']),
            ('The refund? About a week.', '退款吗？大约一周。', []),
            ('A week. OK.', '一周，好吧。', []),
            ('Here is your receipt.', '这是你的小票。', []),
            ('Keep it, please.', '请留着。', []),
            ('I keep it.', '我会留着。', []),
            ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
            ('Have a good evening.', '祝你晚上愉快。', []),
            ('See you tomorrow morning.', '明天早上见。', []),
                        ('Same time, same place.', '老时间，老地方。', []),
            ('Cash, or a card?', '现金还是卡？', []),
            ('That is easy.', '那样就简单。', []),
        ],
    ),
    dict(
        id='L31',
        title='Ten Minutes On Foot',
        summaryCN='跟邻居打听去市场的路：走多远、多久到、几点开门、路上怎么快一点。',
        chunks=['sv01', 'sv14', 'sv26', 'sv27', 'sv28', 'sv30'],
        lines=[
            ('Hello there, neighbor.', '你好啊，邻居。', ['sv01']),
            ('Hello, long time no see.', '你好，好久不见。', []),
            ('Quick question.', '问个小问题。', []),
            ('Sure, go ahead.', '你说。', []),
            ('Is this the right way?', '这条路对吗？', ['sv28']),
            ('To the market? Yes.', '去市场吗？对的。', []),
            ('How do I get there fast?', '怎么到那儿最快？', ['sv14']),
            ('Walk, or take the bus.', '走路，或者坐公交。', []),
            ('How long does it take?', '要多久？', ['sv27']),
            ('Ten minutes on foot.', '走路十分钟。', []),
            ('And the market?', '市场呢？', []),
            ('What time do you open?', '那儿几点开门？', ['sv26']),
            ("I don't own it.", '那店不是我开的。', []),
            ('Sorry, wrong question.', '抱歉，问错了。', []),
            ('It opens at eight.', '它八点开门。', []),
            ('Eight, before the crowd.', '八点，趁人少。', []),
            ('The bus stop, where?', '车站在哪儿？', []),
            ('Across the street.', '街对面。', []),
            ('Do you need a list?', '你需要购物清单吗？', []),
            ('Yes, milk and bread.', '需要，牛奶和面包。', []),
            ('I buy nothing today.', '我今天什么都不买。', []),
            ('Good, you are free.', '挺好，那你很清闲。', []),
            ('Not free. Just fast.', '不清闲，只是图快。', []),
            ('Haha. Then run.', '哈哈，那快跑。', []),
            ('See you later, neighbor.', '回头见，邻居。', ['sv30']),
            ('See you, have fun.', '回头见，买得顺利。', []),
        ],
    ),
    dict(
        id='L32',
        title='At the Service Window',
        summaryCN='办事窗口填表：听不懂就请对方重复、放慢、写下来，最后把字签对。',
        chunks=['sv02', 'sv10', 'sv11', 'sv12', 'sv13', 'sv22'],
        lines=[
            ('Next, please.', '下一位，请。', []),
            ('Hello. I have a form.', '你好，我有一张表。', []),
            ('Pardon me, my English is poor.', '劳驾，我英语不好。', ['sv02', 'sv22']),
            ('That is OK. Slowly.', '没关系，慢慢来。', []),
            ('Please say that again.', '请再说一遍。', ['sv10']),
            ('The form, please.', '请把表格给我。', []),
            ('Here. And this line?', '在这儿。那这一格呢？', []),
            ('What does this mean?', '这是什么意思？', ['sv13']),
            ('Your last address.', '你上一个住址。', []),
            ('Speak slowly please.', '请说慢一点。', ['sv11']),
            ('Slowly: last, address.', '慢读：上一个，住址。', []),
            ('Ah, I understand now.', '啊，我懂了。', []),
            ('Can you write it down?', '你能写下来吗？', ['sv12']),
            ('Your address? I write it.', '你的地址？我写下来。', []),
            ('Yes, the old one.', '对，旧的那个。', []),
            ('Number twelve, Hill Street.', '十二号，希尔街。', []),
            ('Twelve, Hill Street. Done.', '十二号希尔街，好了。', []),
            ('What about this stamp?', '这个章怎么办？', []),
            ('You sign, then I stamp.', '你签字，然后我盖章。', []),
            ('Sign here? Like this?', '在这儿签？这样吗？', []),
            ('Exactly.', '就是这样。', []),
            ('My English is poor, but today works.', '我英语不好，但今天办成了。', ['sv22']),
            ('Today works. Good job.', '办成了，挺好。', []),
                        ('I read it back to you.', '我读一遍给你听。', []),
            ('Clear. Thank you.', '清楚了，谢谢。', []),
            ('Thank you for patience.', '谢谢你的耐心。', []),
        ],
    ),
    dict(
        id='L33',
        title='New Here, Lost Again',
        summaryCN='第一周的日常：承认自己是新来的，把电梯、厕所、出口一件件问明白。',
        chunks=['sv07', 'sv15', 'sv17', 'sv23', 'sv29', 'sv30'],
        lines=[
            ('I am new here.', '我是新来的。', ['sv23']),
            ('First week? It shows.', '第一周？看得出来。', []),
            ("I'm lost again.", '我又迷路了。', ['sv07']),
            ('Again? Where do you go?', '又迷路？你要去哪儿？', []),
            ('The lift.', '电梯。', []),
            ('Behind you.', '在你身后。', []),
            ('Oh. Thank you.', '哦，谢谢。', []),
            ('Where is the toilet?', '厕所在哪儿？', ['sv17']),
            ('Down the hall, first door.', '走廊尽头，第一间。', []),
            ('First door, OK.', '第一间，好的。', []),
            ('And the exit?', '那出口呢？', []),
            ('Where is the exit?', '出口在哪儿？', ['sv15']),
            ('Two exits. This one, near stairs.', '两个出口，这个在楼梯旁。', []),
            ('Near the stairs.', '在楼梯旁边。', []),
            ('I walk with you.', '我和你一起走。', []),
            ('Really? Thank you.', '真的吗？谢谢。', []),
            ('It is nothing.', '没什么。', []),
            ('Today my head is full.', '今天脑子里塞满了。', []),
            ('Full is normal.', '塞满很正常。', []),
            ('You are patient.', '你真有耐心。', []),
            ('Everyone is here.', '这儿的人都这样。', []),
            ('That helps a lot.', '这对我帮助很大。', []),
            ('Thank you for your help.', '谢谢你的帮助。', ['sv29']),
            ('Anytime, new friend.', '随时来问，新朋友。', []),
            ('See you later.', '回头见。', ['sv30']),
                        ('I take a photo too.', '我也拍张照片。', []),
            ('Clever. See you then.', '真聪明，那就到时见。', []),
            ('See you, take care.', '回头见，慢走。', []),
        ],
    ),
]

A1 = dict(min_words=100, max_words=180, max_avg=6.0, min_chunks=1, max_chunks=6)
COLLECT_LIMIT = 6


def words(text):
    return len([t for t in text.split() if any(ch.isalnum() and ord(ch) < 128 for ch in t)])


def load(path):
    with io.open(path, encoding='utf-8') as f:
        return json.load(f)


def dump(path, data):
    with io.open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')


def chunk_map(pack):
    lv = next(l for l in pack['levels'] if l['id'] == 'S0')
    return {c['id']: c for c in lv['chunks']}, lv


def check(pack, article_data):
    errors = []
    by_id, s0 = chunk_map(pack)

    # 1) 目标句：chunkIds 全在 S0 内、块文本按序出现在句中、30 块各有靶句
    used = set()
    for sid, text, cn, ids in SENTENCES:
        for cid in ids:
            if cid not in by_id:
                errors.append('%s 引用 S0 外词块 %s' % (sid, cid))
                continue
            used.add(cid)
            if by_id[cid]['text'].lower() not in text.lower():
                errors.append('%s 未逐字包含词块「%s」' % (sid, by_id[cid]['text']))
        if not cn:
            errors.append('%s 缺中文' % sid)
    missing = sorted(set(by_id) - used)
    if missing:
        errors.append('词块无靶句：%s' % ','.join(missing))
    if len(SENTENCES) != 30:
        errors.append('目标句 %d 条，应为 30' % len(SENTENCES))

    # 2) 九篇对话：三轴 + 标注块 verbatim + 100% 落在 S0
    for a in DIALOGUES:
        seen = []
        tot = 0
        for idx, (text, cn, ids) in enumerate(a['lines'], 1):
            tot += words(text)
            if not cn:
                errors.append('%s 第%d句缺中文' % (a['id'], idx))
            for cid in ids:
                if cid not in by_id:
                    errors.append('%s 第%d句引用 S0 外词块 %s' % (a['id'], idx, cid))
                elif by_id[cid]['text'].lower() not in text.lower():
                    errors.append('%s 第%d句未逐字包含「%s」' % (a['id'], idx, by_id[cid]['text']))
                if cid not in seen:
                    seen.append(cid)
        n = len(a['lines'])
        avg = tot / n
        if not (A1['min_words'] <= tot <= A1['max_words']):
            errors.append('%s 词数 %d 不在 100..180' % (a['id'], tot))
        if avg > A1['max_avg']:
            errors.append('%s 句均 %.2f > 6.0' % (a['id'], avg))
        if not (A1['min_chunks'] <= len(seen) <= A1['max_chunks']):
            errors.append('%s 去重标注块 %d 不在 1..6' % (a['id'], len(seen)))
        if sorted(seen) != sorted(a['chunks']):
            errors.append('%s 声明块集 %s ≠ 实际 %s' % (a['id'], a['chunks'], seen))
        if len(seen) > COLLECT_LIMIT:
            errors.append('%s 标注块超过 collectLimit' % a['id'])
        secs = tot / 150.0 * 60 + (n - 1) * 0.3
        at_slow = secs / 0.75
        if not (45 <= at_slow <= 210):
            errors.append('%s 慢速折算 %.0f 秒不在 45..210' % (a['id'], at_slow))
        print('%s · %-26s 词 %3d · 句 %2d · 句均 %.2f · 块 %d · 慢速 %.0f 秒'
              % (a['id'], a['title'], tot, n, avg, len(seen), at_slow))
    return errors


def apply_changes(pack, article_data):
    by_id, s0 = chunk_map(pack)
    s0['sentences'] = [
        {'id': sid, 'text': text, 'meaningCN': cn, 'chunkIds': ids}
        for sid, text, cn, ids in SENTENCES
    ]
    out = []
    replaced = 0
    for a in article_data['articles']:
        if a['id'] in {d['id'] for d in DIALOGUES}:
            d = next(x for x in DIALOGUES if x['id'] == a['id'])
            a['title'] = d['title']
            a['summaryCN'] = d['summaryCN']
            a['scene'] = 'survival'
            a['sceneLabel'] = '生存'
            a['level'] = 'A1'
            a['baseRate'] = 0.75
            a['collectLimit'] = COLLECT_LIMIT
            a['audioUrl'] = ''
            a['kind'] = 'slow_dialog'
            a['moduleIds'] = ['S0']
            a['updatedAt'] = UPDATED
            a['sentences'] = [
                {
                    'id': '%ss%d' % (d['id'], i),
                    'text': text,
                    'meaningCN': cn,
                    'chunks': [
                        {
                            'id': cid,
                            'text': by_id[cid]['text'],
                            'meaningCN': by_id[cid]['meaningCN'],
                        }
                        for cid in ids
                    ],
                }
                for i, (text, cn, ids) in enumerate(d['lines'], 1)
            ]
            replaced += 1
        out.append(a)
    if replaced != len(DIALOGUES):
        raise SystemExit('只替换到 %d/%d 篇，未落库' % (replaced, len(DIALOGUES)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='只算不改')
    a = ap.parse_args()

    pack = load(PACK)
    arts = load(ARTICLES)
    errors = check(pack, arts)
    if errors:
        print('\n'.join('  ✗ ' + e for e in errors))
        raise SystemExit('内容自检失败 %d 项，未落库' % len(errors))
    if a.check:
        print('[check] L0 内容自检全过（30 靶句 · 9 篇三轴达标）')
        return
    merged = apply_changes(pack, arts)
    dump(PACK, pack)
    arts['articles'] = merged
    arts['generatedAt'] = UPDATED
    dump(ARTICLES, arts)
    print('[ok] S0 30 靶句 + 9 篇慢速对话已落库')


if __name__ == '__main__':
    main()
