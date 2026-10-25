#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/content_pack.json —— 20 场景 × 25 词块 = 500 条。
schema 严格沿用 ContentPack.fromJson。每词块录入：
  (id, text[2-5词], type, meaningCN[全库唯一], example[含text], swap_token, [opts])
自检：① 词块 2-5 词 100% ② 中文锚点唯一 100% ③ 英文地道性抽检 10%。
"""
import json
import os
import subprocess
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "content_pack.json"))

FUNCTION_WORDS = set("""
a an the i you he she it we they me us my your his her our their
to of in on at for with and or but so if is am are was were be been
do does did can could will would shall should may might must have has had
this that these those not no yes please thanks thank about from as by up down
out off get got let me what when where who why how there here very too also just
""".split())

def norm(t: str) -> str:
    return t.lower().strip(" .,!?;:()\"'")

def word_count(t: str) -> int:
    return len([w for w in t.strip().split() if w])

def build_sentence(chunk_text, ctype, example, swap_token, swap_options):
    raw_tokens = example.replace(",", " ,").replace(".", " .").split()
    slots = []
    chunk_tokens = [norm(w) for w in chunk_text.split()]
    for tok in raw_tokens:
        base = norm(tok)
        if base in chunk_tokens:
            ttype = ctype
        elif base in FUNCTION_WORDS:
            ttype = "function"
        else:
            ttype = "content"
        slots.append({"text": tok, "type": ttype})
    core = [t for t in chunk_tokens if t not in FUNCTION_WORDS] or chunk_tokens
    sidx = -1
    for i, s in enumerate(slots):
        if norm(s["text"]) == norm(swap_token):
            sidx = i
            break
    if sidx < 0:
        for i in range(len(slots) - 1, -1, -1):
            if norm(slots[i]["text"]) in chunk_tokens:
                sidx = i
                break
    if sidx < 0:
        sidx = 0
    return {"text": example, "slots": slots, "coreWords": core,
            "swapSlotIndex": sidx, "swapOptions": list(swap_options)}

LEVELS = [
("A", "Greetings", "scene_a.png", [
 ("a01","say hello","function","打招呼说你好","Say hello to the host.","host",["guest","friend","team"]),
 ("a02","hi there","function","嗨，你好","Hi there, how are you?","how",["what","who","where"]),
 ("a03","good morning","function","早上好","Good morning, everyone.","everyone",["teacher","friend","sir"]),
 ("a04","good afternoon","function","下午好","Good afternoon, welcome in.","welcome",["come","sit","stay"]),
 ("a05","good evening","function","晚上好","Good evening, how was your day?","day",["night","trip","week"]),
 ("a06","how are you","function","你最近好吗","How are you today?","today",["now","lately","tonight"]),
 ("a07","I'm fine","function","我挺好的","I'm fine, thank you.","fine",["good","great","okay"]),
 ("a08","nice to meet you","function","很高兴认识你","Nice to meet you, John.","John",["Mary","sir","boss"]),
 ("a09","long time no see","function","好久不见","Long time no see, friend.","friend",["buddy","pal","man"]),
 ("a10","see you later","function","回头见","See you later, take care.","care",["soon","tomorrow","then"]),
 ("a11","say goodbye","function","道别说再见","Say goodbye to your friend.","friend",["team","host","guest"]),
 ("a12","take care","function","保重","Take care of yourself.","yourself",["him","her","them"]),
 ("a13","you are welcome","function","欢迎你来","You are welcome here.","here",["always","home","aboard"]),
 ("a14","my name is","function","我的名字是","My name is Lisa.","Lisa",["Tom","Ann","Sam"]),
 ("a15","what's your name","function","你叫什么名字","What's your name, please?","please",["sir","miss","friend"]),
 ("a16","pleased to meet you","function","幸会（正式）","Pleased to meet you all.","all",["both","sir","ma'am"]),
 ("a17","how's it going","function","最近怎么样","How's it going these days?","days",["night","week","lately"]),
 ("a18","I am from","function","我来自（某地）","I am from China.","China",["Japan","Canada","Spain"]),
 ("a19","this is my friend","function","这是我的朋友","This is my friend, Kate.","Kate",["Bob","Leo","May"]),
 ("a20","glad to see you","function","很高兴见到你","Glad to see you again.","again",["here","today","now"]),
 ("a21","in the morning","timeplace","在早晨时分","I run in the morning.","run",["work","read","walk"]),
 ("a22","by tonight","timeplace","今晚之前","Finish it by tonight.","Finish",["Send","Call","Mail"]),
 ("a23","this weekend","timeplace","这个周末","See you this weekend.","See",["Call","Meet","Text"]),
 ("a24","later today","timeplace","今天晚些","Call me later today.","Call",["Text","Meet","Visit"]),
 ("a25","talk later","timeplace","稍后再聊","Let's talk later.","talk",["meet","eat","go"]),
]),
("B", "Asking for things", "scene_b.png", [
 ("b01","I'd like","function","我想要（礼貌）","I'd like the menu, please.","menu",["water","coffee","bill"]),
 ("b02","a glass of","content","一杯（饮品）","I'd like a glass of water.","water",["juice","milk","tea"]),
 ("b03","the menu","content","菜单","Can I see the menu?","see",["have","read","open"]),
 ("b04","some help","content","一些帮助","I need some help, thanks.","thanks",["please","sir","madam"]),
 ("b05","a table for two","content","两人桌","We want a table for two.","two",["four","three","six"]),
 ("b06","the bill","content","（餐）账单","Could we have the bill?","have",["see","get","pay"]),
 ("b07","a cup of coffee","content","一杯咖啡","I'll have a cup of coffee.","coffee",["tea","milk","water"]),
 ("b08","a bottle of","content","一瓶","Bring a bottle of wine.","wine",["water","beer","juice"]),
 ("b09","a piece of","content","一块／一片","I ate a piece of cake.","cake",["bread","meat","cheese"]),
 ("b10","a pair of","content","一双／一对","I bought a pair of shoes.","shoes",["socks","gloves","glasses"]),
 ("b11","could I have","function","能给我…吗（礼貌）","Could I have some water?","water",["bread","rice","soup"]),
 ("b12","do you have","function","你们有…吗","Do you have a map?","map",["pen","bag","ticket"]),
 ("b13","I need","function","我需要","I need a taxi, please.","taxi",["doctor","phone","key"]),
 ("b14","give me","function","给我","Give me the red one.","red",["big","small","blue"]),
 ("b15","pass me","function","递给我","Pass me the salt, please.","salt",["sugar","bread","fork"]),
 ("b16","bring me","function","拿给我","Bring me the check, thanks.","check",["menu","water","napkin"]),
 ("b17","I'm looking for","function","我在找","I'm looking for the bank.","bank",["hotel","station","shop"]),
 ("b18","where can I","function","我在哪能…","Where can I sit down?","sit",["pay","wash","charge"]),
 ("b19","can you","function","你能…吗","Can you help me?","help",["wait","show","call"]),
 ("b20","a little","content","一点点","Just a little, thanks.","thanks",["please","sir","madam"]),
 ("b21","a lot of","content","许多","We have a lot of time.","time",["food","work","fun"]),
 ("b22","some more","content","再多一些","I want some more, please.","please",["sir","miss","thanks"]),
 ("b23","a little less","content","稍微少点","Make it a little less.","Make",["Keep","Serve","Try"]),
 ("b24","another one","content","另一个（再一）","I'll take another one.","one",["cup","piece","try"]),
 ("b25","the same","content","同样的","I'll have the same.","have",["order","drink","meal"]),
]),
("C", "Coffee & Cafe", "scene_c.png", [
 ("c01","a coffee","content","来杯咖啡","I'll get a coffee.","get",["make","try","want"]),
 ("c02","with milk","content","加奶","Coffee with milk, please.","milk",["sugar","ice","cream"]),
 ("c03","no sugar","content","不加糖","Tea, no sugar.","sugar",["milk","ice","lemon"]),
 ("c04","to go","function","带走","One latte to go.","latte",["coffee","tea","juice"]),
 ("c05","for here","function","堂食","Two espressos for here.","here",["now","me","us"]),
 ("c06","a latte","content","拿铁","She ordered a latte.","ordered",["made","wanted","liked"]),
 ("c07","an espresso","content","意式浓缩","I drank an espresso.","drank",["made","wanted","tried"]),
 ("c08","iced tea","content","冰茶","Iced tea sounds good.","good",["nice","great","cold"]),
 ("c09","a muffin","content","玛芬蛋糕","Add a muffin, please.","muffin",["cookie","cake","bread"]),
 ("c10","a croissant","content","可颂","I ate a croissant.","ate",["bought","wanted","liked"]),
 ("c11","what size","function","什么杯型","What size do you want?","want",["need","like","take"]),
 ("c12","a medium","content","要中杯","A medium, please.","please",["sir","thanks","miss"]),
 ("c13","a large","content","要大杯","A large, please.","please",["sir","thanks","miss"]),
 ("c14","a small","content","要小杯","A small is enough.","enough",["fine","okay","good"]),
 ("c15","any flavor","function","任意口味","Any flavor is fine.","fine",["good","okay","nice"]),
 ("c16","a refill","content","免费续杯","This one is a refill.","refill",["cup","drink","tea"]),
 ("c17","sit by the window","content","靠窗坐","We sat by the window.","window",["door","wall","fire"]),
 ("c18","free wifi","content","免费 wifi","Do you have free wifi?","wifi",["water","menu","seats"]),
 ("c19","the receipt","content","（咖啡）小票","Keep the receipt, please.","keep",["show","print","check"]),
 ("c20","my order","content","我的订单","Where is my order?","order",["coffee","food","bag"]),
 ("c21","wait a moment","function","稍等","Wait a moment, please.","please",["sir","miss","thanks"]),
 ("c22","right away","function","立刻","I'll bring it right away.","bring",["make","send","do"]),
 ("c23","on the house","function","店家请客","This one is on the house.","house",["us","you","me"]),
 ("c24","a tip","content","给小费","Leave a tip, please.","leave",["add","give","keep"]),
 ("c25","it's closed","content","现已打烊","The cafe is closed.","cafe",["shop","store","market"]),
]),
("D", "Restaurant", "scene_d.png", [
 ("d01","a reservation","content","预订","I have a reservation.","have",["want","need","made"]),
 ("d02","book a table","function","订位","Can we book a table?","table",["room","seat","spot"]),
 ("d03","the waiter","content","服务员","Call the waiter, please.","call",["ask","tell","stop"]),
 ("d04","a starter","content","前菜","I'll have a starter.","have",["order","try","skip"]),
 ("d05","main course","content","主菜","The main course was great.","great",["good","hot","big"]),
 ("d06","a dessert","content","甜点","Save room for dessert.","room",["space","time","money"]),
 ("d07","the special","content","今日特餐","What is the special?","what",["where","how","when"]),
 ("d08","today's soup","content","今日汤品","I'll take today's soup.","soup",["salad","fish","rice"]),
 ("d09","cook it rare","content","做成三分熟","Cook it rare, please.","rare",["well","medium","hot"]),
 ("d10","well done","content","全熟","Cook it well done.","cook",["make","serve","give"]),
 ("d11","medium rare","content","五分熟","Medium rare, please.","please",["sir","chef","miss"]),
 ("d12","make it spicy","content","做得辣一点","Make it spicy, please.","spicy",["sweet","salty","hot"]),
 ("d13","go vegetarian","content","吃素（素食）","I will go vegetarian.","vegetarian",["vegan","light","fresh"]),
 ("d14","food allergies","content","食物过敏","I have food allergies.","allergies",["some","no","issues"]),
 ("d15","I recommend","function","我推荐你","I recommend the fish.","fish",["soup","steak","salad"]),
 ("d16","tastes good","function","味道不错","This tastes good.","good",["great","odd","fresh"]),
 ("d17","too salty","function","太咸","It's too salty.","salty",["sweet","hot","dry"]),
 ("d18","the check","content","买单","Bring the check, please.","bring",["give","show","get"]),
 ("d19","split the bill","function","分单","Let's split the bill.","bill",["cost","check","tip"]),
 ("d20","it's on me","function","我请客","Dinner is on me.","me",["us","him","them"]),
 ("d21","a fork","content","叉子","I need a fork.","need",["want","lost","dropped"]),
 ("d22","a knife","content","刀","Pass the knife, please.","pass",["give","show","find"]),
 ("d23","a napkin","content","餐巾","Where is my napkin?","napkin",["fork","spoon","cup"]),
 ("d24","enjoy your meal","function","请慢用","Enjoy your meal!","meal",["food","lunch","dinner"]),
 ("d25","save leftovers","content","留剩菜","Pack the leftovers, please.","pack",["keep","wrap","take"]),
]),
("E", "Eating out", "scene_e.png", [
 ("e01","eat out","function","下馆子","We eat out a lot.","lot",["often","late","early"]),
 ("e02","fast food","content","快餐","I love fast food.","love",["hate","avoid","skip"]),
 ("e03","a snack","content","小吃／零食","Grab a snack, okay?","grab",["buy","make","share"]),
 ("e04","feel hungry","content","感到饿","I feel hungry now.","now",["often","still","soon"]),
 ("e05","feel full","content","觉得饱了","I feel full, thanks.","thanks",["now","already","sir"]),
 ("e06","a bite","content","一口","Just a bite, please.","please",["sip","taste","try"]),
 ("e07","taste tasty","content","尝起来美味","This tastes tasty.","tasty",["great","odd","fresh"]),
 ("e08","stay fresh","content","保持新鲜","The fish stays fresh.","fish",["bread","fruit","meat"]),
 ("e09","too sweet","content","太甜了","This is too sweet.","sweet",["salty","hot","dry"]),
 ("e10","very sour","content","很酸","This is very sour.","sour",["sweet","bitter","mild"]),
 ("e11","so bitter","content","很苦","Coffee is so bitter.","Coffee",["Tea","Beer","Food"]),
 ("e12","order food","function","点餐","Let's order food.","food",["drinks","pizza","sushi"]),
 ("e13","a refill","content","续杯（加）","Can I get a refill?","get",["have","try","want"]),
 ("e14","get takeaway","content","外带带走","I'll get takeaway.","get",["take","make","want"]),
 ("e15","a menu card","content","菜单卡","Show me the menu card.","show",["give","read","open"]),
 ("e16","pay by card","function","刷卡付","I pay by card.","card",["cash","phone","app"]),
 ("e17","leave a tip","content","留小费","Leave a tip, please.","leave",["add","give","keep"]),
 ("e18","the restroom","content","洗手间","Where is the restroom?","where",["what","how","when"]),
 ("e19","a high chair","content","宝宝高脚椅","We need a high chair.","need",["want","have","use"]),
 ("e20","a kids menu","content","儿童菜单","Do you have a kids menu?","have",["want","see","need"]),
 ("e21","no peanuts","content","不要花生","No peanuts, please.","peanuts",["salt","sugar","onion"]),
 ("e22","gluten free","content","无麸质","I eat gluten free.","eat",["want","need","cook"]),
 ("e23","a straw","content","吸管","Give me a straw.","give",["find","show","get"]),
 ("e24","the wifi password","content","wifi 密码","What's the wifi password?","password",["code","name","key"]),
 ("e25","open late","function","营业到很晚","This place opens late.","opens",["closes","stays","runs"]),
]),
("F", "Shopping", "scene_f.png", [
 ("f01","how much","function","问价多少","How much is this?","this",["that","it","one"]),
 ("f02","too expensive","function","太贵","This is too expensive.","expensive",["cheap","big","small"]),
 ("f03","a discount","content","折扣","Can I get a discount?","get",["have","use","want"]),
 ("f04","on sale","function","在打折","It is on sale.","It",["That","This","They"]),
 ("f05","a size","content","尺码","What size do you wear?","wear",["need","want","take"]),
 ("f06","try on","function","试穿","Can I try it on?","it",["them","this","one"]),
 ("f07","a fitting room","content","试衣间","Where is the fitting room?","where",["what","how","when"]),
 ("f08","too tight","function","太紧","These are too tight.","tight",["loose","small","big"]),
 ("f09","too loose","function","太松","This is too loose.","loose",["tight","long","short"]),
 ("f10","a receipt","content","收据","Keep the receipt, please.","keep",["show","print","check"]),
 ("f11","cash only","function","只收现金","We are cash only.","We",["They","It","He"]),
 ("f12","credit card","content","信用卡","Do you take credit card?","take",["want","need","use"]),
 ("f13","a bag","content","购物袋","I need a bag.","need",["want","have","use"]),
 ("f14","in stock","function","有货","Is this in stock?","this",["that","it","one"]),
 ("f15","sold out","function","售罄","This size is sold out.","size",["color","model","style"]),
 ("f16","a refund","content","退款","I want a refund.","want",["need","get","have"]),
 ("f17","exchange it","function","换货（调换）","Can I exchange it?","it",["them","this","one"]),
 ("f18","the price","content","价格","The price is fair.","fair",["high","low","odd"]),
 ("f19","something cheaper","content","更便宜的","Something cheaper, please.","please",["sir","miss","thanks"]),
 ("f20","a color","content","颜色","What color do you like?","like",["want","need","prefer"]),
 ("f21","a style","content","款式","This style suits you.","suits",["fits","matches","works"]),
 ("f22","a brand","content","品牌","Which brand is this?","which",["what","whose","that"]),
 ("f23","a warranty","content","保修","Does it have a warranty?","have",["need","want","include"]),
 ("f24","look around","function","随便看看","I'm just looking around.","looking",["browsing","checking","wandering"]),
 ("f25","window shopping","content","逛橱窗","We went window shopping.","went",["love","enjoy","tried"]),
]),
("G", "Numbers & paying", "scene_g.png", [
 ("g01","how much","function","结账多少钱","How much do I owe?","owe",["pay","need","have"]),
 ("g02","a dollar","content","一美元","It costs a dollar.","costs",["was","is","makes"]),
 ("g03","a euro","content","一欧元","That is a euro.","That",["This","It","They"]),
 ("g04","ten yuan","content","十元","It is ten yuan.","ten",["five","twenty","fifty"]),
 ("g05","the total","content","总额","What is the total?","what",["where","how","when"]),
 ("g06","pay cash","function","付现金","I will pay cash.","cash",["later","now","here"]),
 ("g07","by card","function","刷卡","I paid by card.","paid",["pay","buy","settle"]),
 ("g08","a coin","content","硬币","I have a coin.","have",["need","lost","found"]),
 ("g09","keep the change","content","留着找零","Keep the change.","keep",["count","check","give"]),
 ("g10","a tip","content","餐费小费","Add a tip, please.","add",["leave","give","keep"]),
 ("g11","the bill","content","分摊账单","Split the bill, okay?","split",["pay","check","cover"]),
 ("g12","a receipt","content","收据小票","Print the receipt, please.","print",["show","keep","check"]),
 ("g13","ten yuan","content","十元整","That is ten yuan.","ten",["five","twenty","fifty"]),
 ("g14","twenty total","content","一共二十","That is twenty total.","total",["each","all","now"]),
 ("g15","fifty back","content","找回五十","Give me fifty back.","back",["more","change","cash"]),
 ("g16","a hundred","content","一百","A hundred is enough.","enough",["fine","okay","good"]),
 ("g17","first in line","content","排第一","You are first in line.","line",["row","place","turn"]),
 ("g18","the second","content","第二个","The second one is mine.","mine",["his","hers","ours"]),
 ("g19","in half","content","分成两半","Cut it in half.","cut",["split","share","break"]),
 ("g20","make it double","content","加倍（双份）","Make it double, please.","make",["give","serve","add"]),
 ("g21","it is free","content","这是免费的","This one is free.","free",["cheap","small","new"]),
 ("g22","a price tag","content","价签","Read the price tag.","read",["check","show","see"]),
 ("g23","too pricey","function","太贵了","This feels too pricey.","pricey",["costly","high","much"]),
 ("g24","a budget","content","预算","I have a budget.","have",["set","keep","hit"]),
 ("g25","on me","function","我买单","The drinks are on me.","drinks",["meal","ride","bill"]),
]),
("H", "Directions", "scene_h.png", [
 ("h01","where is","function","…在哪里","Where is the station?","station",["bank","hotel","exit"]),
 ("h02","go straight","function","直走","Go straight ahead.","ahead",["back","left","right"]),
 ("h03","turn left","function","左转","Turn left at the corner.","corner",["light","gate","shop"]),
 ("h04","turn right","function","右转","Turn right after the bridge.","bridge",["park","shop","school"]),
 ("h05","at the corner","function","在拐角","It is at the corner.","It",["He","She","We"]),
 ("h06","next to","function","在…旁边","It is next to the bank.","bank",["park","shop","hotel"]),
 ("h07","across from","function","在…对面","Across from the school.","school",["park","store","church"]),
 ("h08","behind it","function","在它后面","The car is behind it.","car",["tree","wall","shop"]),
 ("h09","in front of","function","在…前面","In front of the gate.","gate",["door","shop","hotel"]),
 ("h10","how far","function","多远","How far is the beach?","beach",["town","park","mall"]),
 ("h11","on the left","function","在左侧","The shop is on the left.","left",["right","corner","hill"]),
 ("h12","on the right","function","在右侧","The bus stop is on the right.","right",["left","corner","hill"]),
 ("h13","a block","content","一个街区","Walk a block, then stop.","walk",["go","run","drive"]),
 ("h14","a crossroad","content","十字路口","Wait at the crossroad.","wait",["stop","turn","look"]),
 ("h15","the subway","content","地铁","Take the subway, please.","take",["ride","use","catch"]),
 ("h16","a bus stop","content","公交站","The bus stop is near.","near",["far","open","closed"]),
 ("h17","a map","content","地图","I lost my map.","lost",["need","want","use"]),
 ("h18","I am lost","content","我迷路了","I am lost, help me.","help",["find","show","tell"]),
 ("h19","the exit","content","出口","Follow the exit sign.","follow",["find","see","take"]),
 ("h20","the entrance","content","入口","The entrance is here.","here",["there","open","locked"]),
 ("h21","a detour","content","绕路","Take a detour, please.","take",["find","use","try"]),
 ("h22","on foot","function","步行","We came on foot.","came",["went","travel","arrive"]),
 ("h23","by taxi","function","打车","Let's go by taxi.","go",["ride","come","leave"]),
 ("h24","a minute","content","一分钟","It is a minute away.","away",["far","near","long"]),
 ("h25","this way","function","这边走","This way, please.","please",["sir","miss","madam"]),
]),
("I", "Places", "scene_i.png", [
 ("i01","the bank","content","银行","Where is the bank?","where",["what","how","when"]),
 ("i02","a hotel","content","酒店","I booked a hotel.","booked",["found","left","need"]),
 ("i03","the station","content","车站","Meet me at the station.","meet",["wait","call","find"]),
 ("i04","the airport","content","机场","The airport is far.","far",["near","busy","big"]),
 ("i05","a hospital","content","医院","Is there a hospital?","there",["near","one","any"]),
 ("i06","a pharmacy","content","药房","Find a pharmacy, please.","find",["use","need","want"]),
 ("i07","a supermarket","content","超市","I shop at the supermarket.","shop",["work","stop","go"]),
 ("i08","a mall","content","商场","Let's meet at the mall.","meet",["eat","walk","sit"]),
 ("i09","a park","content","公园","The park is quiet.","quiet",["big","green","close"]),
 ("i10","a museum","content","博物馆","We visited a museum.","visited",["liked","saw","entered"]),
 ("i11","a beach","content","海滩","The beach is empty.","empty",["clean","far","nice"]),
 ("i12","a library","content","图书馆","The library is open.","open",["closed","quiet","free"]),
 ("i13","a school","content","学校","The school is nearby.","nearby",["far","big","new"]),
 ("i14","a church","content","教堂","The church is old.","old",["small","white","quiet"]),
 ("i15","a market","content","市场","The market is busy.","busy",["cheap","open","loud"]),
 ("i16","a gas station","content","加油站","Stop at a gas station.","stop",["find","use","need"]),
 ("i17","a post office","content","邮局","Where is the post office?","where",["what","how","when"]),
 ("i18","a police station","content","警察局","Call the police station.","call",["find","reach","use"]),
 ("i19","a restaurant","content","餐厅","I like this restaurant.","like",["found","need","want"]),
 ("i20","a cafe","content","咖啡馆","We sat in a cafe.","sat",["met","worked","waited"]),
 ("i21","a gym","content","健身房","I go to the gym.","go",["run","train","swim"]),
 ("i22","a bar","content","酒吧","The bar is loud.","loud",["open","busy","late"]),
 ("i23","a theater","content","剧院","We saw a play at the theater.","saw",["liked","entered","left"]),
 ("i24","a temple","content","寺庙","The temple is ancient.","ancient",["quiet","far","old"]),
 ("i25","go downtown","content","去市中心","Let's go downtown.","go",["walk","drive","meet"]),
]),
("J", "Time & plans", "scene_j.png", [
 ("j01","what time","function","几点","What time is it?","it",["now","then","soon"]),
 ("j02","right now","timeplace","现在","I am free right now.","free",["busy","tired","late"]),
 ("j03","a bit later","timeplace","稍晚一点","Call me a bit later.","later",["soon","today","tomorrow"]),
 ("j04","see you tomorrow","timeplace","明天见","See you tomorrow, friend.","friend",["sir","miss","all"]),
 ("j05","next week","timeplace","下周","I leave next week.","leave",["arrive","return","travel"]),
 ("j06","this morning","timeplace","今早","I ran this morning.","ran",["woke","left","called"]),
 ("j07","this evening","timeplace","今晚","We eat this evening.","eat",["meet","walk","talk"]),
 ("j08","on Monday","timeplace","周一","The class is on Monday.","class",["meeting","trip","call"]),
 ("j09","at noon","timeplace","中午","Let's meet at noon.","meet",["eat","talk","sit"]),
 ("j10","at night","timeplace","夜里","The city sleeps at night.","sleeps",["wakes","calms","shines"]),
 ("j11","wake early","timeplace","早起","I wake early daily.","daily",["now","first","soon"]),
 ("j12","arrive late","timeplace","迟到（晚到）","Sorry I arrive late.","late",["early","soon","now"]),
 ("j13","on time","function","准时","The train is on time.","train",["bus","taxi","plane"]),
 ("j14","in a hurry","function","赶时间","I am in a hurry.","hurry",["rush","late","panic"]),
 ("j15","make plans","function","做计划","Let's make plans.","plans",["time","room","space"]),
 ("j16","must cancel","function","必须取消","I must cancel today.","today",["now","soon","it"]),
 ("j17","let's reschedule","function","我们改期","Let's reschedule, okay?","okay",["soon","now","later"]),
 ("j18","are you free","timeplace","你有空吗","Are you free today?","today",["now","later","tonight"]),
 ("j19","I am busy","content","我很忙","I am busy now.","now",["later","tomorrow","today"]),
 ("j20","an appointment","content","预约","I have an appointment.","have",["need","made","want"]),
 ("j21","a deadline","content","截止日","The deadline is near.","near",["far","tight","past"]),
 ("j22","for a while","function","一会儿","Wait for a while.","wait",["stay","rest","sit"]),
 ("j23","every day","function","每天","I read every day.","read",["walk","cook","train"]),
 ("j24","see you soon","content","很快见","See you soon, friend.","friend",["sir","miss","all"]),
 ("j25","in a minute","timeplace","一分钟内","I'll be there in a minute.","there",["ready","back","done"]),
]),
("K", "Weather", "scene_k.png", [
 ("k01","it is sunny","content","天气晴朗","It is sunny today.","today",["now","outside","here"]),
 ("k02","it is rainy","content","下雨天","It is rainy again.","again",["now","often","still"]),
 ("k03","sky is cloudy","content","天阴了","The sky is cloudy.","sky",["day","morning","evening"]),
 ("k04","it is windy","content","有风","It is windy outside.","outside",["here","now","today"]),
 ("k05","it is snowy","content","下雪了","It is snowy in winter.","winter",["mountains","north","town"]),
 ("k06","it is hot","content","天气热","It is hot today.","today",["now","outside","here"]),
 ("k07","feel cold","content","觉得冷","I feel cold now.","now",["often","still","here"]),
 ("k08","room is warm","content","房间暖","The room is warm.","room",["day","water","sun"]),
 ("k09","a storm","content","暴风雨","A storm is coming.","coming",["near","past","here"]),
 ("k10","it is foggy","content","有雾","It is foggy now.","now",["here","today","outside"]),
 ("k11","the temperature","content","温度","What is the temperature?","what",["where","how","when"]),
 ("k12","ten degrees","content","十度","It is ten degrees.","ten",["five","thirty","zero"]),
 ("k13","an umbrella","content","雨伞","Bring an umbrella.","bring",["take","need","use"]),
 ("k14","a coat","content","外套","Wear a coat, please.","wear",["bring","take","buy"]),
 ("k15","rain boots","content","雨靴","I wore rain boots.","wore",["bought","found","need"]),
 ("k16","check forecast","content","查天气预报","Check the forecast.","check",["read","watch","trust"]),
 ("k17","clear up","function","放晴","It will clear up.","will",["might","should","can"]),
 ("k18","pour down","function","倾盆大雨","It started to pour down.","started",["began","rained","poured"]),
 ("k19","a breeze","content","微风","Feel the breeze.","feel",["enjoy","love","catch"]),
 ("k20","air is humid","content","空气潮湿","The air is humid here.","here",["now","today","outside"]),
 ("k21","air is dry","content","空气干","The air is dry.","dry",["day","weather","skin"]),
 ("k22","a season","content","季节","Winter is my season.","winter",["spring","summer","fall"]),
 ("k23","the climate","content","气候","I like the climate.","like",["hate","prefer","study"]),
 ("k24","in the shade","content","在阴凉处","Let's sit in the shade.","sit",["rest","wait","stay"]),
 ("k25","the weather","content","这天气","The weather is nice.","nice",["bad","odd","calm"]),
]),
("L", "Feelings", "scene_l.png", [
 ("l01","I am happy","content","我开心","I am happy today.","today",["now","here","again"]),
 ("l02","look sad","content","看上去难过","She looks sad now.","now",["often","still","today"]),
 ("l03","so tired","content","好累","I am so tired.","so",["very","still","not"]),
 ("l04","is angry","content","生气了","He is angry now.","now",["today","still","often"]),
 ("l05","I am excited","content","我很兴奋","I am excited!","I",["We","She","He"]),
 ("l06","feel nervous","content","感到紧张","I feel nervous now.","now",["often","still","here"]),
 ("l07","I am bored","content","我觉得无聊","I am bored, honestly.","honestly",["now","often","today"]),
 ("l08","stay calm","content","保持冷静","Stay calm, please.","calm",["quiet","still","cool"]),
 ("l09","I am worried","content","我担心","I am worried, honestly.","worried",["sad","tired","lost"]),
 ("l10","I am proud","content","我骄傲","I am proud of you.","you",["him","her","us"]),
 ("l11","feel lonely","content","感到孤独","I feel lonely here.","here",["now","tonight","often"]),
 ("l12","I am grateful","content","我很感激","I am grateful, truly.","truly",["deeply","so","really"]),
 ("l13","I am confused","content","我困惑","I am confused now.","now",["still","often","here"]),
 ("l14","feel relaxed","content","感到放松","I feel relaxed at last.","last",["home","now","here"]),
 ("l15","still hungry","content","还饿着","I am still hungry.","hungry",["thirsty","tired","lost"]),
 ("l16","feel thirsty","content","感到渴","I feel thirsty, get water.","get",["want","need","bring"]),
 ("l17","feel sick","content","感到不适","I feel sick today.","today",["now","suddenly","badly"]),
 ("l18","I am fine","content","我还行","I am fine, thanks.","thanks",["now","really","okay"]),
 ("l19","I feel great","content","感觉很棒","I feel great!","I",["We","She","He"]),
 ("l20","I feel awful","content","感觉糟糕","I feel awful.","I",["We","She","He"]),
 ("l21","miss you","function","想你","I miss you a lot.","lot",["so","already","still"]),
 ("l22","cheer up","function","振作","Cheer up, it's okay.","okay",["soon","now","friend"]),
 ("l23","no worries","function","别担心","No worries, I'm fine.","fine",["late","busy","tired"]),
 ("l24","take it easy","function","放轻松","Take it easy today.","today",["now","tonight","friend"]),
 ("l25","feel better","function","感觉好些","I hope you feel better.","hope",["get","stay","are"]),
]),
("M", "Opinions", "scene_m.png", [
 ("m01","I think","function","我认为","I think it is good.","good",["bad","odd","true"]),
 ("m02","in my view","function","依我看","In my view, it works.","works",["helps","fits","matters"]),
 ("m03","I agree","function","我同意","I agree with you.","you",["him","her","them"]),
 ("m04","I disagree","function","我不同意","I disagree, sorry.","sorry",["though","really","kindly"]),
 ("m05","maybe we","function","也许我们","Maybe we can go.","go",["try","help","stay"]),
 ("m06","probably rain","function","大概会下雨","It will probably rain.","rain",["work","help","pass"]),
 ("m07","I prefer","function","我更喜欢","I prefer tea.","tea",["coffee","walk","home"]),
 ("m08","I like","function","我喜欢","I like this one.","one",["idea","place","song"]),
 ("m09","I don't like","function","我不喜欢","I don't like that.","that",["this","it","him"]),
 ("m10","it's good","function","挺好的","It's good, I guess.","guess",["think","feel","suppose"]),
 ("m11","it's bad","function","不太好","It's bad, honestly.","honestly",["really","truly","sadly"]),
 ("m12","the best","content","最好的","This is the best.","This",["That","It","He"]),
 ("m13","the worst","content","最差的","That was the worst.","That",["This","It","We"]),
 ("m14","it is important","content","这很重要","This is important.","This",["That","It","He"]),
 ("m15","that is useless","content","那没用","That is useless.","That",["This","It","He"]),
 ("m16","this is useful","content","这有用","This tip is useful.","tip",["idea","tool","trick"]),
 ("m17","I doubt","function","我怀疑（它）","I doubt it works.","works",["helps","fits","matters"]),
 ("m18","for sure","function","肯定","For sure, I'll go.","go",["come","stay","help"]),
 ("m19","not really","function","不算／不太","Not really, thanks.","thanks",["sir","miss","now"]),
 ("m20","to be honest","function","说实话","To be honest, no.","no",["yes","maybe","later"]),
 ("m21","I suppose","function","我想是","I suppose so.","so",["not","maybe","yes"]),
 ("m22","no way","function","不可能","No way, that's silly.","silly",["late","wrong","cheap"]),
 ("m23","of course","function","当然（我同意）","Of course I agree.","agree",["will","do","help"]),
 ("m24","I'm not sure","function","我不确定","I'm not sure yet.","yet",["now","still","either"]),
 ("m25","what a pity","function","真遗憾","What a pity, indeed.","indeed",["really","sadly","though"]),
]),
("N", "Invitations", "scene_n.png", [
 ("n01","would you like","function","你想…吗","Would you like some tea?","tea",["coffee","water","cake"]),
 ("n02","come with me","function","跟我来","Come with me, please.","please",["now","soon","friend"]),
 ("n03","join us","function","加入我们","Join us for dinner.","dinner",["lunch","coffee","walk"]),
 ("n04","be my guest","function","请随意","Be my guest tonight.","tonight",["now","here","today"]),
 ("n05","save a seat","function","留个位","Save a seat for me.","me",["him","her","us"]),
 ("n06","a dinner party","content","晚宴","I host a dinner party.","host",["plan","love","join"]),
 ("n07","a birthday","content","生日","It is my birthday.","my",["his","her","their"]),
 ("n08","let's celebrate","content","我们庆祝","Let's celebrate tonight.","tonight",["now","soon","together"]),
 ("n09","you're invited","function","你被邀请了","You're invited, friend.","friend",["sir","miss","all"]),
 ("n10","count me in","function","算我一个","Count me in, sure.","sure",["in","too","yes"]),
 ("n11","maybe next time","function","也许下次","Maybe next time.","time",["day","week","year"]),
 ("n12","I'd love to","function","我很乐意","I'd love to, thanks.","thanks",["really","sure","gladly"]),
 ("n13","I can't","function","我去不了","I can't, sorry.","sorry",["today","now","later"]),
 ("n14","bring a friend","function","带个朋友","Bring a friend along.","along",["too","over","here"]),
 ("n15","pick you up","function","接你","I'll pick you up.","up",["out","home","there"]),
 ("n16","drop you off","function","送你","I'll drop you off.","off",["home","there","near"]),
 ("n17","see you there","function","那边见","See you there at eight.","eight",["seven","nine","six"]),
 ("n18","on the list","function","在名单上","You are on the list.","list",["map","team","plan"]),
 ("n19","please RSVP","content","请回复邀约","Please RSVP by Friday.","Friday",["Monday","noon","mail"]),
 ("n20","a gift","content","礼物","Bring a gift, maybe.","maybe",["card","cake","wine"]),
 ("n21","dress code","content","着装要求","What is the dress code?","what",["where","how","when"]),
 ("n22","casual is fine","content","休闲就好","Casual is fine.","fine",["okay","good","accepted"]),
 ("n23","formal tonight","content","今晚正式","Formal tonight, sadly.","tonight",["here","now","then"]),
 ("n24","a plus one","content","带一人","Can I bring a plus one?","bring",["take","have","invite"]),
 ("n25","the host","content","主人","Meet the host, please.","host",["guest","chef","band"]),
]),
("O", "Kind requests", "scene_o.png", [
 ("o01","could you","function","您能…吗","Could you open the window?","window",["door","bag","box"]),
 ("o02","would you mind","function","您介意…吗","Would you mind waiting?","waiting",["sitting","moving","helping"]),
 ("o03","help me please","function","请帮帮我","Help me please, sir.","sir",["miss","now","friend"]),
 ("o04","if you don't mind","function","若不介意","If you don't mind, I'll sit.","sit",["go","pass","leave"]),
 ("o05","when you can","function","方便时","Call when you can.","call",["text","come","reply"]),
 ("o06","no rush","function","不急","No rush, take your time.","time",["hurry","worry","stress"]),
 ("o07","bear with me","function","请包涵","Bear with me, please.","please",["sir","miss","now"]),
 ("o08","make a request","function","提个请求","I'd like to make a request.","request",["point","wish","note"]),
 ("o09","do me a favor","function","帮个忙","Do me a favor, okay?","okay",["please","sir","friend"]),
 ("o10","lend me","function","借我","Lend me a pen.","pen",["book","charger","hand"]),
 ("o11","spare a moment","function","抽空","Spare a moment, please.","please",["sir","miss","now"]),
 ("o12","I was wondering","function","我想请教","I was wondering if you help.","help",["know","agree","join"]),
 ("o13","it's not urgent","function","暂不紧急","It's not urgent, relax.","relax",["hurry","worry","rush"]),
 ("o14","at your convenience","function","您方便时","Reply at your convenience.","reply",["call","come","send"]),
 ("o15","thank you in advance","function","先谢过","Thank you in advance.","advance",["kindly","so","much"]),
 ("o16","I appreciate it","function","我感激你","I appreciate it, truly.","truly",["so","deeply","really"]),
 ("o17","excuse me","function","打扰一下","Excuse me, one question.","question",["moment","sec","thing"]),
 ("o18","sorry to bother","function","抱歉打扰","Sorry to bother you.","you",["him","her","them"]),
 ("o19","may I","function","我可以…吗","May I sit here?","sit",["pass","ask","help"]),
 ("o20","after you","function","您先请","After you, please.","please",["sir","miss","madam"]),
 ("o21","go ahead","function","请便／继续","Go ahead, I'm listening.","listening",["speaking","saying","doing"]),
 ("o22","be careful","function","小心","Be careful on the stairs.","stairs",["road","step","corner"]),
 ("o23","mind the step","function","注意脚下","Mind the step, please.","please",["sir","miss","now"]),
 ("o24","hold on","function","稍等一下","Hold on a second.","second",["minute","moment","bit"]),
 ("o25","let me help","function","让我来帮你","Let me help you.","you",["him","her","them"]),
]),
("P", "Quick responses", "scene_p.png", [
 ("p01","yes I will","content","好我愿意","Yes I will, thanks.","will",["can","do","try"]),
 ("p02","no thanks","content","婉拒：不了","No thanks, I'm set.","set",["fine","full","good"]),
 ("p03","sure no problem","content","当然没问题","Sure no problem at all.","all",["here","sir","now"]),
 ("p04","okay I see","content","好的明白了","Okay I see now.","now",["sir","miss","friend"]),
 ("p05","got it","function","明白了","Got it, thanks.","thanks",["sir","miss","now"]),
 ("p06","I see","function","我懂了（理解）","I see what you mean.","mean",["say","want","need"]),
 ("p07","no problem","function","没问题（小事）","No problem at all.","all",["here","sir","now"]),
 ("p08","of course","function","当然（我能）","Of course I can.","can",["will","do","help"]),
 ("p09","wait a moment","content","等一下","Wait a moment, please.","please",["sir","miss","now"]),
 ("p10","never mind","function","算了","Never mind, it's fine.","fine",["okay","small","done"]),
 ("p11","let's go","function","走吧","Let's go now.","now",["home","there","outside"]),
 ("p12","good idea","function","好主意","Good idea, let's do it.","do",["try","make","take"]),
 ("p13","that works","function","那样行","That works for me.","me",["us","him","them"]),
 ("p14","not yet","function","还没","Not yet, almost.","almost",["now","soon","ready"]),
 ("p15","right away","function","马上","I'll do it right away.","do",["make","send","call"]),
 ("p16","just a sec","function","稍等一秒","Just a sec, please.","please",["sir","miss","now"]),
 ("p17","me too","function","我也是","Me too, exactly.","exactly",["also","sir","miss"]),
 ("p18","me neither","function","我也不","Me neither, sadly.","sadly",["really","now","here"]),
 ("p19","why not","function","为何不","Why not give it a try?","try",["go","see","ask"]),
 ("p20","no thanks","function","不用了","No thanks, I'm full.","full",["done","fine","good"]),
 ("p21","you're welcome","function","不客气","You're welcome, friend.","friend",["sir","miss","all"]),
 ("p22","my pleasure","function","我的荣幸","My pleasure, truly.","truly",["sir","miss","madam"]),
 ("p23","exactly right","content","完全正确","Exactly right, you got it.","got",["said","know","see"]),
 ("p24","perhaps another","content","或许另一次","Perhaps another time.","time",["day","week","place"]),
 ("p25","definitely yes","content","绝对是","Definitely yes, count me in.","in",["on","sure","ready"]),
]),
("Q", "Yes & no", "scene_q.png", [
 ("q01","yes please","function","好的（接受）","Yes please, I'd love one.","one",["some","more","two"]),
 ("q02","no thank you","function","不用了谢谢","No thank you, I'm set.","set",["fine","full","good"]),
 ("q03","I guess so","function","我想是吧","I guess so, maybe.","maybe",["yes","sure","not"]),
 ("q04","absolutely agree","content","绝对同意","Absolutely agree, I do.","do",["will","can","love"]),
 ("q05","not at all","function","一点也不","Not at all, it's fine.","fine",["small","okay","nothing"]),
 ("q06","by all means","function","当然可以","By all means, go ahead.","ahead",["in","on","now"]),
 ("q07","I'm afraid not","function","恐怕不行","I'm afraid not, sorry.","sorry",["now","today","yet"]),
 ("q08","that's right","function","没错","That's right, you got it.","got",["said","know","see"]),
 ("q09","that's wrong","function","错了","That's wrong, sorry.","sorry",["it","him","them"]),
 ("q10","are you sure","function","你确定吗","Are you sure, really?","really",["now","sir","miss"]),
 ("q11","I'm certain","function","我确定","I'm certain, yes.","yes",["now","sir","miss"]),
 ("q12","doubt it","function","我表示怀疑","Doubt it, honestly.","honestly",["really","truly","now"]),
 ("q13","no way","function","没门","No way, that's false.","false",["late","wrong","cheap"]),
 ("q14","sure thing","function","没问题（包了）","Sure thing, I'm in.","in",["on","yes","ready"]),
 ("q15","not exactly","function","不全是","Not exactly, but close.","close",["right","true","near"]),
 ("q16","sort of","function","算是","Sort of, I suppose.","suppose",["guess","think","feel"]),
 ("q17","on the contrary","function","恰恰相反","On the contrary, no.","no",["yes","not","maybe"]),
 ("q18","I suppose not","function","我想不是","I suppose not, no.","no",["yes","maybe","yet"]),
 ("q19","quite good","content","相当好","Quite good, I agree.","agree",["like","love","feel"]),
 ("q20","hardly any","content","几乎没","Hardly any, not really.","really",["at","all","now"]),
 ("q21","maybe yes","function","也许是","Maybe yes, who knows.","knows",["says","cares","tells"]),
 ("q22","definitely not","function","绝对不","Definitely not, no.","no",["way","sir","miss"]),
 ("q23","could be","function","可能是","Could be, I guess.","guess",["say","think","feel"]),
 ("q24","I'd say no","function","我会说不行","I'd say no, sorry.","sorry",["now","today","yet"]),
 ("q25","we agreed","content","我们同意","We agreed, let's move.","let",["us","them","go"]),
]),
("R", "Understanding", "scene_r.png", [
 ("r01","I don't understand","function","我没听懂","I don't understand, sorry.","sorry",["yet","now","still"]),
 ("r02","say that again","function","再说一遍","Say that again, please.","please",["slowly","louder","sir"]),
 ("r03","speak slowly","function","说慢点","Speak slowly, thanks.","thanks",["clearly","louder","sir"]),
 ("r04","what does mean","function","…是什么意思","What does this mean?","this",["that","it","word"]),
 ("r05","in English","function","用英语","Say it in English.","English",["Chinese","simple","short"]),
 ("r06","please translate","function","请翻译","Please translate this.","this",["it","that","word"]),
 ("r07","speak louder","content","说大声点","Speak louder, please.","please",["clearly","slowly","sir"]),
 ("r08","say clearly","content","说清楚","Say it clearly.","it",["that","this","word"]),
 ("r09","I see","function","我明白了","I see, thank you.","you",["now","sir","miss"]),
 ("r10","got it","function","懂了","Got it, I will.","I",["We","She","He"]),
 ("r11","say pardon","content","请再说（抱歉）","Say pardon, repeat that.","repeat",["slowly","louder","please"]),
 ("r12","excuse me","function","抱歉（没听清）","Excuse me, repeat that.","that",["it","this","word"]),
 ("r13","what do you mean","function","你什么意思","What do you mean by that?","that",["this","it","so"]),
 ("r14","I'm confused","function","我糊涂了","I'm confused, explain.","explain",["stop","wait","slow"]),
 ("r15","make sense","function","说得通","That makes sense now.","now",["here","to","me"]),
 ("r16","I get it","function","我听明白了","I get it, thanks.","thanks",["now","sir","miss"]),
 ("r17","could you repeat","function","能重复吗","Could you repeat that?","that",["it","this","part"]),
 ("r18","in other words","function","换句话说","In other words, slower.","slower",["clear","loud","short"]),
 ("r19","I follow","function","我跟上（听懂）","I follow you now.","you",["him","her","them"]),
 ("r20","missed that","function","漏听了","I missed that, sorry.","sorry",["it","part","word"]),
 ("r21","a word","content","一个词","What is that word?","that",["this","the","your"]),
 ("r22","a phrase","content","一个短语","Teach me a phrase.","me",["us","him","her"]),
 ("r23","the meaning","content","意思","Tell me the meaning.","tell",["show","give","find"]),
 ("r24","please clarify","function","请澄清","Please clarify that.","that",["it","this","part"]),
 ("r25","I'm listening","function","我在听","I'm listening, go on.","go",["speak","tell","say"]),
]),
("S", "Morning routine", "scene_s.png", [
 ("s01","wake up","function","醒来","I wake up at seven.","seven",["six","eight","nine"]),
 ("s02","get up","function","起床","I get up early.","early",["late","soon","now"]),
 ("s03","brush teeth","function","刷牙","I brush teeth daily.","daily",["now","first","twice"]),
 ("s04","take a shower","function","洗澡","I take a shower.","shower",["bath","break","nap"]),
 ("s05","get dressed","function","穿衣服","I get dressed fast.","fast",["slow","first","last"]),
 ("s06","make coffee","function","煮咖啡","I make coffee first.","first",["now","here","daily"]),
 ("s07","have breakfast","function","吃早餐","I have breakfast at home.","home",["work","school","now"]),
 ("s08","check phone","function","看手机","I check phone in bed.","bed",["bus","morning","night"]),
 ("s09","feed the cat","function","喂猫","I feed the cat.","cat",["dog","fish","bird"]),
 ("s10","walk the dog","function","遛狗","I walk the dog.","dog",["cat","baby","path"]),
 ("s11","pack my bag","function","收拾包","I pack my bag.","bag",["lunch","things","books"]),
 ("s12","catch the bus","function","赶公交","I catch the bus.","bus",["train","taxi","subway"]),
 ("s13","go to work","function","去上班","I go to work now.","now",["late","soon","home"]),
 ("s14","a alarm","content","闹钟","Set the alarm, please.","set",["check","use","hear"]),
 ("s15","a routine","content","日常","I love my routine.","love",["hate","keep","change"]),
 ("s16","on weekdays","timeplace","工作日","I work on weekdays.","work",["rest","sleep","train"]),
 ("s17","early bird","content","早起的人","I am an early bird.","an",["a","the","no"]),
 ("s18","fresh air","content","新鲜空气","I want fresh air.","want",["need","breathe","like"]),
 ("s19","a to-do list","content","待办清单","Make a to-do list.","make",["check","use","keep"]),
 ("s20","a habit","content","习惯","This is a good habit.","good",["bad","new","old"]),
 ("s21","sleep well","function","睡得好","I slept well.","slept",["ate","ran","felt"]),
 ("s22","stay in bed","function","赖床","I stay in bed.","bed",["late","long","warm"]),
 ("s23","a quick bite","content","随便吃口","Grab a quick bite.","grab",["make","buy","eat"]),
 ("s24","head out","function","出门","I head out at eight.","eight",["seven","nine","six"]),
 ("s25","start the day","function","开始一天","Let's start the day.","day",["week","work","plan"]),
]),
("T", "Home & Hotel", "scene_t.png", [
 ("t01","check in","function","办理入住","I want to check in.","in",["out","now","here"]),
 ("t02","check out","function","退房","I need to check out.","out",["in","now","early"]),
 ("t03","a room key","content","房卡","I lost my room key.","lost",["need","want","use"]),
 ("t04","a twin room","content","双床房","I booked a twin room.","booked",["want","need","found"]),
 ("t05","a single room","content","单人间","Give me a single room.","give",["find","show","book"]),
 ("t06","room service","content","客房服务","Call room service.","call",["use","need","want"]),
 ("t07","a towel","content","毛巾","Bring a towel, please.","bring",["find","show","give"]),
 ("t08","the wifi","content","无线网络","What is the wifi code?","code",["name","key","pass"]),
 ("t09","the elevator","content","电梯","The elevator is there.","there",["here","broken","busy"]),
 ("t10","a balcony","content","阳台","The room has a balcony.","has",["needs","lacks","wants"]),
 ("t11","air conditioning","content","空调","Turn on the air conditioning.","on",["off","up","down"]),
 ("t12","make the bed","function","铺床","I make the bed.","bed",["room","coffee","lunch"]),
 ("t13","do the dishes","function","洗碗","I do the dishes.","dishes",["laundry","cleaning","trash"]),
 ("t14","take out trash","function","扔垃圾","Take out the trash.","trash",["recycling","bags","boxes"]),
 ("t15","clean the room","function","打扫房间","Clean the room, please.","please",["now","soon","sir"]),
 ("t16","a guest","content","客人","We have a guest.","have",["met","invited","host"]),
 ("t17","the landlord","content","房东","Call the landlord.","call",["text","meet","ask"]),
 ("t18","a neighbor","content","邻居","My neighbor is kind.","kind",["loud","new","old"]),
 ("t19","the doorman","content","门房","The doorman helped me.","helped",["opened","called","waited"]),
 ("t20","a key card","content","门禁卡","Swipe the key card.","swipe",["show","tap","use"]),
 ("t21","a heater","content","暖气","Turn on the heater.","on",["off","up","down"]),
 ("t22","the lights","content","灯","Switch off the lights.","off",["on","up","down"]),
 ("t23","a window","content","窗户","Open the window, please.","open",["close","clean","fix"]),
 ("t24","the floor","content","地板","Mop the floor, please.","mop",["sweep","clean","wash"]),
 ("t25","make yourself at home","function","别客气（像在家）","Make yourself at home.","home",["comfortable","welcome","relaxed"]),
]),
]

def main():
    bad_len = []
    seen_cn = {}
    dup_cn = []
    levels_out = []
    total = 0
    for (lid, theme, scene, chunks) in LEVELS:
        out_chunks = []
        for (cid, text, ctype, cn, ex, swap, opts) in chunks:
            total += 1
            wc = word_count(text)
            if not (2 <= wc <= 5):
                bad_len.append((cid, text, wc))
            if cn in seen_cn:
                dup_cn.append((cid, seen_cn[cn], cn))
            else:
                seen_cn[cn] = cid
            out_chunks.append({
                "id": cid, "text": text, "type": ctype, "meaningCN": cn,
                "sentence": build_sentence(text, ctype, ex, swap, opts),
            })
        levels_out.append({"id": lid, "theme": theme, "sceneImage": scene, "chunks": out_chunks})

    pack = {"version": "1.1.0", "levels": levels_out}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(pack, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"[GEN] total chunks = {total}  (levels={len(levels_out)})")
    print(f"[GEN] self-check 1 (2-5 words) failures = {len(bad_len)}")
    for b in bad_len: print("   BAD:", b)
    print(f"[GEN] self-check 2 (CN anchor unique) dups = {len(dup_cn)}")
    for d in dup_cn: print("   DUP:", d)
    print("[GEN] per-scene chunk counts:")
    for (lid, theme, scene, chunks) in LEVELS:
        print(f"   {lid}: {theme} -> {len(chunks)}")
    random.seed(20261014)
    allc = [(lid, c) for (lid, _, _, ch) in LEVELS for c in ch]
    sample_n = max(10, int(len(allc) * 0.10))
    sample = random.sample(allc, sample_n)
    print(f"[GEN] self-check 3 (naturalness sample, n={sample_n}):")
    for lid, c in sample:
        print(f"   [{lid}/{c[0]}] {c[1]} | {c[3]} | e.g. {c[4]}")
    if bad_len or dup_cn:
        print("[GEN] FAILED self-checks; abort.")
        sys.exit(1)
    # 进包闸门（DDS §19.2 / 指令 N §一）：先补齐核心库标签，再校验；失败即阻断。
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run([sys.executable, os.path.join(here, "tag_core_library.py")], check=True)
    subprocess.run([sys.executable, os.path.join(here, "validate_content_pack.py")], check=True)
    print(f"[GEN] OK -> wrote {OUT}")

if __name__ == "__main__":
    main()
