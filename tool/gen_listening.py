import json, re, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
pack = json.loads((ROOT / "assets/content_pack.json").read_text(encoding="utf-8"))
chunks = {}
for lv in pack["levels"]:
    for c in lv["chunks"]:
        chunks[c["id"]] = c

def E(i):
    return ("e", i)

def N(text, cn):
    return ("n", text, cn)

S = lambda text, cn, *cs: (text, cn, list(cs))

# 分级标尺（指令 S §一.1，与 lib/models/listening_article.dart 的 ListeningLevel 同值）：
# 三轴 = 总词数 / 句均词数 / 标注块数；baseRate 走播放速率，不进音频缓存键。
LEVELS = {
    "A1": dict(rate=0.75, words=(100, 180), avg=(0.0, 6.0), chunks=(1, 6),
               existing=(4, 6), cand=(0, 1), reuse_min=0.70),
    "A2": dict(rate=0.75, words=(181, 260), avg=(6.1, 7.4), chunks=(6, 8),
               existing=(5, 6), cand=(1, 3)),
    "B1": dict(rate=1.00, words=(261, 360), avg=(7.5, 9.4), chunks=(7, 8),
               existing=(5, 6), cand=(1, 3)),
    "B2": dict(rate=1.00, words=(361, 430), avg=(9.5, 11.9), chunks=(8, 8),
               existing=(5, 6), cand=(2, 3)),
    "C1": dict(rate=1.25, words=(431, 520), avg=(12.0, 99.0), chunks=(8, 8),
               existing=(5, 6), cand=(2, 3)),
}


def build(aid, title, scene, scene_label, summary, updated, level, sents):
    rub = LEVELS[level]
    out_sents = []
    existing = set()
    cand = set()
    for idx, (text, cn, cs) in enumerate(sents, 1):
        anns = []
        for c in cs:
            if c[0] == "e":
                d = chunks[c[1]]
                assert d["text"].lower() in text.lower(), (aid, c[1], d["text"], text)
                anns.append({"id": c[1], "text": d["text"], "meaningCN": d.get("meaningCN", "")})
                existing.add(c[1])
            else:
                assert c[1].lower() in text.lower(), (aid, c[1], text)
                slug = re.sub(r"[^a-z0-9]+", "_", c[1].lower()).strip("_")
                cid = f"lx_{scene}_{slug}"
                anns.append({"id": cid, "text": c[1], "meaningCN": c[2],
                             "candidate": True, "type": "content"})
                cand.add(cid)
        out_sents.append({"id": f"{aid}s{idx}", "text": text, "meaningCN": cn, "chunks": anns})
    total = len(existing) + len(cand)
    words = sum(len(s["text"].split()) for s in out_sents)
    avg = words / max(len(out_sents), 1)
    lo, hi = rub["words"]
    assert lo <= words <= hi, (aid, level, "words", words)
    lo, hi = rub["avg"]
    assert lo <= avg <= hi, (aid, level, "avg", round(avg, 2))
    lo, hi = rub["chunks"]
    assert lo <= total <= hi, (aid, level, "chunks", total)
    elo, ehi = rub["existing"]
    assert elo <= len(existing) <= ehi, (aid, level, "existing", len(existing))
    clo, chi = rub["cand"]
    assert clo <= len(cand) <= chi, (aid, level, "candidate", len(cand))
    assert total <= 8, (aid, total)  # 收词上限红线：任何级别都不超过 8 块
    if "reuse_min" in rub:
        assert len(existing) / total >= rub["reuse_min"], (aid, level, len(existing), total)
    return {
        "id": aid,
        "title": title,
        "scene": scene,
        "sceneLabel": scene_label,
        "summaryCN": summary,
        "updatedAt": updated,
        "level": level,
        "baseRate": rub["rate"],
        "collectLimit": 8,
        "audioUrl": "",
        "sentences": out_sents,
    }, existing, cand

articles = []
stats = []

a, e, c = build(
    "L01", "A Morning Coffee Run", "food", "点餐",
    "一个忙碌清晨的咖啡外带小故事，练点单、尺寸和口味。", "2026-10-23", "B1",
    [
        S("Good morning, everyone.", "大家早上好。"),
        S("I am in a hurry, so I just want a coffee to go.", "我赶时间，所以只想要一杯咖啡带走。", E("c01"), E("c04")),
        S("The cafe is next to the station, and it is already busy.", "咖啡店在车站旁边，已经忙起来了。"),
        S("I feel hungry, so I order a muffin as well.", "我觉得饿了，所以又点了一个松饼。", E("e04")),
        S("The barista smiles and asks what size I want.", "咖啡师笑着问我要什么尺寸。", E("c11")),
        S("I ask for a medium with milk, but no sugar.", "我要中杯、加奶、不加糖。", E("c12"), E("c02")),
        S("She asks if I want oat milk today.", "她问我今天要不要燕麦奶。", N("oat milk", "燕麦奶")),
        S("I say yes, and I ask for an extra shot.", "我说好，还要一份额外的浓缩。", N("an extra shot", "一份额外的浓缩")),
        S("\"That will be five dollars,\" she says.", "她说：“一共五美元。”"),
        S("I pay by card and wait near the counter.", "我刷卡付款，在柜台旁等候。"),
        S("The machine is loud, and the room smells wonderful.", "机器很响，屋里香气扑鼻。"),
        S("A man beside me is reading a newspaper.", "我旁边的男人在看报纸。"),
        S("A student is typing quickly on her laptop.", "一个学生在笔记本电脑上飞快打字。"),
        S("Everyone seems calm except me.", "除了我，大家似乎都很从容。"),
        S("I check my phone and see that I am late.", "我看了一眼手机，发现已经迟了。"),
        S("The barista calls my name and hands me the cup.", "咖啡师叫我的名字，把杯子递给我。"),
        S("The cup is warm in my hand.", "杯子在我手里暖暖的。"),
        S("I walk out and turn left at the corner.", "我走出去，在街角左转。"),
        S("The street is full of people and bicycles.", "街上满是行人和自行车。"),
        S("I take a sip and the coffee tastes strong and sweet.", "我喝了一口，咖啡又浓又甜。"),
        S("It is a small pleasure on a busy day.", "这是忙碌日子里的一点小确幸。"),
        S("I will come back tomorrow morning.", "明天早上我还会再来。"),
        S("Maybe I will try a latte next time.", "也许下次我会试试拿铁。"),
        S("The cafe also sells fresh bread and cakes.", "这家店还卖新鲜面包和蛋糕。"),
        S("The line is long, but the staff are fast.", "队伍很长，但店员动作很快。"),
        S("They know many customers by name.", "他们能叫出许多顾客的名字。"),
        S("An old woman is talking to the owner.", "一位老妇人正在和店主聊天。"),
        S("They laugh about the rainy weather.", "他们笑着聊起下雨的天气。"),
        S("I finish my coffee near the park.", "我在公园附近喝完咖啡。"),
        S("The sky is still gray, but I feel awake.", "天空仍然灰蒙蒙的，但我清醒了。"),
        S("I throw the cup into the bin.", "我把杯子扔进垃圾桶。"),
        S("Then I walk to the office with a clear head.", "然后我头脑清醒地走向办公室。"),
        S("Outside, a bus stops with a soft hiss.", "外面，一辆公交车伴着轻轻的嘶声停下。"),
        S("I step onto it and find a seat by the window.", "我上了车，在窗边找了个座位。"),
        S("The city passes quickly, and my mind is quiet.", "城市飞快掠过，我的心很安静。"),
        S("I take the last sip near the station door.", "我在车站门口喝完最后一口。"),
        S("The bus is already waiting at the stop.", "公交车已经在站台等着了。"),
        S("I find a seat and open my notebook.", "我找了个座位，打开笔记本。"),
        S("A new day has begun.", "新的一天开始了。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L02", "Dinner for Two", "food", "点餐",
    "两人晚餐：订位、前菜、主菜、账单与分摊。", "2026-10-21", "B1",
    [
        S("On Friday night, I want to book a table for two.", "周五晚上，我想订一张两人桌。", E("d02")),
        S("The restaurant is small, warm, and close to the river.", "餐厅不大，很温暖，离河很近。"),
        S("We arrive at seven and the waiter greets us at the door.", "我们七点到，服务员在门口迎接。", E("d03")),
        S("He takes our coats and shows us to a quiet table.", "他接过我们的外套，把我们带到一张安静的桌子。"),
        S("The menu has many dishes, and everything sounds good.", "菜单上菜很多，每道听起来都不错。"),
        S("We order still water while we read.", "我们边看边点了still water。", N("still water", "不含气的矿泉水")),
        S("My friend asks for a vegetarian option.", "朋友问有没有素食选项。", N("a vegetarian option", "素食选项")),
        S("The waiter says the soup is vegetarian today.", "服务员说今天的汤是素的。"),
        S("We share a starter with bread and tomatoes.", "我们分了一份配面包和番茄的前菜。", E("d04")),
        S("The starter is simple but very fresh.", "前菜简单，但非常新鲜。"),
        S("For the main course, I choose fish with rice.", "主菜我选了鱼配米饭。", E("d05")),
        S("My friend orders pasta with mushrooms.", "朋友点了蘑菇意面。"),
        S("The food arrives after fifteen minutes.", "食物十五分钟后到了。"),
        S("The fish is soft, and the sauce is light.", "鱼肉很嫩，酱汁清淡。"),
        S("We talk about work, travel, and old friends.", "我们聊工作、旅行和老朋友。"),
        S("The waiter fills our glasses and smiles.", "服务员给我们倒满水，笑了笑。"),
        S("For dessert, we share a small chocolate cake.", "甜点我们分了一块小巧克力蛋糕。"),
        S("The cake is sweet, but not too heavy.", "蛋糕很甜，但不腻。"),
        S("We drink tea and watch the lights on the river.", "我们喝茶，看河上的灯光。"),
        S("The restaurant becomes quieter after nine.", "九点后餐厅安静下来。"),
        S("We ask for the bill and the waiter brings it quickly.", "我们叫结账，服务员很快拿来账单。", E("b06")),
        S("We decide to split the bill.", "我们决定分摊账单。", N("split the bill", "分摊账单")),
        S("I pay my part by card, and my friend pays cash.", "我刷卡付自己那份，朋友付现金。"),
        S("We leave a small tip on the table.", "我们在桌上留了一点小费。"),
        S("The waiter thanks us and opens the door.", "服务员道谢并为我们开门。"),
        S("Outside, the night air is cool and clean.", "外面，夜晚的空气清凉干净。"),
        S("We walk along the river for a while.", "我们沿着河走了一会儿。"),
        S("It is a good end to a long week.", "这是一周辛苦工作的好结尾。"),
        S("The river is dark, and the city lights move on the water.", "河水很深，城市灯光在水面晃动。"),
        S("We talk about coming back next month.", "我们聊到下个月再来。"),
        S("My friend says she knows a good place for dessert.", "朋友说她知道一家不错的甜点店。"),
        S("I laugh and say we already had cake.", "我笑着说我们已经吃过蛋糕了。"),
        S("It is late, so we call a taxi.", "时间不早了，我们叫了出租车。"),
        S("We say goodbye and promise to meet again.", "我们道别，约好再见面。"),
        S("The taxi is warm, and the driver plays soft music.", "出租车里很暖，司机放着轻柔的音乐。"),
        S("I look at the river one last time.", "我最后看了一眼河。"),
        S("It was a simple dinner, but I will remember it.", "这顿晚餐很简单，但我会记住它。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L03", "Takeaway on a Busy Night", "food", "点餐",
    "忙碌夜晚的外带订单：点餐、总价、现金与退单。", "2026-10-19", "B1",
    [
        S("It is late, and I am too tired to cook.", "已经很晚了，我累得不想做饭。"),
        S("I decide to order food from a small shop near my home.", "我决定从家附近的小店点餐。", E("e12")),
        S("The shop is busy, so I use the app instead of calling.", "店里很忙，所以我用应用下单，没有打电话。"),
        S("I want a hot soup, a sandwich, and a drink.", "我想要热汤、三明治和饮料。"),
        S("The app asks if I want to get takeaway or eat in.", "应用问我是外带还是堂食。", E("e14")),
        S("I choose takeaway because I want to go home.", "我选外带，因为我想回家。"),
        S("I add extra napkins to the order.", "我在订单里加了额外的餐巾纸。", N("extra napkins", "额外的餐巾纸")),
        S("I also ask for no ice in my drink.", "我还要求饮料不加冰。", N("no ice", "不加冰")),
        S("The total is twenty dollars.", "总价是二十美元。", E("g05")),
        S("I notice the shop takes cash only.", "我注意到这家店只收现金。", E("f11")),
        S("I check my wallet and find enough cash.", "我检查钱包，发现现金够用。"),
        S("I walk to the shop in the light rain.", "我冒着小雨走向店里。"),
        S("The street is quiet, and most shops are closed.", "街上很安静，大多数店都关门了。"),
        S("A delivery rider passes me on a bike.", "一个外卖骑手骑车从我身边经过。"),
        S("At the shop, a young man is packing bags.", "店里，一个年轻人在打包。"),
        S("He tells me my food will be ready soon.", "他告诉我食物很快就好。"),
        S("I wait by the window and watch the rain.", "我在窗边等，看着雨。"),
        S("The man calls my number and gives me the bag.", "他叫我的号，把袋子递给我。"),
        S("I ask for a refund for the drink because it is wrong.", "饮料做错了，我要求退款。", N("a refund", "退款")),
        S("He checks the order and gives me the money.", "他核对了订单，把钱退给我。"),
        S("He also gives me a snack for free.", "他还免费送了我一份小吃。", E("e03")),
        S("I take a bite while I wait for the bus.", "等公交时我咬了一口。"),
        S("The soup is hot, and the sandwich is fresh.", "汤很热，三明治很新鲜。"),
        S("I feel full and happy on the way home.", "回家路上我吃得饱饱的，很开心。"),
        S("At home, I put the food on the table.", "到家后，我把食物放在桌上。"),
        S("I eat slowly and listen to music.", "我慢慢吃，听着音乐。"),
        S("Next time, I will check the order before I leave.", "下次离开前我会先检查订单。"),
        S("It is a small mistake, but the shop fixes it well.", "这是个小失误，但店里处理得很好。"),
        S("I put the empty boxes in the bin.", "我把空盒子扔进垃圾桶。"),
        S("Then I wash my hands and make some tea.", "然后洗手泡了杯茶。"),
        S("The rain is still falling outside.", "外面雨还在下。"),
        S("I open a book but fall asleep on the sofa.", "我打开书，却在沙发上睡着了。"),
        S("It was a busy night, but everything worked out.", "这是个忙碌的夜晚，但一切都解决了。"),
        S("I turn off the lamp and go to bed.", "我关灯上床。"),
        S("The rain stops before midnight.", "雨在午夜前停了。"),
        S("Tomorrow I will cook something simple.", "明天我要做点简单的饭菜。"),
        S("For now, I just want to sleep.", "现在，我只想睡觉。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L04", "Checking In at the Airport", "airport", "机场",
    "机场值机：托运行李、登机牌、座位与登机口。", "2026-10-22", "B1",
    [
        S("My flight leaves at nine, so I arrive at the airport at seven.", "航班九点起飞，所以我七点就到了机场。", E("i04")),
        S("The airport is busy, but the signs are clear.", "机场很忙，但指示牌很清楚。"),
        S("I need to check in for my flight to London.", "我需要办理去伦敦的航班值机。", E("t01")),
        S("I walk to the counter and show my passport.", "我走到柜台，出示护照。"),
        S("The woman asks if I want a window seat.", "工作人员问我要不要靠窗座位。", N("window seat", "靠窗座位")),
        S("I say yes, and she prints my boarding pass.", "我说要，她打印了我的登机牌。", N("boarding pass", "登机牌")),
        S("My friend prefers an aisle seat.", "朋友更喜欢靠过道的座位。", N("an aisle seat", "靠过道的座位")),
        S("She books it for him without any trouble.", "她顺利地为朋友订好了。"),
        S("The woman tells me the gate number.", "她告诉我登机口号码。"),
        S("I ask where is the security check.", "我问安检在哪里。", E("h01")),
        S("She says go straight and turn right at the coffee shop.", "她说一直走，在咖啡店右转。", E("h02")),
        S("I follow her direction and join the line.", "我按她说的走，加入了队伍。"),
        S("The line moves faster than I expect.", "队伍比我想象的快。"),
        S("I put my bag on the belt and walk through.", "我把包放上传送带，走了过去。"),
        S("My flight is on time today.", "我的航班今天准点。", E("j13")),
        S("I find a seat near the gate and check my email.", "我在登机口附近找了个座位，查看邮件。"),
        S("A family with two children sits beside me.", "一家带着两个孩子的人坐在我旁边。"),
        S("The children are excited about the trip.", "孩子们对旅行很兴奋。"),
        S("I buy a bottle of water and a small snack.", "我买了一瓶水和一份小零食。"),
        S("I hear an announcement about boarding.", "我听到登机广播。"),
        S("I look at my boarding pass again.", "我又看了一眼登机牌。"),
        S("The gate is close, so I walk slowly.", "登机口很近，所以我慢慢走。"),
        S("I call my friend and tell him I am ready.", "我给朋友打电话，说我准备好了。"),
        S("He says he is near the gate already.", "他说他已经到登机口附近了。"),
        S("We meet at the window and watch the planes.", "我们在窗边碰面，看着飞机。"),
        S("The sky is bright, and the runway is long.", "天空明亮，跑道很长。"),
        S("We board the plane at half past eight.", "我们八点半登机。"),
        S("It is the start of a short holiday.", "一段短假开始了。"),
        S("The plane pushes back from the gate.", "飞机从登机口推出。"),
        S("The crew shows us how to use the life jacket.", "机组人员演示救生衣的用法。"),
        S("I put my bag under the seat.", "我把包放在座位下面。"),
        S("The engine is loud, and the plane begins to move.", "引擎很响，飞机开始移动。"),
        S("I look out of the window as the city gets smaller.", "我看着窗外，城市越来越小。"),
        S("Soon we are above the clouds.", "很快我们就到了云层之上。"),
        S("I close my eyes and listen to the engines.", "我闭上眼睛，听着引擎声。"),
        S("In two hours, I will be in a new city.", "两小时后，我就会到一座新城市。"),
        S("I smile and think about the holiday.", "我微笑着，想着假期。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L05", "Through Security to the Gate", "airport", "机场",
    "安检到登机口：方向、时间、登机牌与登机组。", "2026-10-20", "B1",
    [
        S("I arrive at the airport with my small bag.", "我带着小包到达机场。", E("i04")),
        S("The security check is at the end of the hall.", "安检在大厅尽头。", N("security check", "安检")),
        S("A staff member tells me to go straight.", "一位工作人员让我一直走。", E("h02")),
        S("Then I should turn left after the shops.", "然后过了商店后左转。", E("h03")),
        S("I ask what time boarding starts.", "我问几点开始登机。", E("j01")),
        S("He says it starts at ten fifteen.", "他说十点十五开始。"),
        S("I don't understand the gate number.", "我没听懂登机口号码。", E("r01"), N("gate number", "登机口号码")),
        S("He repeats it slowly and points at the screen.", "他慢慢重复，并指着屏幕。"),
        S("I thank him and walk to the line.", "我道谢后走向队伍。"),
        S("The line is long, but it moves quickly.", "队伍很长，但移动得很快。"),
        S("I take out my laptop and my liquids.", "我拿出笔记本电脑和液体。"),
        S("A woman checks my boarding pass.", "一位女士检查我的登机牌。"),
        S("She asks me to step through the scanner.", "她让我走过扫描仪。"),
        S("My bag is clear, and I pick it up.", "我的包没问题，我把它拿起来。"),
        S("I look for a boarding group on the screen.", "我在屏幕上寻找登机组。", N("a boarding group", "登机组")),
        S("The screen shows that my flight is boarding.", "屏幕显示我的航班正在登机。"),
        S("I walk to the gate and find a free seat.", "我走到登机口，找了个空位。"),
        S("A man is charging his phone near the window.", "一个男人在窗边给手机充电。"),
        S("A child is sleeping on her mother's lap.", "一个孩子睡在妈妈腿上。"),
        S("I buy a coffee and sit down.", "我买了杯咖啡坐下。"),
        S("I check my passport and my ticket.", "我检查护照和机票。"),
        S("The gate agent calls my group.", "登机口工作人员叫到我的组。"),
        S("I stand up and join the line.", "我起身加入队伍。"),
        S("The plane is ready, and the crew is smiling.", "飞机准备好了，机组人员在微笑。"),
        S("I send a message to my family.", "我给家人发了条消息。"),
        S("They wish me a safe flight.", "他们祝我一路平安。"),
        S("I walk through the door and onto the plane.", "我穿过门，走上飞机。"),
        S("The seat is small, but the window is clear.", "座位很小，但窗户很明亮。"),
        S("The agent scans my boarding pass.", "工作人员扫描我的登机牌。"),
        S("I walk down the bridge and into the plane.", "我走过廊桥，进入机舱。"),
        S("A flight attendant greets me with a smile.", "一位空乘微笑着迎接我。"),
        S("I find my seat and put my bag above.", "我找到座位，把包放上去。"),
        S("The passenger beside me is reading a map.", "旁边的乘客在看地图。"),
        S("I fasten my seat belt and wait.", "我系好安全带，等待起飞。"),
        S("The plane is full, and the crew is busy.", "飞机坐满了，机组人员很忙。"),
        S("I put on my headphones and choose some music.", "我戴上耳机，选了些音乐。"),
        S("The engines start, and the plane moves slowly.", "引擎启动，飞机缓缓移动。"),
        S("I am ready for the flight.", "我准备好起飞了。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L06", "A Delayed Flight", "airport", "机场",
    "航班延误后的转机、行李与出租车，练求助与时间表达。", "2026-10-18", "B1",
    [
        S("I land at the airport and check my connecting flight.", "我降落机场，查看转机航班。", N("connecting flight", "转机航班")),
        S("The weather is bad, and it is rainy outside.", "天气不好，外面在下雨。", E("k02")),
        S("I have an umbrella, but my bag is heavy.", "我带了伞，但包很重。", E("k13")),
        S("The screen says my next flight is delayed.", "屏幕显示我的下一班航班延误了。"),
        S("I ask a staff member what I should do right now.", "我问工作人员现在该怎么办。", E("j02")),
        S("She says the flight will leave a bit later.", "她说航班会晚一点起飞。", E("j03")),
        S("I need to find baggage claim first.", "我得先去找行李提取处。", N("baggage claim", "行李提取处")),
        S("The signs are hard to read in the crowd.", "人群里很难看清指示牌。"),
        S("I follow the other passengers down the stairs.", "我跟着其他乘客下楼。"),
        S("A train takes us to the main building.", "一列小火车把我们带到主楼。"),
        S("The station is warm and full of noise.", "车站很暖和，充满了嘈杂声。", E("i03")),
        S("I wait near the baggage belt for twenty minutes.", "我在行李传送带旁等了二十分钟。"),
        S("My suitcase finally appears on the belt.", "我的行李箱终于出现在传送带上。"),
        S("I take a taxi stand outside the door.", "我在门外找到了出租车候车点。", N("a taxi stand", "出租车候车点")),
        S("The line for taxis is very long.", "等出租车的人排得很长。"),
        S("A driver offers to take me to the city.", "一位司机主动载我去市区。"),
        S("I ask him if he can drive faster.", "我问他能不能开快一点。"),
        S("He laughs and says the traffic is terrible.", "他笑着说交通太糟了。"),
        S("We drive through the rain and the lights.", "我们穿过雨幕和灯光。"),
        S("I call my hotel and say I will arrive late.", "我给酒店打电话，说我会晚到。"),
        S("The hotel clerk says my room is ready.", "酒店前台说房间已经准备好了。"),
        S("I feel tired but relieved.", "我累了，但松了口气。"),
        S("The taxi stops in front of the hotel.", "出租车停在酒店门口。"),
        S("I pay the driver and give him a tip.", "我付了车费，还给了小费。"),
        S("The rain is still falling, but I am dry.", "雨还在下，但我是干的。"),
        S("I check in and go straight to my room.", "我办了入住，直接回房间。"),
        S("Tomorrow I will take the early train.", "明天我要坐早班火车。"),
        S("For now, I just want to sleep.", "现在，我只想睡觉。"),
        S("I open the window and listen to the rain.", "我打开窗，听雨声。"),
        S("The room is small, but the bed is soft.", "房间不大，但床很软。"),
        S("I put my wet coat on a chair.", "我把湿外套放在椅子上。"),
        S("I set an alarm for six.", "我把闹钟定在六点。"),
        S("Then I turn off the light.", "然后关了灯。"),
        S("Tomorrow will be a better day.", "明天会更好。"),
        S("I hear the rain on the window and feel calm.", "我听着窗上的雨声，感到平静。"),
        S("The hotel is quiet, and the city is far away.", "酒店很安静，城市仿佛很远。"),
        S("I close my eyes and let the day go.", "我闭上眼，把这一天放下。"),
        S("Tomorrow I will start again with a clear plan.", "明天我会带着清晰的计划重新开始。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L07", "First Day at the Office", "work", "职场",
    "入职第一天：自我介绍、工牌、会议室与茶歇。", "2026-10-23", "B1",
    [
        S("Today is my first day at the office.", "今天是我到办公室的第一天。"),
        S("I get up early and go to work by bus.", "我早起坐公交去上班。", E("s13")),
        S("The building is tall, and the lobby is bright.", "大楼很高，大堂很明亮。"),
        S("A woman at the desk gives me a badge.", "前台女士给了我一张工牌。", N("a badge", "工牌")),
        S("She says my name is on the list.", "她说名单上有我的名字。", E("a05")),
        S("I meet my manager near the elevator.", "我在电梯旁见到了经理。"),
        S("He says nice to meet you and shakes my hand.", "他说很高兴认识我，和我握手。", E("a07")),
        S("He shows me the meeting room.", "他带我看会议室。", N("the meeting room", "会议室")),
        S("The room has a long table and a large screen.", "房间里有一张长桌和一块大屏幕。"),
        S("My desk is near the window.", "我的工位在窗边。"),
        S("Could you help me please with the computer?", "你能帮我弄一下电脑吗？", E("o03")),
        S("I don't understand the password system.", "我不懂这个密码系统。", E("r01")),
        S("She explains it again and writes it down.", "她又解释了一遍，并写下来。"),
        S("At ten, we take a coffee break.", "十点，我们去茶歇。", N("a coffee break", "茶歇")),
        S("The coffee is strong, and the biscuits are good.", "咖啡很浓，饼干很好吃。"),
        S("Everyone asks me where I am from.", "大家问我是哪里人。"),
        S("I tell them about my city and my family.", "我跟他们讲我的城市和家庭。"),
        S("They ask me about my old job.", "他们问我以前的工作。"),
        S("I say I like the team already.", "我说我已经喜欢上这个团队了。"),
        S("At noon, we eat lunch together.", "中午我们一起吃午饭。"),
        S("The food is simple, but the conversation is warm.", "饭菜简单，但聊天很温暖。"),
        S("In the afternoon, I read some documents.", "下午我读了一些文件。"),
        S("I ask a lot of questions.", "我问了很多问题。"),
        S("My manager says it is normal on the first day.", "经理说第一天这样很正常。"),
        S("I leave the office at six.", "我六点离开办公室。"),
        S("The city lights are bright on the way home.", "回家路上城市灯火明亮。"),
        S("I feel tired but happy.", "我累但开心。"),
        S("Tomorrow I will know more names.", "明天我会记住更多名字。"),
        S("At home, I write down the names I learned.", "回家后，我写下学到的名字。"),
        S("I make a small list for tomorrow.", "我为明天列了个小清单。"),
        S("My family asks me about the day.", "家人问我今天怎么样。"),
        S("I tell them the office is friendly.", "我告诉他们办公室的人很友好。"),
        S("I go to bed early.", "我很早就睡了。"),
        S("I feel ready for the next morning.", "我觉得已经准备好迎接第二天早晨。"),
        S("I set my alarm and put my badge on the desk.", "我定好闹钟，把工牌放在桌上。"),
        S("The first day was hard, but the people were kind.", "第一天很难，但大家都很友善。"),
        S("I know the building a little better now.", "我现在对大楼熟悉了一点。"),
        S("I look forward to my first real project.", "我期待我的第一个正式项目。"),
        S("I think I will like working here.", "我想我会喜欢在这里工作。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L08", "A Busy Monday Meeting", "work", "职场",
    "周一例会：议程、分歧、跟进邮件与收尾。", "2026-10-17", "B1",
    [
        S("It is Monday morning, and the office is full of noise.", "周一早上，办公室很热闹。"),
        S("We have a team meeting on Monday at nine.", "我们周一九点开团队会。", E("j08")),
        S("The manager puts the agenda on the screen.", "经理把议程放在屏幕上。", N("the agenda", "议程")),
        S("The first item is the new project plan.", "第一项是新项目计划。"),
        S("I think the plan is too ambitious.", "我觉得这个计划太激进了。", E("m01")),
        S("I agree with the goal, but not the timeline.", "我同意目标，但不同意时间表。", E("m03")),
        S("Another colleague says I disagree with the cost.", "另一位同事说他不同意成本。", E("m04")),
        S("We discuss the budget for twenty minutes.", "我们讨论了二十分钟预算。"),
        S("I was wondering if we could start smaller.", "我在想我们能不能从小规模开始。", E("o12")),
        S("The manager writes my idea on the board.", "经理把我的想法写在白板上。"),
        S("She says that is a good idea.", "她说这是个好主意。", E("p12")),
        S("We decide to test the plan with one team first.", "我们决定先在一个团队试点。"),
        S("After the meeting, I need to follow up by email.", "会后，我需要发邮件跟进。", N("follow up", "跟进")),
        S("I write a short summary and send it to everyone.", "我写了一份简短总结，发给所有人。"),
        S("A colleague calls me to check the numbers.", "一位同事打电话来核对数字。"),
        S("We find a mistake in the third row.", "我们发现第三行有个错误。"),
        S("I correct it and send the file again.", "我改正后重新发送文件。"),
        S("At noon, I take a quick break.", "中午我短暂休息了一下。"),
        S("The afternoon is quieter than the morning.", "下午比上午安静。"),
        S("I finish two reports and answer many messages.", "我完成两份报告，回复了很多消息。"),
        S("At five, I review my notes from the meeting.", "五点，我回顾会议笔记。"),
        S("The plan is clearer now.", "计划现在更清楚了。"),
        S("I make a list for Tuesday.", "我为周二列了清单。"),
        S("I leave the office after six.", "我六点后离开办公室。"),
        S("The bus is crowded, but I find a seat.", "公交很挤，但我找到了座位。"),
        S("I listen to music and watch the city.", "我听音乐，看着城市。"),
        S("It was a long day, but we made progress.", "今天很长，但我们有进展。"),
        S("Tomorrow we will follow up with the client.", "明天我们会跟进客户。"),
        S("I buy a sandwich and eat it in the park.", "我买了个三明治，在公园吃。"),
        S("The sun comes out for a few minutes.", "太阳出来了几分钟。"),
        S("I check my messages before I go back.", "回去前我查看了消息。"),
        S("The afternoon passes quickly.", "下午过得很快。"),
        S("At six, I pack my bag and leave.", "六点，我收拾包离开。"),
        S("I will sleep well tonight.", "今晚我会睡得很好。"),
        S("The meeting was long, but the result was clear.", "会议很长，但结果很清楚。"),
        S("I am glad we tested the plan first.", "我很高兴我们先做了试点。"),
        S("Next week, we will check the numbers again.", "下周我们会再核对数字。"),
        S("I close my laptop and say good night to the team.", "我合上电脑，和团队道晚安。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L09", "Making an Appointment", "hospital", "医院",
    "医院预约与就诊：时间、保险卡、候诊室和用药叮嘱。", "2026-10-21", "B1",
    [
        S("I feel sick, so I call a hospital near my home.", "我不舒服，所以打电话给家附近的医院。", E("i05")),
        S("I need an appointment with a doctor.", "我需要预约看医生。", N("an appointment", "预约")),
        S("The woman on the phone asks what time I can come.", "电话里的女士问我几点能来。", E("j01")),
        S("Could you repeat the address, please?", "你能重复一下地址吗？", E("o01")),
        S("Please speak slowly and give me the street name.", "请说慢一点，告诉我街道名。", E("r03")),
        S("I write it down and thank her.", "我记下来并道谢。"),
        S("She asks for the insurance card at the desk.", "她在前台要保险卡。", N("the insurance card", "保险卡")),
        S("I read the number from my card.", "我从卡上读出号码。"),
        S("She says the waiting room is on the second floor.", "她说候诊室在二楼。", N("the waiting room", "候诊室")),
        S("I arrive early and sit near the window.", "我提前到，坐在窗边。"),
        S("The waiting room is quiet and clean.", "候诊室安静又干净。"),
        S("A nurse calls my name and checks my temperature.", "护士叫我的名字，量了体温。"),
        S("Could you help me please with the form?", "你能帮我填一下表吗？", E("o03")),
        S("I fill in my name, age, and address.", "我填上姓名、年龄和地址。"),
        S("The doctor asks me how I feel.", "医生问我感觉怎么样。"),
        S("I tell her about my headache and my cough.", "我告诉她我头痛、咳嗽。"),
        S("She listens carefully and asks more questions.", "她仔细听，又问了一些问题。"),
        S("She says I need rest and some medicine.", "她说我需要休息和吃药。"),
        S("I ask if I can go to work tomorrow.", "我问明天能不能去上班。"),
        S("She says I should stay home for one day.", "她说我应该在家待一天。"),
        S("I thank her and leave the room.", "我道谢后离开诊室。"),
        S("At the front desk, I pay for the visit.", "我在前台付了诊费。"),
        S("The clerk gives me a receipt and a smile.", "工作人员递给我收据，笑了笑。"),
        S("Outside, the sun is warm.", "外面阳光很暖。"),
        S("I buy some fruit and go home.", "我买了些水果回家。"),
        S("I take my medicine and sleep for two hours.", "我吃了药，睡了两个小时。"),
        S("I feel better in the evening.", "晚上我感觉好多了。"),
        S("Next time, I will call earlier.", "下次我会早点打电话。"),
        S("The nurse gives me a glass of water.", "护士给了我一杯水。"),
        S("I sit in the waiting room and read a poster.", "我坐在候诊室看海报。"),
        S("It says that sleep is important for health.", "上面说睡眠对健康很重要。"),
        S("I agree and close my eyes for a moment.", "我同意，闭眼休息了一会儿。"),
        S("The doctor calls my name again.", "医生又叫了我的名字。"),
        S("I stand up and follow her.", "我起身跟着她走。"),
        S("She gives me a mask and asks me to wait.", "她给了我一个口罩，让我等一下。"),
        S("The room is bright, and the bed is clean.", "房间很明亮，床很干净。"),
        S("I feel a little nervous, but the doctor is kind.", "我有点紧张，但医生很和善。"),
        S("I know I will be fine after some rest.", "我知道休息一下就会好。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L10", "At the Pharmacy", "hospital", "医院",
    "药房取药：处方、副作用、服药说明与一次回访。", "2026-10-19", "B1",
    [
        S("The doctor gives me a prescription for my cough.", "医生给我开了止咳处方。", N("a prescription", "处方")),
        S("I walk to a pharmacy next to the hospital.", "我走向医院旁边的一家药房。", E("i06"), E("h06")),
        S("The pharmacist is a kind woman with glasses.", "药剂师是位戴眼镜的友善女士。"),
        S("I give her the prescription and wait.", "我把处方递给她，等着。"),
        S("She asks if I am allergic to anything.", "她问我有没有过敏史。"),
        S("I say no, but I am worried about the side effects.", "我说没有，但我担心副作用。", E("l09"), N("side effects", "副作用")),
        S("Could you explain how to take it?", "你能解释一下怎么服用吗？", E("o01")),
        S("She says I should take it with food.", "她说我应该随餐服用。", N("take it with food", "随餐服用")),
        S("I ask her to say that again.", "我请她再说一遍。", E("r02")),
        S("She repeats the instruction slowly.", "她慢慢重复了说明。"),
        S("I should take one pill in the morning and one at night.", "我应该在早晚各服一片。"),
        S("I should not drink alcohol with this medicine.", "服这种药不能喝酒。"),
        S("She also gives me some cough drops.", "她还给了我一些止咳含片。"),
        S("I ask if I can drive after taking it.", "我问服药后能不能开车。"),
        S("She says I may feel sleepy, so I should rest.", "她说我可能会犯困，应该休息。"),
        S("I pay for the medicine and put it in my bag.", "我付了药费，把药放进包里。"),
        S("On the way home, I buy a bottle of water.", "回家路上，我买了一瓶水。"),
        S("I read the label again at the kitchen table.", "我在餐桌旁又看了一遍标签。"),
        S("The instructions are clear and easy to follow.", "说明清楚易懂。"),
        S("I take the first pill with a small meal.", "我随少量食物服下第一片药。"),
        S("The medicine tastes bitter, but I swallow it.", "药很苦，但我咽了下去。"),
        S("I lie down and close my eyes.", "我躺下，闭上眼睛。"),
        S("In the afternoon, I feel a little better.", "下午我感觉好了一点。"),
        S("I drink tea and read a book.", "我喝茶看书。"),
        S("My friend calls to ask about my health.", "朋友打电话问我身体怎么样。"),
        S("I tell her the pharmacist was very helpful.", "我告诉她药剂师帮了很大忙。"),
        S("She says she will visit tomorrow.", "她说说明天来看我。"),
        S("I am grateful for the quiet day at home.", "我很感激在家度过的安静一天。"),
        S("I put the medicine in a safe place.", "我把药放在安全的地方。"),
        S("I write a note to take it at eight.", "我写了张便条，提醒八点吃药。"),
        S("My mother calls and asks if I need anything.", "妈妈打电话问我要不要什么。"),
        S("I say no thanks and tell her I am fine.", "我说不用了，谢谢，我很好。"),
        S("She says she will bring some soup.", "她说会带些汤来。"),
        S("I smile and wait for her.", "我笑了笑，等她来。"),
        S("The soup is warm and tastes like home.", "汤很暖，有家的味道。"),
        S("We talk for an hour and laugh a little.", "我们聊了一个小时，笑了几声。"),
        S("I take my medicine again before bed.", "睡前我又吃了一次药。"),
        S("The day was quiet, and I feel grateful.", "这一天很安静，我心怀感激。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

# ─────────────────────────────────────────────────────────────
# 指令 S §一.3：新增 6 篇（A1×3 / B1×2 / C1×1）
# ─────────────────────────────────────────────────────────────

a, e, c = build(
    "L11", "Hello, Neighbor", "greet", "打招呼",
    "新邻居在楼道里打招呼，练最日常的问候与自我介绍。", "2026-10-23", "A1",
    [
        S("Good morning, neighbor.", "早上好，邻居。", E("a01")),
        S("Good morning to you too.", "你也早上好。", E("a01")),
        S("I am Sam.", "我叫 Sam。"),
        S("My name is Sam.", "我的名字是 Sam。", E("a05")),
        S("Nice to meet you.", "很高兴认识你。", E("a07")),
        S("Nice to meet you too.", "我也很高兴认识你。", E("a07")),
        S("This is my son.", "这是我儿子。"),
        S("He is new here.", "他刚来这儿。"),
        S("Do you live here?", "你住这儿吗？"),
        S("Yes, we just moved in.", "是的，我们刚搬来。"),
        S("The building is quiet.", "这栋楼很安静。"),
        S("And the street is safe.", "街道也安全。"),
        S("Thank you for the help.", "谢谢你的帮忙。", E("a04")),
        S("Thank you so much.", "真的很感谢你。", E("a04")),
        S("No problem at all.", "完全没问题。"),
        S("Have a nice day.", "祝你今天愉快。", N("have a nice day", "祝你今天愉快")),
        S("You too, Sam.", "你也是，Sam。"),
        S("See you later.", "回头见。", E("a08")),
        S("See you tomorrow.", "明天见。", E("a08")),
        S("Have a good weekend.", "周末愉快。"),
        S("Thanks, neighbor.", "谢谢你，邻居。"),
        S("My son says hello.", "我儿子向你问好。"),
        S("Hello to him.", "替我问好。"),
        S("Is the coffee good?", "那里的咖啡好吗？"),
        S("The cafe is great.", "那家咖啡店很棒。"),
        S("I go there daily.", "我每天都去。"),
        S("Me too, every day.", "我也是，每天。"),
        S("Then we will meet.", "那我们会碰面。"),
        S("Good morning again.", "再次早上好。", E("a01")),
        S("Goodbye for now.", "先这样，再见。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L12", "Where Is the Station", "direction", "问路",
    "在街口问路去车站：直走、左转、右转、拐角。", "2026-10-23", "A1",
    [
        S("Excuse me, a question.", "打扰一下，问个问题。"),
        S("Where is the station?", "车站在哪里？", E("h01"), E("i03")),
        S("The station is near.", "车站就在附近。", E("i03")),
        S("Please go straight.", "请直走。", E("h02")),
        S("Go straight for two blocks.", "直走过两个街区。", E("h02")),
        S("Then turn left.", "然后左转。", E("h03")),
        S("Turn left at the light.", "在红绿灯处左转。", E("h03")),
        S("Now turn right.", "现在右转。", E("h04")),
        S("Turn right at the corner.", "在拐角处右转。", E("h04"), E("h05")),
        S("It is at the corner.", "它就在拐角。", E("h05")),
        S("You will see a big sign.", "你会看到一个大牌子。"),
        S("The station is behind it.", "车站就在后面。", E("i03")),
        S("Is it far from here?", "离这儿远吗？"),
        S("No, it is five minutes.", "不远，五分钟。"),
        S("Just walk, it is easy.", "走着去就行，很容易。"),
        S("Am I on the right road?", "我走的路对吗？"),
        S("Yes, go straight from here.", "对，从这里直走。", E("h02")),
        S("Do not turn left here.", "这儿不要左转。", E("h03")),
        S("Turn right after the shop.", "商店之后再右转。", E("h04")),
        S("Then you will see it.", "然后你就看到了。"),
        S("Thank you for the way.", "谢谢你指路。"),
        S("You are welcome, friend.", "不客气，朋友。"),
        S("Have a good trip.", "一路顺利。"),
        S("The station, right?", "是车站，对吧？", E("i03")),
        S("Yes, the station ahead.", "对，车站就在前面。", E("i03")),
        S("I see the blue sign.", "我看到蓝色的牌子了。"),
        S("That is the place.", "就是那儿。"),
        S("Great, I found it.", "太好了，找到了。"),
        S("Thank you again.", "再次感谢你。"),
        S("Goodbye, and walk safe.", "再见，路上小心。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L13", "At the Corner Shop", "shop", "便利店",
    "便利店买水和咖啡：要什么、怎么付、要不要袋子。", "2026-10-23", "A1",
    [
        S("The shop is open late.", "这家店开得晚。"),
        S("I come here often.", "我常来这儿。"),
        S("Hello, just two things.", "你好，就买两样。"),
        S("I'd like some water.", "我想要点水。", E("b01")),
        S("A bottle of water, please.", "请给我一瓶水。", E("b08")),
        S("And a coffee, hot.", "再来一杯热咖啡。", E("c01")),
        S("The coffee is fresh.", "咖啡很新鲜。"),
        S("Do you need a bag?", "你需要袋子吗？"),
        S("Yes, a small bag.", "要，一个小的。"),
        S("Here is your food.", "你的吃的在这儿。"),
        S("How much is it?", "多少钱？"),
        S("It is six dollars.", "六美元。"),
        S("Can I pay by card?", "我能刷卡吗？", E("g07")),
        S("Yes, pay by card here.", "可以，在这儿刷卡。", E("g07")),
        S("The machine is slow.", "机器有点慢。"),
        S("No hurry at all.", "一点不急。"),
        S("Do you want a receipt?", "你要小票吗？", E("f10")),
        S("Yes, a receipt please.", "要，请给我小票。", E("f10")),
        S("I use the self checkout.", "我用自助结账。", N("self checkout", "自助结账")),
        S("It is fast and easy.", "又快又简单。"),
        S("The line is long today.", "今天队伍很长。"),
        S("I wait near the door.", "我在门边等。"),
        S("The clerk is kind.", "店员很和善。"),
        S("She smiles and says thanks.", "她笑着说谢谢。"),
        S("Thank you, have a good night.", "谢谢，晚上愉快。"),
        S("You too, take care.", "你也是，慢走。"),
        S("I'd like a quiet walk home.", "我想安静地走回家。", E("b01")),
        S("The street is calm now.", "街上现在很安静。"),
        S("See you next time.", "下次再来。"),
        S("Have a nice evening.", "晚上愉快。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L14", "The Friday Wrap-Up", "work", "职场",
    "周五收尾：快速回顾、行动项、下周计划与准时交付。", "2026-10-23", "B1",
    [
        S("It is Friday afternoon, and the office is finally calm.", "周五下午，办公室终于安静下来。"),
        S("I think we all needed a slower hour.", "我觉得我们都需要慢一点的一个小时。", E("m01")),
        S("The meeting ran long, but we closed the last item.", "会开得很久，但我们把最后一项结了。"),
        S("Could you send the notes when you have time?", "你有空时能把会议纪要发一下吗？", E("o01")),
        S("Got it, I will write them tonight.", "收到，我今晚就写。", E("p05")),
        S("A quick recap keeps everyone on the same page.", "一次快速回顾能让所有人对齐。", N("a quick recap", "快速回顾")),
        S("I will list the action items in one column.", "我会把行动项列在一栏里。", N("action items", "行动项")),
        S("Each item gets one owner and one date.", "每项都有一个负责人和一个日期。"),
        S("Nobody should leave with an unclear task.", "不该有人带着模糊的任务离开。"),
        S("I prefer short lists over long emails.", "我更喜欢短清单而不是长邮件。"),
        S("Long emails hide the two things that matter.", "长邮件会埋掉真正重要的两件事。"),
        S("The deadline is Tuesday, not next Friday.", "截止日期是周二，不是下周五。"),
        S("Next week we start the second phase.", "下周我们启动第二阶段。", E("j05")),
        S("Next week also has a review with the client.", "下周还有一次和客户过的评审。", E("j05")),
        S("Could you prepare the slides before Thursday?", "你能在周四前把幻灯片准备好吗？", E("o01")),
        S("I can do that if I get the data today.", "如果今天拿到数据，我就能做。"),
        S("The data lives in a shared folder, I think.", "数据在共享文件夹里，我猜。", E("m01")),
        S("I will ask the team for access this afternoon.", "我今天下午会向团队要权限。"),
        S("Please keep the numbers simple and honest.", "请把数字弄得简单、诚实。"),
        S("Simple numbers make better decisions.", "简单的数字能带来更好的决策。"),
        S("We agreed to ship on time, not early and rough.", "我们同意按时交付，而不是提前交粗糙的东西。", E("j13")),
        S("Being on time builds trust with the client.", "准时能建立客户的信任。", E("j13")),
        S("I agree, and I will say so in the review.", "我同意，评审时我会这么说。"),
        S("If anything slips, tell me early.", "如果有延误，尽早告诉我。"),
        S("Early warnings are cheaper than late surprises.", "提前预警比事后惊吓便宜。"),
        S("Got it, I will flag risks on Monday.", "明白，我周一就把风险标出来。", E("p05")),
        S("Monday morning is a good time for that.", "周一上午正适合做这件事。"),
        S("We can move the smaller tasks to next week.", "我们可以把小事挪到下周。", E("j05")),
        S("The client only sees the finished part.", "客户只看到完成的部分。"),
        S("So let us protect the team's quiet time.", "所以让我们保住团队的安静时间。"),
        S("I was glad the meeting ended early today.", "很高兴今天的会提前结束了。"),
        S("We still have real work to do this week.", "这周我们还有真正的活儿。"),
        S("But the plan is clear, and that helps.", "不过计划清楚了，这就很有帮助。"),
        S("Let us call it a day and rest.", "今天就到这儿，去休息吧。", N("call it a day", "今天就到此为止")),
        S("Rest is part of the work, not a reward.", "休息是工作的一部分，不是奖赏。"),
        S("See you Monday, refreshed and ready.", "周一见，精神饱满地开始。"),
        S("Have a good weekend, everyone.", "祝大家周末愉快。"),
        S("Thank you all for a clean finish.", "谢谢大家把这一周收得干净。"),
        S("The office is dark, and the week is done.", "办公室熄了灯，这一周结束了。"),
        S("I lock the door and head home.", "我锁门回家。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L15", "Delayed Again at the Desk", "airport", "机场",
    "又一次延误：改签、登机口变更、酒店券与行李重新托运。", "2026-10-23", "B1",
    [
        S("The board says delayed, and the hall fills with sighs.", "屏幕上写着延误，大厅里满是叹气。"),
        S("It is rainy outside, so more flights are late.", "外面下着雨，所以更多航班晚点。", E("k02")),
        S("I walk to the desk and join the longest line.", "我走到柜台，排进最长的队伍。"),
        S("What time is the next available flight?", "下一个有位的航班是几点？", E("j01")),
        S("The agent checks her screen and says an hour.", "工作人员看了看屏幕，说一小时。"),
        S("An hour is fine, I have nowhere to be.", "一小时没关系，我哪儿也不赶。"),
        S("But then comes a gate change notice.", "但接着来了登机口变更的通知。", N("a gate change", "登机口变更")),
        S("Gate twelve is now gate twenty-six.", "十二号口改成了二十六号口。"),
        S("I need to rebook my flight, not just wait.", "我需要改签，而不只是等。", N("rebook my flight", "改签航班")),
        S("Could you put me on the morning flight?", "能把我改到早班机吗？", E("o01")),
        S("The agent types slowly and then nods.", "工作人员慢慢地打字，然后点头。"),
        S("Yes, that seat is still open today.", "可以，今天那个座位还空着。"),
        S("My bag is already checked in downstairs.", "我的行李已经在楼下托运了。"),
        S("Will it reach the airport before I do?", "它会比我先到机场吗？", E("i04")),
        S("The airport is large, and the transfer is tight.", "机场很大，转机很紧。", E("i04")),
        S("I ask for a hotel voucher for the night.", "我要一张当晚的酒店券。"),
        S("They give me a voucher and a breakfast card.", "他们给了我一张券和一份早餐卡。"),
        S("A bit later, the screen changes again.", "过了一会儿，屏幕又变了。", E("j03")),
        S("The new flight leaves at six sharp.", "新航班六点整起飞。"),
        S("I find a chair near the window and sit.", "我在窗边找了把椅子坐下。"),
        S("A man beside me works on a small laptop.", "我旁边的男人在小笔记本上工作。"),
        S("His child sleeps under a thin blanket.", "他的孩子在薄毯子下睡着。"),
        S("Nobody complains loudly, which feels kind.", "没有人大声抱怨，这让人觉得善意。"),
        S("We share the news like a small community.", "我们像个小集体一样分享消息。"),
        S("The coffee here costs more than the flight.", "这里的咖啡比机票还贵。"),
        S("Still, I buy one and wait without hurry.", "但我还是买了一杯，不着急地等。"),
        S("I was wondering if the gate will change again.", "我在想登机口会不会再变。"),
        S("It does not, and we board in one group.", "没有变，我们一组人登机。"),
        S("The plane is late, but it is ours now.", "飞机晚点了，但此刻是我们的了。"),
        S("I stow my bag and look out at the rain.", "我放好行李，看向外面的雨。"),
        S("Delay teaches patience at an awkward price.", "延误以别扭的代价教会人耐心。"),
        S("Next time I will build in a longer gap.", "下次我会留出更长的间隔。"),
        S("I will check in online the night before.", "我会在前一晚网上值机。", E("t01")),
        S("And I will keep this voucher as a story.", "我会把这张券留成一个故事。"),
        S("The engine hums, and the hall falls away.", "引擎轰鸣，大厅渐渐远去。"),
        S("Somewhere ahead, my morning is still waiting.", "在前方某处，我的早晨仍在等待。"),
        S("I close my eyes and let the night pass.", "我闭上眼睛，让夜里过去。"),
        S("By dawn, the delay feels almost small.", "到拂晓，延误几乎变得渺小。"),
        S("The pilot apologizes and thanks us kindly.", "机长道歉并客气地感谢我们。"),
        S("We land early, which nobody expected today.", "我们提前落地，谁也没料到。"),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

a, e, c = build(
    "L16", "Late Night Radio", "radio", "电台",
    "深夜电台独白：关于慢下来的节奏、凌晨与自我说服。", "2026-10-23", "C1",
    [
        S("It is past midnight, and the city has finally stopped explaining itself to me.", "已经过了午夜，城市终于不再向我解释它自己。"),
        S("I think that is the real gift of the small hours.", "我觉得这正是凌晨时段真正的礼物。", E("m01"), N("the small hours", "凌晨时分")),
        S("Nobody expects a reply before sunrise, and the silence is not rude.", "没人期待日出前有回复，而这种沉默并不失礼。"),
        S("I prefer the slower version of my own thinking.", "我更喜欢自己思考里更慢的那个版本。", E("m07")),
        S("In daylight, thought arrives already dressed for work.", "在白天，想法一到达就已经穿好上班的衣服。"),
        S("At night it comes in bare feet, unhurried and honest.", "夜里它光着脚来，不慌不忙，也很诚实。", E("j10")),
        S("To be honest, I have been running at a speed I never chose.", "说实话，我一直在用一个自己从未选过的速度奔跑。", E("m20")),
        S("The schedule was written by other hands, and I simply agreed.", "日程是别人的手写的，我只是同意了。"),
        S("Somewhere along the way, agreement started to look like ambition.", "在某个路口之后，同意开始看起来像野心。"),
        S("It is important to notice the difference before you are tired.", "在疲惫之前察觉这个差别，很重要。", E("m14")),
        S("A slower pace is not laziness wearing a nicer coat.", "更慢的节奏不是懒惰穿了件更好看的外套。", N("a slower pace", "更慢的节奏")),
        S("It is a decision about which things deserve your attention.", "它是关于哪些事值得你注意力的决定。"),
        S("I have learned to keep one hour empty, like a window.", "我学会留出一个空白小时，像一扇窗。"),
        S("Nothing is scheduled there, and everything is possible.", "那里没有安排，却一切皆有可能。"),
        S("Sometimes I sit with a cup of tea and do absolutely nothing, though the first attempts felt uncomfortable and almost rude.", "有时我端着一杯茶什么都不做，尽管最初的尝试让人不安，几乎算失礼。"),
        S("My hands reached for the phone out of pure habit, but I stayed anyway, and the discomfort passed like weather.", "我的手出于习惯去拿手机，但我还是留下来，那种不适像天气一样过去了。"),
        S("I think most people underestimate how fast boredom leaves.", "我觉得大多数人低估了无聊离开的速度。", E("m01")),
        S("What arrives afterwards is usually a small, useful idea that rarely shouts and tends to whisper and wait.", "之后到来的通常是一个小而有用的想法，它很少喊叫，而是低语并等待。"),
        S("To be honest, some of my best decisions were whispers.", "说实话，我一些最好的决定都是低语。", E("m20")),
        S("The loud ones belonged to other people's calendars.", "那些大声的属于别人的日历。"),
        S("I would rather be late to a meeting than early to a mistake.", "我宁愿开会迟到，也不愿过早犯错。"),
        S("That line sounds careless until you have tried it twice, and stay calm is the instruction I repeat most often now.", "这句话听起来草率，直到你试过两次；而保持平静是如今我重复最多的一句指令。", E("l08")),
        S("Not calm as in numb, but calm as in clear water where you can see the bottom and read the stones.", "不是麻木的平静，而是清水般的平静，你能看见水底，读懂石头。"),
        S("I keep a notebook by the bed for these late transmissions, though most entries are three words long and useless by morning.", "我在床边放一本笔记本记这些深夜播报，尽管多数条目只有三个词，到早上就没用了。"),
        S("But one in ten changes the entire following week, and that ratio is cheap enough to pay much more for.", "但十分之一会改变接下来的整个一周，这个比例便宜到值得付更多。"),
        S("The radio plays something old and nobody asks for a request, which is a pleasure in receiving what you did not choose.", "电台放着一首老歌，没人点歌，这种接受你没选的东西本身就是一种愉悦。"),
        S("I prefer this to the endless menu of my own device.", "我更喜欢这样，而不是我设备上的无尽菜单。", E("m07")),
        S("The host speaks softly, as if reading to an empty room.", "主播轻声说话，像在给空房间朗读。"),
        S("It is important, I think, to be addressed so gently.", "我觉得，被人如此温柔地对待很重要。", E("m14"), E("m01")),
        S("Gentleness is not a weakness that serious people outgrow.", "温柔不是严肃的人长大后会丢掉的弱点。"),
        S("It is a skill, and like most skills it needs quiet practice.", "它是一种技能，和多数技能一样需要安静地练习。"),
        S("By now the traffic has gone, and the street sounds wider.", "此刻车流散去，街道听起来更宽阔。"),
        S("I will sleep without a plan for tomorrow, which is rare.", "我会不带明日计划地睡去，这很难得。"),
        S("Tomorrow will ask its usual questions, and I will answer late.", "明天会照例提问，我会晚一点回答。"),
        S("For now, the small hours hold the door open for me, so good night from a city that has stopped explaining itself.", "此刻，凌晨为我扶着门，所以请接受这座不再解释自己的城市的晚安。", N("the small hours", "凌晨时分")),
    ],
)
articles.append(a); stats.append((a["id"], len(e), len(c)))

pack_out = {
    "version": 2,
    "generatedAt": "2026-10-23",
    "articles": articles,
}
out = ROOT / "assets/listening_articles.json"

by_id = {aid: (ne, nc) for aid, ne, nc in stats}
all_e = sum(x[1] for x in stats)
all_n = sum(x[2] for x in stats)
print("articles:", len(articles))
print("aggregate existing ratio", round(all_e / (all_e + all_n), 4))
print()
# 《评级依据表》——三轴实测值 + 复用率 + 折算时长，直接抄进内容分册
print("| 篇 | 标题 | 场景 | 级别 | 句数 | 词数 | 句均 | 块数 | 既有/候选 | 复用率 | baseRate | 折算时长 |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for a in articles:
    sents = len(a["sentences"])
    words = sum(len(s["text"].split()) for s in a["sentences"])
    avg = words / sents
    rate = a["baseRate"]
    ne, nc = by_id[a["id"]]
    # 估算口径：150 wpm + 句间 0.3s 停顿（与播放器实际合成参数一致），再按本级默认语速折算
    secs = (words / 150 * 60 + (sents - 1) * 0.3) / rate
    lo, hi = LEVELS[a["level"]]["words"]
    assert lo <= words <= hi, (a["id"], a["level"], words)
    assert 45 <= secs <= 210, (a["id"], round(secs, 1))
    print(f"| {a['id']} | {a['title']} | {a['sceneLabel']} | {a['level']} | {sents} | "
          f"{words} | {avg:.1f} | {ne + nc} | {ne}/{nc} | "
          f"{round(ne / (ne + nc) * 100)}% | {rate} | {int(secs // 60)}分{int(secs % 60)}秒 |")
out.write_text(json.dumps(pack_out, ensure_ascii=False, indent=1), encoding="utf-8")
print("written", out)
