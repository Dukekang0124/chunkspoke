# ChunkSpoke v2.0 内容总表（Phase 0 审校稿）

> 共 26 关，每关 4-6 词块；每词块绑定 1 句可说出口的完整句（句子由本关词块纯拼接）。
> 词块类型：content 内容 / function 功能 / connector 连接 / timeplace 时间地点（对应 UI 四色双重编码）。

## A · Asking for things

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I'd like | function | 我想要（礼貌表达意愿） | I'd like the menu, please. | like, menu | the menu | a glass of water / a table for two / the bill |
| 2 | a glass of | content | 一杯…（饮品量词） | I'd like a glass of water. | like, water | a glass of | a cup of / a bottle of / some |
| 3 | water | content | 水 | I'd like a glass of water. | like, water | water | juice / coffee / tea |
| 4 | the menu | content | 菜单 | I'd like the menu, please. | like, menu | the menu | the bill / a table for two / the wifi |
| 5 | please | function | 请（礼貌用语） | I'd like the menu, please. | like, menu | the menu | a glass of water / a table for two / the bill |

## B · Breakfast

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I'll have | function | 我点…（点餐） | I'll have eggs and toast. | have, eggs, toast | eggs | coffee / pancakes / cereal |
| 2 | eggs | content | 鸡蛋 | Some eggs and toast. | eggs, toast | eggs | toast / fruit / coffee |
| 3 | and | connector | 和（连接词） | Eggs and toast. | eggs, toast | eggs | Toast / Fruit / Coffee |
| 4 | toast | content | 吐司 | I'll have toast and eggs. | have, toast, eggs | toast | eggs / cereal / pancakes |
| 5 | some | function | 一些（量词） | Some eggs and toast. | eggs, toast | eggs | toast / fruit / coffee |

## C · Coffee & Cafe

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I'd like | function | 我想要 | I'd like a cup of coffee. | like, coffee | a cup of | a glass of tea / a bottle of water / some hot milk |
| 2 | a cup of | content | 一杯…（量词短语，后接饮品） | Can I have a cup of coffee. | have, coffee | a cup of | a glass of / a bottle of / some |
| 3 | coffee | content | 咖啡 | I'd like a cup of coffee. | like, coffee | coffee | tea / juice / water |
| 4 | Can I have | function | 我能要…吗 | Can I have a cup of coffee. | have, coffee | coffee | tea / juice / water |
| 5 | the bill | content | 账单 | Can I have the bill. | have, bill | the bill | the menu / a table / the wifi |

## D · Directions

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Where is | function | …在哪里 | Where is the station. | where, station | the station | the bus stop / the exit / the toilet |
| 2 | the station | content | 车站 | Where is the station near here. | station, near | the station | the hotel / the bank / the park |
| 3 | near here | timeplace | 在这附近 | Turn left near here. | turn, near | left | right / back / around |
| 4 | Turn | function | 转向… | Turn left near here. | turn, left | left | right / back / around |
| 5 | left | content | 左边 | Turn left near here. | turn, left | left | right / back / around |

## E · Eating out

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I'd like to order | function | 我想点… | I'd like to order a pizza. | like, order, pizza | a pizza | a salad / a burger / some pasta |
| 2 | a pizza | content | 一个披萨 | I'd like to order a pizza. | like, pizza | a pizza | a salad / a burger / some pasta |
| 3 | a table for two | content | 两人桌 | Could you bring a table for two. | bring, table | a table for two | a table for four / a window seat / the bill |
| 4 | the bill | content | 账单 | Could you bring the bill. | bring, bill | the bill | the menu / some water / the check |
| 5 | Could you bring | function | 能请你拿…吗 | Could you bring a pizza. | bring, pizza | a pizza | a salad / a burger / some pasta |

## F · Feelings

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I'm | function | 我是… | I'm happy. | happy | happy | tired / sad / excited |
| 2 | happy | content | 开心 | I'm happy. | happy | happy | tired / sad / excited |
| 3 | tired | content | 累 | I'm a little tired. | tired | tired | hungry / sleepy / busy |
| 4 | a little | function | 有点… | I'm a little sad. | sad | sad | very / so / not |
| 5 | sad | content | 难过 | I'm a little sad. | sad | sad | tired / hungry / busy |

## G · Greetings

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Hi | function | 嗨 | Hi, how are you. | hi | Hi | Hello / Hey / Good morning |
| 2 | how are you | function | 你好吗 | Hi, how are you. | how | how are you | How is it going / What's up / How have you been |
| 3 | Nice to meet you | content | 很高兴认识你 | Nice to meet you, Thanks. | nice | Nice to meet you | Good to see you / Pleased to meet you / Great to meet you |
| 4 | See you later | content | 回头见 | See you later, Thanks. | see | See you later | See you soon / Talk to you later / Bye for now |
| 5 | Thanks | function | 谢谢 | Thanks, See you later. | thanks | See you later | Nice to meet you / See you soon / Talk to you later |

## H · Home & Hotel

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I have | function | 我有… | I have a reservation. | have, reservation | a reservation | a question / a problem / a request |
| 2 | a reservation | content | 预订 | I have a reservation. | have, reservation | a reservation | a question / a problem / a request |
| 3 | the room | content | 房间 | Can I get the room. | get, room | the room | the wifi / the key / the bill |
| 4 | Can I get | function | 能给我…吗 | Can I get the wifi. | get, wifi | the wifi | the room / some towels / the key |
| 5 | the wifi | content | 无线网络 | Can I get the wifi. | get, wifi | the wifi | the room / some towels / the key |

## I · Invitations

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Would you like | function | 你想要…吗 | Would you like to join us. | would, join | to join us | to come with us / to have dinner / to dance |
| 2 | to join us | function | 加入我们 | Would you like to join us. | join | to join us | to come with us / to have dinner / to dance |
| 3 | Let's | function | 我们…吧 | Let's go to the party. | lets, party | the party | the movies / the beach / dinner |
| 4 | the party | content | 派对 | Let's go to the party. | party | the party | the movies / the beach / dinner |
| 5 | go to | function | 去… | Let's go to the party. | go, party | the party | the movies / the beach / dinner |

## J · Just checking

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | What's new | function | 有什么新鲜事 | What's new with you. | what, new | What's new | What's up / How's it going / Anything new |
| 2 | with you | connector | 和你… | What's new with you. | new | with you | today / this week / lately |
| 3 | Not much | content | 没什么 | Not much, Same here. | much | Not much | Same old / Busy / Quiet |
| 4 | Same here | content | 我也是 | Same here, Not much. | same | Same here | Me too / Right / Exactly |
| 5 | busy | content | 忙 | Same here, busy. | busy | busy | tired / good / free |

## K · Kind requests

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Could you | function | 你能…吗 | Could you help me, Please. | could, help | help me | open this / move that / repeat that |
| 2 | help me | content | 帮我 | Could you help me, Please. | help | help me | show me / tell me / check this |
| 3 | Please | function | 请 | Can you help me, Please. | help | help me | show me / tell me / check this |
| 4 | Can you | function | 你能…吗 | Can you help me, Please. | can, help | help me | show me / tell me / check this |
| 5 | slowly | content | 慢一点 | Could you help me slowly. | help, slowly | slowly | clearly / louder / again |

## L · Let's go

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Let's go | function | 我们走吧 | Let's go home. | lets, go | home | out / now / together |
| 2 | home | content | 家 | Let's go home. | home | home | out / now / together |
| 3 | Are we ready | function | 我们准备好了吗 | Are we ready to leave. | ready, leave | to leave | to go / to eat / to start |
| 4 | to leave | function | 离开 | Are we ready to leave. | leave | to leave | to go / to eat / to start |
| 5 | the car | content | 车 | Let's go the car. | go, car | the car | the bus / the train / the taxi |

## M · Morning routine

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I wake up | content | 我醒来 | I wake up at seven. | wake, seven | at seven | early / late / at six |
| 2 | at seven | timeplace | 在七点 | I wake up at seven. | wake, seven | at seven | at eight / at nine / in the morning |
| 3 | I take | function | 我洗/做… | I take a shower. | take, shower | a shower | a bath / a walk / a break |
| 4 | a shower | content | 淋浴 | I take a shower. | take, shower | a shower | a bath / a walk / a break |
| 5 | then | connector | 然后 | I take a shower then. | take, shower | a shower | a bath / a walk / a break |

## N · Numbers & paying

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | How much | function | 多少钱 | How much is this. | how, much | is this | How many / What price / The total |
| 2 | is this | content | 这个… | How much is this. | this | is this | is that / is the book / is the bag |
| 3 | It's | function | 它是… | It's ten dollars. | ten, dollars | ten dollars | twenty / five / free |
| 4 | ten dollars | content | 十美元 | It's ten dollars. | ten, dollars | ten dollars | twenty / five / free |
| 5 | Can I pay | function | 我能付款…吗 | Can I pay ten dollars. | pay, dollars | ten dollars | twenty / five / free |

## O · Opinions

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I think | function | 我认为 | I think it's good. | think, good | it's good | great / okay / bad |
| 2 | it's good | content | 挺好的 | I think it's good. | good | it's good | great / nice / enough |
| 3 | This | function | 这… | This is better. | better | is better | worse / cheaper / bigger |
| 4 | is better | content | 更好 | This is better. | better | is better | worse / cheaper / bigger |
| 5 | I like | function | 我喜欢 | I like This. | like | This | that one / both / neither |

## P · Places

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Where is | function | …在哪里 | Where is the museum. | where, museum | the museum | the park / the lake / the square |
| 2 | the museum | content | 博物馆 | Where is the museum. | museum | the museum | the park / the lake / the square |
| 3 | Let's meet | function | 我们见面…吧 | Let's meet at the park. | meet, park | at the park | at the station / at the mall / at the cafe |
| 4 | at the park | timeplace | 在公园 | Let's meet at the park. | meet, park | at the park | at the station / at the mall / at the cafe |
| 5 | next to | timeplace | 在…旁边 | Where is next to the museum. | next, museum | next to | behind / across from / far from |

## Q · Quick responses

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Sure | content | 当然 | Sure, no problem. | sure | Sure | Of course / Definitely / Okay |
| 2 | no problem | content | 没问题 | Sure, no problem. | problem | no problem | my pleasure / anytime / you're welcome |
| 3 | I see | content | 我明白了 | I see, no problem. | see | I see | Got it / Understand / Right |
| 4 | Just a moment | content | 稍等 | Just a moment, I see. | moment | Just a moment | One second / Wait / Hold on |
| 5 | Of course | content | 当然 | Of course, no problem. | of course | Of course | Sure / Definitely / Why not |

## R · Restaurant

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | A table for | content | …人桌 | A table for two. | table, two | two | four / three / one |
| 2 | two | content | 两个 | A table for two. | two | two | four / three / one |
| 3 | I'd like to book | function | 我想预订 | I'd like to book the menu. | like, book | the menu | a table for two / the bill / a window seat |
| 4 | the menu | content | 菜单 | I'd like to book the menu. | book, menu | the menu | a table for two / the bill / a window seat |
| 5 | What do you recommend | function | 你推荐什么 | What do you recommend the menu. | recommend, menu | the menu | the wine list / the specials / the bill |

## S · Shopping

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | How much is | function | …多少钱 | How much is this shirt. | how, shirt | this shirt | this hat / that bag / these shoes |
| 2 | this shirt | content | 这件衬衫 | How much is this shirt. | shirt | this shirt | this hat / that bag / these shoes |
| 3 | I'm just looking | content | 我只是看看 | I'm just looking in blue. | looking, blue | in blue | in red / in black / in green |
| 4 | Do you have | function | 你们有…吗 | Do you have this shirt in blue. | have, shirt, blue | this shirt | this hat / that bag / these shoes |
| 5 | in blue | content | 蓝色的 | Do you have this shirt in blue. | blue | in blue | in red / in black / in green |

## T · Time & plans

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | What time | function | 几点… | What time shall we meet. | what, meet | shall we meet | do we leave / is dinner / is the movie |
| 2 | shall we meet | function | 我们见面 | What time shall we meet. | meet | shall we meet | do we leave / is dinner / is the movie |
| 3 | Let's meet | function | 我们见面…吧 | Let's meet at eight. | meet, eight | at eight | at six / at noon / tomorrow |
| 4 | at eight | timeplace | 在八点 | Let's meet at eight. | meet, eight | at eight | at six / at noon / tomorrow |
| 5 | I'm free | content | 我有空 | I'm free at eight. | free, eight | at eight | at six / at noon / tomorrow |

## U · Understanding

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Sorry | function | 抱歉 | Sorry, can you repeat. | sorry, repeat | can you repeat | Excuse me / Pardon / Wait |
| 2 | can you repeat | function | 你能重复吗 | Sorry, can you repeat. | repeat | can you repeat | say that again / spell it / explain |
| 3 | I don't | function | 我不… | I don't understand. | understand | understand | know / follow / get it |
| 4 | understand | content | 明白 | I don't understand. | understand | understand | know / follow / get it |
| 5 | Could you write | function | 你能写下来吗 | Sorry, Could you write. | write | Could you write | show me / spell it / point to it |

## V · Weekend vibes

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | What are you doing | function | 你在做什么 | What are you doing this weekend. | doing, weekend | this weekend | tonight / tomorrow / on holiday |
| 2 | this weekend | timeplace | 这个周末 | What are you doing this weekend. | weekend | this weekend | tonight / tomorrow / on holiday |
| 3 | I'm going | function | 我要去 | I'm going to the beach. | going, beach | to the beach | to a party / hiking / shopping |
| 4 | to the beach | content | 去海滩 | I'm going to the beach. | beach | to the beach | to the park / home / out |
| 5 | Let's hang out | content | 我们聚聚吧 | Let's hang out this weekend. | hang, weekend | this weekend | tonight / tomorrow / after work |

## W · Weather

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | It's | function | 它是… | It's sunny today. | sunny, today | sunny | rainy / cold / hot |
| 2 | sunny | content | 晴天 | It's sunny today. | sunny | sunny | rainy / cold / hot |
| 3 | today | timeplace | 今天 | It's sunny today. | today | sunny | tomorrow / tonight / this week |
| 4 | How's the weather | function | 天气怎样 | How's the weather today. | weather | today | tomorrow / tonight / this week |
| 5 | cold | content | 冷 | It's cold today. | cold, today | cold | warm / windy / snowing |

## X · eXclamations

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Wow | content | 哇 | Wow, that's amazing. | wow | Wow | Cool / Nice / Great |
| 2 | that's amazing | content | 太棒了 | Wow, that's amazing. | amazing | that's amazing | great / cool / awesome |
| 3 | Oh no | content | 噢不 | Oh no, it's broken. | oh no | Oh no | Oops / Uh oh / Damn |
| 4 | it's broken | content | 坏了 | Oh no, it's broken. | broken | it's broken | lost / late / wrong |
| 5 | Happy birthday | content | 生日快乐 | Wow, Happy birthday. | happy, birthday | Happy birthday | New Year / anniversary / holidays |

## Y · Yes & no

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | Yes | content | 是的 | Yes, please. | yes | Yes | Sure / Okay / Why not |
| 2 | please | function | 请 | Yes, please. | please | Yes | No / Maybe / Sure |
| 3 | No | content | 不 | No, thanks. | no | No | Sure / Maybe / Okay |
| 4 | thanks | function | 谢谢 | No, thanks. | thanks | No | Yes / Maybe / Sure |
| 5 | I agree | content | 我同意 | Yes, I agree. | agree | I agree | disagree / think so / don't think so |

## Zzz · Sleep & rest

| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |
|---|---|---|---|---|---|---|---|
| 1 | I'm | function | 我是… | I'm sleepy. | sleepy | sleepy | tired / awake / dizzy |
| 2 | sleepy | content | 困 | I'm sleepy. | sleepy | sleepy | tired / awake / dizzy |
| 3 | Good night | content | 晚安 | I'm Good night. | good, night | Good night | morning / bye / rest |
| 4 | I need to sleep | content | 我需要睡 | I need to sleep the light. | need, sleep | the light | to rest / to lie down / to close my eyes |
| 5 | Turn off | function | 关掉… | Turn off the light. | turn, light | the light | on / down / up |
| 6 | the light | content | 灯 | Turn off the light. | light | the light | the tv / the music / the fan |

