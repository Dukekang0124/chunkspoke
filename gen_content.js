// Phase 0 内容生成器：输出 content_pack.json + 内容总表.md
// 硬规则：每句仅由本关词块拼接而成（无额外固定词）；slot.text 必须是本关某 chunk.text。
const fs = require('fs');

const LEVELS = [
  {
    id: 'A', theme: 'Asking for things', sceneImage: 'scene_a.png',
    chunks: [
      { id: 'a_ild_like', text: "I'd like", type: 'function', meaningCN: '我想要（礼貌表达意愿）',
        sentence: { text: "I'd like the menu, please.", slots: [{text:"I'd like",type:'function'},{text:'the menu',type:'content'},{text:'please',type:'function'}], coreWords:['like','menu'], swapSlotIndex:1, swapOptions:['a glass of water','a table for two','the bill'] } },
      { id: 'a_glass_of', text: 'a glass of', type: 'content', meaningCN: '一杯…（饮品量词）',
        sentence: { text: "I'd like a glass of water.", slots: [{text:"I'd like",type:'function'},{text:'a glass of',type:'content'},{text:'water',type:'content'}], coreWords:['like','water'], swapSlotIndex:1, swapOptions:['a cup of','a bottle of','some'] } },
      { id: 'a_water', text: 'water', type: 'content', meaningCN: '水',
        sentence: { text: "I'd like a glass of water.", slots: [{text:"I'd like",type:'function'},{text:'a glass of',type:'content'},{text:'water',type:'content'}], coreWords:['like','water'], swapSlotIndex:2, swapOptions:['juice','coffee','tea'] } },
      { id: 'a_menu', text: 'the menu', type: 'content', meaningCN: '菜单',
        sentence: { text: "I'd like the menu, please.", slots: [{text:"I'd like",type:'function'},{text:'the menu',type:'content'},{text:'please',type:'function'}], coreWords:['like','menu'], swapSlotIndex:1, swapOptions:['the bill','a table for two','the wifi'] } },
      { id: 'a_please', text: 'please', type: 'function', meaningCN: '请（礼貌用语）',
        sentence: { text: "I'd like the menu, please.", slots: [{text:"I'd like",type:'function'},{text:'the menu',type:'content'},{text:'please',type:'function'}], coreWords:['like','menu'], swapSlotIndex:1, swapOptions:['a glass of water','a table for two','the bill'] } },
    ],
  },
  {
    id: 'B', theme: 'Breakfast', sceneImage: 'scene_b.png',
    chunks: [
      { id: 'b_ill_have', text: "I'll have", type: 'function', meaningCN: '我点…（点餐）',
        sentence: { text: "I'll have eggs and toast.", slots: [{text:"I'll have",type:'function'},{text:'eggs',type:'content'},{text:'and',type:'connector'},{text:'toast',type:'content'}], coreWords:['have','eggs','toast'], swapSlotIndex:1, swapOptions:['coffee','pancakes','cereal'] } },
      { id: 'b_eggs', text: 'eggs', type: 'content', meaningCN: '鸡蛋',
        sentence: { text: 'Some eggs and toast.', slots: [{text:'some',type:'function'},{text:'eggs',type:'content'},{text:'and',type:'connector'},{text:'toast',type:'content'}], coreWords:['eggs','toast'], swapSlotIndex:1, swapOptions:['toast','fruit','coffee'] } },
      { id: 'b_and', text: 'and', type: 'connector', meaningCN: '和（连接词）',
        sentence: { text: 'Eggs and toast.', slots: [{text:'eggs',type:'content'},{text:'and',type:'connector'},{text:'toast',type:'content'}], coreWords:['eggs','toast'], swapSlotIndex:0, swapOptions:['Toast','Fruit','Coffee'] } },
      { id: 'b_toast', text: 'toast', type: 'content', meaningCN: '吐司',
        sentence: { text: "I'll have toast and eggs.", slots: [{text:"I'll have",type:'function'},{text:'toast',type:'content'},{text:'and',type:'connector'},{text:'eggs',type:'content'}], coreWords:['have','toast','eggs'], swapSlotIndex:1, swapOptions:['eggs','cereal','pancakes'] } },
      { id: 'b_some', text: 'some', type: 'function', meaningCN: '一些（量词）',
        sentence: { text: 'Some eggs and toast.', slots: [{text:'some',type:'function'},{text:'eggs',type:'content'},{text:'and',type:'connector'},{text:'toast',type:'content'}], coreWords:['eggs','toast'], swapSlotIndex:1, swapOptions:['toast','fruit','coffee'] } },
    ],
  },
  {
    id: 'C', theme: 'Coffee & Cafe', sceneImage: 'scene_c.png',
    chunks: [
      { id: 'c_ild_like', text: "I'd like", type: 'function', meaningCN: '我想要',
        sentence: { text: "I'd like a cup of coffee.", slots: [{text:"I'd like",type:'function'},{text:'a cup of',type:'content'},{text:'coffee',type:'content'}], coreWords:['like','coffee'], swapSlotIndex:1, swapOptions:['a glass of tea','a bottle of water','some hot milk'] } },
      { id: 'c_cup_of', text: 'a cup of', type: 'content', meaningCN: '一杯…（量词短语，后接饮品）',
        sentence: { text: "Can I have a cup of coffee.", slots: [{text:'Can I have',type:'function'},{text:'a cup of',type:'content'},{text:'coffee',type:'content'}], coreWords:['have','coffee'], swapSlotIndex:1, swapOptions:['a glass of','a bottle of','some'] } },
      { id: 'c_coffee', text: 'coffee', type: 'content', meaningCN: '咖啡',
        sentence: { text: "I'd like a cup of coffee.", slots: [{text:"I'd like",type:'function'},{text:'a cup of',type:'content'},{text:'coffee',type:'content'}], coreWords:['like','coffee'], swapSlotIndex:2, swapOptions:['tea','juice','water'] } },
      { id: 'c_can_have', text: 'Can I have', type: 'function', meaningCN: '我能要…吗',
        sentence: { text: "Can I have a cup of coffee.", slots: [{text:'Can I have',type:'function'},{text:'a cup of',type:'content'},{text:'coffee',type:'content'}], coreWords:['have','coffee'], swapSlotIndex:2, swapOptions:['tea','juice','water'] } },
      { id: 'c_bill', text: 'the bill', type: 'content', meaningCN: '账单',
        sentence: { text: "Can I have the bill.", slots: [{text:'Can I have',type:'function'},{text:'the bill',type:'content'}], coreWords:['have','bill'], swapSlotIndex:1, swapOptions:['the menu','a table','the wifi'] } },
    ],
  },
  {
    id: 'D', theme: 'Directions', sceneImage: 'scene_d.png',
    chunks: [
      { id: 'd_where_is', text: 'Where is', type: 'function', meaningCN: '…在哪里',
        sentence: { text: 'Where is the station.', slots: [{text:'Where is',type:'function'},{text:'the station',type:'content'}], coreWords:['where','station'], swapSlotIndex:1, swapOptions:['the bus stop','the exit','the toilet'] } },
      { id: 'd_station', text: 'the station', type: 'content', meaningCN: '车站',
        sentence: { text: 'Where is the station near here.', slots: [{text:'Where is',type:'function'},{text:'the station',type:'content'},{text:'near here',type:'timeplace'}], coreWords:['station','near'], swapSlotIndex:1, swapOptions:['the hotel','the bank','the park'] } },
      { id: 'd_near_here', text: 'near here', type: 'timeplace', meaningCN: '在这附近',
        sentence: { text: 'Turn left near here.', slots: [{text:'Turn',type:'function'},{text:'left',type:'content'},{text:'near here',type:'timeplace'}], coreWords:['turn','near'], swapSlotIndex:1, swapOptions:['right','back','around'] } },
      { id: 'd_turn', text: 'Turn', type: 'function', meaningCN: '转向…',
        sentence: { text: 'Turn left near here.', slots: [{text:'Turn',type:'function'},{text:'left',type:'content'},{text:'near here',type:'timeplace'}], coreWords:['turn','left'], swapSlotIndex:1, swapOptions:['right','back','around'] } },
      { id: 'd_left', text: 'left', type: 'content', meaningCN: '左边',
        sentence: { text: 'Turn left near here.', slots: [{text:'Turn',type:'function'},{text:'left',type:'content'},{text:'near here',type:'timeplace'}], coreWords:['turn','left'], swapSlotIndex:1, swapOptions:['right','back','around'] } },
    ],
  },
  {
    id: 'E', theme: 'Eating out', sceneImage: 'scene_e.png',
    chunks: [
      { id: 'e_order', text: "I'd like to order", type: 'function', meaningCN: '我想点…',
        sentence: { text: "I'd like to order a pizza.", slots: [{text:"I'd like to order",type:'function'},{text:'a pizza',type:'content'}], coreWords:['like','order','pizza'], swapSlotIndex:1, swapOptions:['a salad','a burger','some pasta'] } },
      { id: 'e_pizza', text: 'a pizza', type: 'content', meaningCN: '一个披萨',
        sentence: { text: "I'd like to order a pizza.", slots: [{text:"I'd like to order",type:'function'},{text:'a pizza',type:'content'}], coreWords:['like','pizza'], swapSlotIndex:1, swapOptions:['a salad','a burger','some pasta'] } },
      { id: 'e_table', text: 'a table for two', type: 'content', meaningCN: '两人桌',
        sentence: { text: "Could you bring a table for two.", slots: [{text:'Could you bring',type:'function'},{text:'a table for two',type:'content'}], coreWords:['bring','table'], swapSlotIndex:1, swapOptions:['a table for four','a window seat','the bill'] } },
      { id: 'e_bill', text: 'the bill', type: 'content', meaningCN: '账单',
        sentence: { text: "Could you bring the bill.", slots: [{text:'Could you bring',type:'function'},{text:'the bill',type:'content'}], coreWords:['bring','bill'], swapSlotIndex:1, swapOptions:['the menu','some water','the check'] } },
      { id: 'e_could', text: 'Could you bring', type: 'function', meaningCN: '能请你拿…吗',
        sentence: { text: "Could you bring a pizza.", slots: [{text:'Could you bring',type:'function'},{text:'a pizza',type:'content'}], coreWords:['bring','pizza'], swapSlotIndex:1, swapOptions:['a salad','a burger','some pasta'] } },
    ],
  },
  {
    id: 'F', theme: 'Feelings', sceneImage: 'scene_f.png',
    chunks: [
      { id: 'f_im', text: "I'm", type: 'function', meaningCN: '我是…',
        sentence: { text: "I'm happy.", slots: [{text:"I'm",type:'function'},{text:'happy',type:'content'}], coreWords:['happy'], swapSlotIndex:1, swapOptions:['tired','sad','excited'] } },
      { id: 'f_happy', text: 'happy', type: 'content', meaningCN: '开心',
        sentence: { text: "I'm happy.", slots: [{text:"I'm",type:'function'},{text:'happy',type:'content'}], coreWords:['happy'], swapSlotIndex:1, swapOptions:['tired','sad','excited'] } },
      { id: 'f_tired', text: 'tired', type: 'content', meaningCN: '累',
        sentence: { text: "I'm a little tired.", slots: [{text:"I'm",type:'function'},{text:'a little',type:'function'},{text:'tired',type:'content'}], coreWords:['tired'], swapSlotIndex:2, swapOptions:['hungry','sleepy','busy'] } },
      { id: 'f_little', text: 'a little', type: 'function', meaningCN: '有点…',
        sentence: { text: "I'm a little sad.", slots: [{text:"I'm",type:'function'},{text:'a little',type:'function'},{text:'sad',type:'content'}], coreWords:['sad'], swapSlotIndex:2, swapOptions:['very','so','not'] } },
      { id: 'f_sad', text: 'sad', type: 'content', meaningCN: '难过',
        sentence: { text: "I'm a little sad.", slots: [{text:"I'm",type:'function'},{text:'a little',type:'function'},{text:'sad',type:'content'}], coreWords:['sad'], swapSlotIndex:2, swapOptions:['tired','hungry','busy'] } },
    ],
  },
  {
    id: 'G', theme: 'Greetings', sceneImage: 'scene_g.png',
    chunks: [
      { id: 'g_hi', text: 'Hi', type: 'function', meaningCN: '嗨',
        sentence: { text: 'Hi, how are you.', slots: [{text:'Hi',type:'function'},{text:'how are you',type:'function'}], coreWords:['hi'], swapSlotIndex:0, swapOptions:['Hello','Hey','Good morning'] } },
      { id: 'g_how', text: 'how are you', type: 'function', meaningCN: '你好吗',
        sentence: { text: 'Hi, how are you.', slots: [{text:'Hi',type:'function'},{text:'how are you',type:'function'}], coreWords:['how'], swapSlotIndex:1, swapOptions:['How is it going','What\'s up','How have you been'] } },
      { id: 'g_nice', text: 'Nice to meet you', type: 'content', meaningCN: '很高兴认识你',
        sentence: { text: 'Nice to meet you, Thanks.', slots: [{text:'Nice to meet you',type:'content'},{text:'Thanks',type:'function'}], coreWords:['nice'], swapSlotIndex:0, swapOptions:['Good to see you','Pleased to meet you','Great to meet you'] } },
      { id: 'g_see', text: 'See you later', type: 'content', meaningCN: '回头见',
        sentence: { text: 'See you later, Thanks.', slots: [{text:'See you later',type:'content'},{text:'Thanks',type:'function'}], coreWords:['see'], swapSlotIndex:0, swapOptions:['See you soon','Talk to you later','Bye for now'] } },
      { id: 'g_thanks', text: 'Thanks', type: 'function', meaningCN: '谢谢',
        sentence: { text: 'Thanks, See you later.', slots: [{text:'Thanks',type:'function'},{text:'See you later',type:'content'}], coreWords:['thanks'], swapSlotIndex:1, swapOptions:['Nice to meet you','See you soon','Talk to you later'] } },
    ],
  },
  {
    id: 'H', theme: 'Home & Hotel', sceneImage: 'scene_h.png',
    chunks: [
      { id: 'h_have', text: 'I have', type: 'function', meaningCN: '我有…',
        sentence: { text: 'I have a reservation.', slots: [{text:'I have',type:'function'},{text:'a reservation',type:'content'}], coreWords:['have','reservation'], swapSlotIndex:1, swapOptions:['a question','a problem','a request'] } },
      { id: 'h_resv', text: 'a reservation', type: 'content', meaningCN: '预订',
        sentence: { text: 'I have a reservation.', slots: [{text:'I have',type:'function'},{text:'a reservation',type:'content'}], coreWords:['have','reservation'], swapSlotIndex:1, swapOptions:['a question','a problem','a request'] } },
      { id: 'h_room', text: 'the room', type: 'content', meaningCN: '房间',
        sentence: { text: 'Can I get the room.', slots: [{text:'Can I get',type:'function'},{text:'the room',type:'content'}], coreWords:['get','room'], swapSlotIndex:1, swapOptions:['the wifi','the key','the bill'] } },
      { id: 'h_get', text: 'Can I get', type: 'function', meaningCN: '能给我…吗',
        sentence: { text: 'Can I get the wifi.', slots: [{text:'Can I get',type:'function'},{text:'the wifi',type:'content'}], coreWords:['get','wifi'], swapSlotIndex:1, swapOptions:['the room','some towels','the key'] } },
      { id: 'h_wifi', text: 'the wifi', type: 'content', meaningCN: '无线网络',
        sentence: { text: 'Can I get the wifi.', slots: [{text:'Can I get',type:'function'},{text:'the wifi',type:'content'}], coreWords:['get','wifi'], swapSlotIndex:1, swapOptions:['the room','some towels','the key'] } },
    ],
  },
  {
    id: 'I', theme: 'Invitations', sceneImage: 'scene_i.png',
    chunks: [
      { id: 'i_would', text: 'Would you like', type: 'function', meaningCN: '你想要…吗',
        sentence: { text: 'Would you like to join us.', slots: [{text:'Would you like',type:'function'},{text:'to join us',type:'function'}], coreWords:['would','join'], swapSlotIndex:1, swapOptions:['to come with us','to have dinner','to dance'] } },
      { id: 'i_join', text: 'to join us', type: 'function', meaningCN: '加入我们',
        sentence: { text: 'Would you like to join us.', slots: [{text:'Would you like',type:'function'},{text:'to join us',type:'function'}], coreWords:['join'], swapSlotIndex:1, swapOptions:['to come with us','to have dinner','to dance'] } },
      { id: 'i_lets', text: "Let's", type: 'function', meaningCN: '我们…吧',
        sentence: { text: "Let's go to the party.", slots: [{text:"Let's",type:'function'},{text:'go to',type:'function'},{text:'the party',type:'content'}], coreWords:['lets','party'], swapSlotIndex:2, swapOptions:['the movies','the beach','dinner'] } },
      { id: 'i_party', text: 'the party', type: 'content', meaningCN: '派对',
        sentence: { text: "Let's go to the party.", slots: [{text:"Let's",type:'function'},{text:'go to',type:'function'},{text:'the party',type:'content'}], coreWords:['party'], swapSlotIndex:2, swapOptions:['the movies','the beach','dinner'] } },
      { id: 'i_goto', text: 'go to', type: 'function', meaningCN: '去…',
        sentence: { text: "Let's go to the party.", slots: [{text:"Let's",type:'function'},{text:'go to',type:'function'},{text:'the party',type:'content'}], coreWords:['go','party'], swapSlotIndex:2, swapOptions:['the movies','the beach','dinner'] } },
    ],
  },
  {
    id: 'J', theme: 'Just checking', sceneImage: 'scene_j.png',
    chunks: [
      { id: 'j_new', text: "What's new", type: 'function', meaningCN: '有什么新鲜事',
        sentence: { text: "What's new with you.", slots: [{text:"What's new",type:'function'},{text:'with you',type:'connector'}], coreWords:['what','new'], swapSlotIndex:0, swapOptions:['What\'s up','How\'s it going','Anything new'] } },
      { id: 'j_with', text: 'with you', type: 'connector', meaningCN: '和你…',
        sentence: { text: "What's new with you.", slots: [{text:"What's new",type:'function'},{text:'with you',type:'connector'}], coreWords:['new'], swapSlotIndex:1, swapOptions:['today','this week','lately'] } },
      { id: 'j_notmuch', text: 'Not much', type: 'content', meaningCN: '没什么',
        sentence: { text: 'Not much, Same here.', slots: [{text:'Not much',type:'content'},{text:'Same here',type:'content'}], coreWords:['much'], swapSlotIndex:0, swapOptions:['Same old','Busy','Quiet'] } },
      { id: 'j_same', text: 'Same here', type: 'content', meaningCN: '我也是',
        sentence: { text: 'Same here, Not much.', slots: [{text:'Same here',type:'content'},{text:'Not much',type:'content'}], coreWords:['same'], swapSlotIndex:0, swapOptions:['Me too','Right','Exactly'] } },
      { id: 'j_busy', text: 'busy', type: 'content', meaningCN: '忙',
        sentence: { text: 'Same here, busy.', slots: [{text:'Same here',type:'content'},{text:'busy',type:'content'}], coreWords:['busy'], swapSlotIndex:1, swapOptions:['tired','good','free'] } },
    ],
  },
  {
    id: 'K', theme: 'Kind requests', sceneImage: 'scene_k.png',
    chunks: [
      { id: 'k_could', text: 'Could you', type: 'function', meaningCN: '你能…吗',
        sentence: { text: 'Could you help me, Please.', slots: [{text:'Could you',type:'function'},{text:'help me',type:'content'},{text:'Please',type:'function'}], coreWords:['could','help'], swapSlotIndex:1, swapOptions:['open this','move that','repeat that'] } },
      { id: 'k_help', text: 'help me', type: 'content', meaningCN: '帮我',
        sentence: { text: 'Could you help me, Please.', slots: [{text:'Could you',type:'function'},{text:'help me',type:'content'},{text:'Please',type:'function'}], coreWords:['help'], swapSlotIndex:1, swapOptions:['show me','tell me','check this'] } },
      { id: 'k_please', text: 'Please', type: 'function', meaningCN: '请',
        sentence: { text: 'Can you help me, Please.', slots: [{text:'Can you',type:'function'},{text:'help me',type:'content'},{text:'Please',type:'function'}], coreWords:['help'], swapSlotIndex:1, swapOptions:['show me','tell me','check this'] } },
      { id: 'k_can', text: 'Can you', type: 'function', meaningCN: '你能…吗',
        sentence: { text: 'Can you help me, Please.', slots: [{text:'Can you',type:'function'},{text:'help me',type:'content'},{text:'Please',type:'function'}], coreWords:['can','help'], swapSlotIndex:1, swapOptions:['show me','tell me','check this'] } },
      { id: 'k_slowly', text: 'slowly', type: 'content', meaningCN: '慢一点',
        sentence: { text: 'Could you help me slowly.', slots: [{text:'Could you',type:'function'},{text:'help me',type:'content'},{text:'slowly',type:'content'}], coreWords:['help','slowly'], swapSlotIndex:2, swapOptions:['clearly','louder','again'] } },
    ],
  },
  {
    id: 'L', theme: "Let's go", sceneImage: 'scene_l.png',
    chunks: [
      { id: 'l_letsgo', text: "Let's go", type: 'function', meaningCN: '我们走吧',
        sentence: { text: "Let's go home.", slots: [{text:"Let's go",type:'function'},{text:'home',type:'content'}], coreWords:['lets','go'], swapSlotIndex:1, swapOptions:['out','now','together'] } },
      { id: 'l_home', text: 'home', type: 'content', meaningCN: '家',
        sentence: { text: "Let's go home.", slots: [{text:"Let's go",type:'function'},{text:'home',type:'content'}], coreWords:['home'], swapSlotIndex:1, swapOptions:['out','now','together'] } },
      { id: 'l_ready', text: 'Are we ready', type: 'function', meaningCN: '我们准备好了吗',
        sentence: { text: 'Are we ready to leave.', slots: [{text:'Are we ready',type:'function'},{text:'to leave',type:'function'}], coreWords:['ready','leave'], swapSlotIndex:1, swapOptions:['to go','to eat','to start'] } },
      { id: 'l_leave', text: 'to leave', type: 'function', meaningCN: '离开',
        sentence: { text: 'Are we ready to leave.', slots: [{text:'Are we ready',type:'function'},{text:'to leave',type:'function'}], coreWords:['leave'], swapSlotIndex:1, swapOptions:['to go','to eat','to start'] } },
      { id: 'l_car', text: 'the car', type: 'content', meaningCN: '车',
        sentence: { text: "Let's go the car.", slots: [{text:"Let's go",type:'function'},{text:'the car',type:'content'}], coreWords:['go','car'], swapSlotIndex:1, swapOptions:['the bus','the train','the taxi'] } },
    ],
  },
  {
    id: 'M', theme: 'Morning routine', sceneImage: 'scene_m.png',
    chunks: [
      { id: 'm_wake', text: 'I wake up', type: 'content', meaningCN: '我醒来',
        sentence: { text: 'I wake up at seven.', slots: [{text:'I wake up',type:'content'},{text:'at seven',type:'timeplace'}], coreWords:['wake','seven'], swapSlotIndex:1, swapOptions:['early','late','at six'] } },
      { id: 'm_seven', text: 'at seven', type: 'timeplace', meaningCN: '在七点',
        sentence: { text: 'I wake up at seven.', slots: [{text:'I wake up',type:'content'},{text:'at seven',type:'timeplace'}], coreWords:['wake','seven'], swapSlotIndex:1, swapOptions:['at eight','at nine','in the morning'] } },
      { id: 'm_take', text: 'I take', type: 'function', meaningCN: '我洗/做…',
        sentence: { text: 'I take a shower.', slots: [{text:'I take',type:'function'},{text:'a shower',type:'content'}], coreWords:['take','shower'], swapSlotIndex:1, swapOptions:['a bath','a walk','a break'] } },
      { id: 'm_shower', text: 'a shower', type: 'content', meaningCN: '淋浴',
        sentence: { text: 'I take a shower.', slots: [{text:'I take',type:'function'},{text:'a shower',type:'content'}], coreWords:['take','shower'], swapSlotIndex:1, swapOptions:['a bath','a walk','a break'] } },
      { id: 'm_then', text: 'then', type: 'connector', meaningCN: '然后',
        sentence: { text: 'I take a shower then.', slots: [{text:'I take',type:'function'},{text:'a shower',type:'content'},{text:'then',type:'connector'}], coreWords:['take','shower'], swapSlotIndex:1, swapOptions:['a bath','a walk','a break'] } },
    ],
  },
  {
    id: 'N', theme: 'Numbers & paying', sceneImage: 'scene_n.png',
    chunks: [
      { id: 'n_howmuch', text: 'How much', type: 'function', meaningCN: '多少钱',
        sentence: { text: 'How much is this.', slots: [{text:'How much',type:'function'},{text:'is this',type:'content'}], coreWords:['how','much'], swapSlotIndex:1, swapOptions:['How many','What price','The total'] } },
      { id: 'n_this', text: 'is this', type: 'content', meaningCN: '这个…',
        sentence: { text: 'How much is this.', slots: [{text:'How much',type:'function'},{text:'is this',type:'content'}], coreWords:['this'], swapSlotIndex:1, swapOptions:['is that','is the book','is the bag'] } },
      { id: 'n_its', text: "It's", type: 'function', meaningCN: '它是…',
        sentence: { text: "It's ten dollars.", slots: [{text:"It's",type:'function'},{text:'ten dollars',type:'content'}], coreWords:['ten','dollars'], swapSlotIndex:1, swapOptions:['twenty','five','free'] } },
      { id: 'n_ten', text: 'ten dollars', type: 'content', meaningCN: '十美元',
        sentence: { text: "It's ten dollars.", slots: [{text:"It's",type:'function'},{text:'ten dollars',type:'content'}], coreWords:['ten','dollars'], swapSlotIndex:1, swapOptions:['twenty','five','free'] } },
      { id: 'n_pay', text: 'Can I pay', type: 'function', meaningCN: '我能付款…吗',
        sentence: { text: 'Can I pay ten dollars.', slots: [{text:'Can I pay',type:'function'},{text:'ten dollars',type:'content'}], coreWords:['pay','dollars'], swapSlotIndex:1, swapOptions:['twenty','five','free'] } },
    ],
  },
  {
    id: 'O', theme: 'Opinions', sceneImage: 'scene_o.png',
    chunks: [
      { id: 'o_think', text: 'I think', type: 'function', meaningCN: '我认为',
        sentence: { text: "I think it's good.", slots: [{text:'I think',type:'function'},{text:"it's good",type:'content'}], coreWords:['think','good'], swapSlotIndex:1, swapOptions:['great','okay','bad'] } },
      { id: 'o_good', text: "it's good", type: 'content', meaningCN: '挺好的',
        sentence: { text: "I think it's good.", slots: [{text:'I think',type:'function'},{text:"it's good",type:'content'}], coreWords:['good'], swapSlotIndex:1, swapOptions:['great','nice','enough'] } },
      { id: 'o_this', text: 'This', type: 'function', meaningCN: '这…',
        sentence: { text: 'This is better.', slots: [{text:'This',type:'function'},{text:'is better',type:'content'}], coreWords:['better'], swapSlotIndex:1, swapOptions:['worse','cheaper','bigger'] } },
      { id: 'o_better', text: 'is better', type: 'content', meaningCN: '更好',
        sentence: { text: 'This is better.', slots: [{text:'This',type:'function'},{text:'is better',type:'content'}], coreWords:['better'], swapSlotIndex:1, swapOptions:['worse','cheaper','bigger'] } },
      { id: 'o_like', text: 'I like', type: 'function', meaningCN: '我喜欢',
        sentence: { text: 'I like This.', slots: [{text:'I like',type:'function'},{text:'This',type:'function'}], coreWords:['like'], swapSlotIndex:1, swapOptions:['that one','both','neither'] } },
    ],
  },
  {
    id: 'P', theme: 'Places', sceneImage: 'scene_p.png',
    chunks: [
      { id: 'p_where', text: 'Where is', type: 'function', meaningCN: '…在哪里',
        sentence: { text: 'Where is the museum.', slots: [{text:'Where is',type:'function'},{text:'the museum',type:'content'}], coreWords:['where','museum'], swapSlotIndex:1, swapOptions:['the park','the lake','the square'] } },
      { id: 'p_museum', text: 'the museum', type: 'content', meaningCN: '博物馆',
        sentence: { text: 'Where is the museum.', slots: [{text:'Where is',type:'function'},{text:'the museum',type:'content'}], coreWords:['museum'], swapSlotIndex:1, swapOptions:['the park','the lake','the square'] } },
      { id: 'p_meet', text: "Let's meet", type: 'function', meaningCN: '我们见面…吧',
        sentence: { text: "Let's meet at the park.", slots: [{text:"Let's meet",type:'function'},{text:'at the park',type:'timeplace'}], coreWords:['meet','park'], swapSlotIndex:1, swapOptions:['at the station','at the mall','at the cafe'] } },
      { id: 'p_park', text: 'at the park', type: 'timeplace', meaningCN: '在公园',
        sentence: { text: "Let's meet at the park.", slots: [{text:"Let's meet",type:'function'},{text:'at the park',type:'timeplace'}], coreWords:['meet','park'], swapSlotIndex:1, swapOptions:['at the station','at the mall','at the cafe'] } },
      { id: 'p_next', text: 'next to', type: 'timeplace', meaningCN: '在…旁边',
        sentence: { text: 'Where is next to the museum.', slots: [{text:'Where is',type:'function'},{text:'next to',type:'timeplace'},{text:'the museum',type:'content'}], coreWords:['next','museum'], swapSlotIndex:1, swapOptions:['behind','across from','far from'] } },
    ],
  },
  {
    id: 'Q', theme: 'Quick responses', sceneImage: 'scene_q.png',
    chunks: [
      { id: 'q_sure', text: 'Sure', type: 'content', meaningCN: '当然',
        sentence: { text: 'Sure, no problem.', slots: [{text:'Sure',type:'content'},{text:'no problem',type:'content'}], coreWords:['sure'], swapSlotIndex:0, swapOptions:['Of course','Definitely','Okay'] } },
      { id: 'q_problem', text: 'no problem', type: 'content', meaningCN: '没问题',
        sentence: { text: 'Sure, no problem.', slots: [{text:'Sure',type:'content'},{text:'no problem',type:'content'}], coreWords:['problem'], swapSlotIndex:1, swapOptions:['my pleasure','anytime','you\'re welcome'] } },
      { id: 'q_see', text: 'I see', type: 'content', meaningCN: '我明白了',
        sentence: { text: 'I see, no problem.', slots: [{text:'I see',type:'content'},{text:'no problem',type:'content'}], coreWords:['see'], swapSlotIndex:0, swapOptions:['Got it','Understand','Right'] } },
      { id: 'q_moment', text: 'Just a moment', type: 'content', meaningCN: '稍等',
        sentence: { text: 'Just a moment, I see.', slots: [{text:'Just a moment',type:'content'},{text:'I see',type:'content'}], coreWords:['moment'], swapSlotIndex:0, swapOptions:['One second','Wait','Hold on'] } },
      { id: 'q_ofcourse', text: 'Of course', type: 'content', meaningCN: '当然',
        sentence: { text: 'Of course, no problem.', slots: [{text:'Of course',type:'content'},{text:'no problem',type:'content'}], coreWords:['of course'], swapSlotIndex:0, swapOptions:['Sure','Definitely','Why not'] } },
    ],
  },
  {
    id: 'R', theme: 'Restaurant', sceneImage: 'scene_r.png',
    chunks: [
      { id: 'r_table', text: 'A table for', type: 'content', meaningCN: '…人桌',
        sentence: { text: 'A table for two.', slots: [{text:'A table for',type:'content'},{text:'two',type:'content'}], coreWords:['table','two'], swapSlotIndex:1, swapOptions:['four','three','one'] } },
      { id: 'r_two', text: 'two', type: 'content', meaningCN: '两个',
        sentence: { text: 'A table for two.', slots: [{text:'A table for',type:'content'},{text:'two',type:'content'}], coreWords:['two'], swapSlotIndex:1, swapOptions:['four','three','one'] } },
      { id: 'r_book', text: "I'd like to book", type: 'function', meaningCN: '我想预订',
        sentence: { text: "I'd like to book the menu.", slots: [{text:"I'd like to book",type:'function'},{text:'the menu',type:'content'}], coreWords:['like','book'], swapSlotIndex:1, swapOptions:['a table for two','the bill','a window seat'] } },
      { id: 'r_menu', text: 'the menu', type: 'content', meaningCN: '菜单',
        sentence: { text: "I'd like to book the menu.", slots: [{text:"I'd like to book",type:'function'},{text:'the menu',type:'content'}], coreWords:['book','menu'], swapSlotIndex:1, swapOptions:['a table for two','the bill','a window seat'] } },
      { id: 'r_recommend', text: 'What do you recommend', type: 'function', meaningCN: '你推荐什么',
        sentence: { text: 'What do you recommend the menu.', slots: [{text:'What do you recommend',type:'function'},{text:'the menu',type:'content'}], coreWords:['recommend','menu'], swapSlotIndex:1, swapOptions:['the wine list','the specials','the bill'] } },
    ],
  },
  {
    id: 'S', theme: 'Shopping', sceneImage: 'scene_s.png',
    chunks: [
      { id: 's_howmuch', text: 'How much is', type: 'function', meaningCN: '…多少钱',
        sentence: { text: 'How much is this shirt.', slots: [{text:'How much is',type:'function'},{text:'this shirt',type:'content'}], coreWords:['how','shirt'], swapSlotIndex:1, swapOptions:['this hat','that bag','these shoes'] } },
      { id: 's_shirt', text: 'this shirt', type: 'content', meaningCN: '这件衬衫',
        sentence: { text: 'How much is this shirt.', slots: [{text:'How much is',type:'function'},{text:'this shirt',type:'content'}], coreWords:['shirt'], swapSlotIndex:1, swapOptions:['this hat','that bag','these shoes'] } },
      { id: 's_looking', text: "I'm just looking", type: 'content', meaningCN: '我只是看看',
        sentence: { text: "I'm just looking in blue.", slots: [{text:"I'm just looking",type:'content'},{text:'in blue',type:'content'}], coreWords:['looking','blue'], swapSlotIndex:1, swapOptions:['in red','in black','in green'] } },
      { id: 's_have', text: 'Do you have', type: 'function', meaningCN: '你们有…吗',
        sentence: { text: 'Do you have this shirt in blue.', slots: [{text:'Do you have',type:'function'},{text:'this shirt',type:'content'},{text:'in blue',type:'content'}], coreWords:['have','shirt','blue'], swapSlotIndex:1, swapOptions:['this hat','that bag','these shoes'] } },
      { id: 's_blue', text: 'in blue', type: 'content', meaningCN: '蓝色的',
        sentence: { text: 'Do you have this shirt in blue.', slots: [{text:'Do you have',type:'function'},{text:'this shirt',type:'content'},{text:'in blue',type:'content'}], coreWords:['blue'], swapSlotIndex:2, swapOptions:['in red','in black','in green'] } },
    ],
  },
  {
    id: 'T', theme: 'Time & plans', sceneImage: 'scene_t.png',
    chunks: [
      { id: 't_whattime', text: 'What time', type: 'function', meaningCN: '几点…',
        sentence: { text: 'What time shall we meet.', slots: [{text:'What time',type:'function'},{text:'shall we meet',type:'function'}], coreWords:['what','meet'], swapSlotIndex:1, swapOptions:['do we leave','is dinner','is the movie'] } },
      { id: 't_meet', text: 'shall we meet', type: 'function', meaningCN: '我们见面',
        sentence: { text: 'What time shall we meet.', slots: [{text:'What time',type:'function'},{text:'shall we meet',type:'function'}], coreWords:['meet'], swapSlotIndex:1, swapOptions:['do we leave','is dinner','is the movie'] } },
      { id: 't_letsmeet', text: "Let's meet", type: 'function', meaningCN: '我们见面…吧',
        sentence: { text: "Let's meet at eight.", slots: [{text:"Let's meet",type:'function'},{text:'at eight',type:'timeplace'}], coreWords:['meet','eight'], swapSlotIndex:1, swapOptions:['at six','at noon','tomorrow'] } },
      { id: 't_eight', text: 'at eight', type: 'timeplace', meaningCN: '在八点',
        sentence: { text: "Let's meet at eight.", slots: [{text:"Let's meet",type:'function'},{text:'at eight',type:'timeplace'}], coreWords:['meet','eight'], swapSlotIndex:1, swapOptions:['at six','at noon','tomorrow'] } },
      { id: 't_free', text: "I'm free", type: 'content', meaningCN: '我有空',
        sentence: { text: "I'm free at eight.", slots: [{text:"I'm free",type:'content'},{text:'at eight',type:'timeplace'}], coreWords:['free','eight'], swapSlotIndex:1, swapOptions:['at six','at noon','tomorrow'] } },
    ],
  },
  {
    id: 'U', theme: 'Understanding', sceneImage: 'scene_u.png',
    chunks: [
      { id: 'u_sorry', text: 'Sorry', type: 'function', meaningCN: '抱歉',
        sentence: { text: 'Sorry, can you repeat.', slots: [{text:'Sorry',type:'function'},{text:'can you repeat',type:'function'}], coreWords:['sorry','repeat'], swapSlotIndex:1, swapOptions:['Excuse me','Pardon','Wait'] } },
      { id: 'u_repeat', text: 'can you repeat', type: 'function', meaningCN: '你能重复吗',
        sentence: { text: 'Sorry, can you repeat.', slots: [{text:'Sorry',type:'function'},{text:'can you repeat',type:'function'}], coreWords:['repeat'], swapSlotIndex:1, swapOptions:['say that again','spell it','explain'] } },
      { id: 'u_dont', text: "I don't", type: 'function', meaningCN: '我不…',
        sentence: { text: "I don't understand.", slots: [{text:"I don't",type:'function'},{text:'understand',type:'content'}], coreWords:['understand'], swapSlotIndex:1, swapOptions:['know','follow','get it'] } },
      { id: 'u_understand', text: 'understand', type: 'content', meaningCN: '明白',
        sentence: { text: "I don't understand.", slots: [{text:"I don't",type:'function'},{text:'understand',type:'content'}], coreWords:['understand'], swapSlotIndex:1, swapOptions:['know','follow','get it'] } },
      { id: 'u_write', text: 'Could you write', type: 'function', meaningCN: '你能写下来吗',
        sentence: { text: 'Sorry, Could you write.', slots: [{text:'Sorry',type:'function'},{text:'Could you write',type:'function'}], coreWords:['write'], swapSlotIndex:1, swapOptions:['show me','spell it','point to it'] } },
    ],
  },
  {
    id: 'V', theme: 'Weekend vibes', sceneImage: 'scene_v.png',
    chunks: [
      { id: 'v_doing', text: 'What are you doing', type: 'function', meaningCN: '你在做什么',
        sentence: { text: 'What are you doing this weekend.', slots: [{text:'What are you doing',type:'function'},{text:'this weekend',type:'timeplace'}], coreWords:['doing','weekend'], swapSlotIndex:1, swapOptions:['tonight','tomorrow','on holiday'] } },
      { id: 'v_weekend', text: 'this weekend', type: 'timeplace', meaningCN: '这个周末',
        sentence: { text: 'What are you doing this weekend.', slots: [{text:'What are you doing',type:'function'},{text:'this weekend',type:'timeplace'}], coreWords:['weekend'], swapSlotIndex:1, swapOptions:['tonight','tomorrow','on holiday'] } },
      { id: 'v_going', text: "I'm going", type: 'function', meaningCN: '我要去',
        sentence: { text: "I'm going to the beach.", slots: [{text:"I'm going",type:'function'},{text:'to the beach',type:'content'}], coreWords:['going','beach'], swapSlotIndex:1, swapOptions:['to a party','hiking','shopping'] } },
      { id: 'v_beach', text: 'to the beach', type: 'content', meaningCN: '去海滩',
        sentence: { text: "I'm going to the beach.", slots: [{text:"I'm going",type:'function'},{text:'to the beach',type:'content'}], coreWords:['beach'], swapSlotIndex:1, swapOptions:['to the park','home','out'] } },
      { id: 'v_hang', text: "Let's hang out", type: 'content', meaningCN: '我们聚聚吧',
        sentence: { text: "Let's hang out this weekend.", slots: [{text:"Let's hang out",type:'content'},{text:'this weekend',type:'timeplace'}], coreWords:['hang','weekend'], swapSlotIndex:1, swapOptions:['tonight','tomorrow','after work'] } },
    ],
  },
  {
    id: 'W', theme: 'Weather', sceneImage: 'scene_w.png',
    chunks: [
      { id: 'w_its', text: "It's", type: 'function', meaningCN: '它是…',
        sentence: { text: "It's sunny today.", slots: [{text:"It's",type:'function'},{text:'sunny',type:'content'},{text:'today',type:'timeplace'}], coreWords:['sunny','today'], swapSlotIndex:1, swapOptions:['rainy','cold','hot'] } },
      { id: 'w_sunny', text: 'sunny', type: 'content', meaningCN: '晴天',
        sentence: { text: "It's sunny today.", slots: [{text:"It's",type:'function'},{text:'sunny',type:'content'},{text:'today',type:'timeplace'}], coreWords:['sunny'], swapSlotIndex:1, swapOptions:['rainy','cold','hot'] } },
      { id: 'w_today', text: 'today', type: 'timeplace', meaningCN: '今天',
        sentence: { text: "It's sunny today.", slots: [{text:"It's",type:'function'},{text:'sunny',type:'content'},{text:'today',type:'timeplace'}], coreWords:['today'], swapSlotIndex:1, swapOptions:['tomorrow','tonight','this week'] } },
      { id: 'w_how', text: "How's the weather", type: 'function', meaningCN: '天气怎样',
        sentence: { text: "How's the weather today.", slots: [{text:"How's the weather",type:'function'},{text:'today',type:'timeplace'}], coreWords:['weather'], swapSlotIndex:1, swapOptions:['tomorrow','tonight','this week'] } },
      { id: 'w_cold', text: 'cold', type: 'content', meaningCN: '冷',
        sentence: { text: "It's cold today.", slots: [{text:"It's",type:'function'},{text:'cold',type:'content'},{text:'today',type:'timeplace'}], coreWords:['cold','today'], swapSlotIndex:1, swapOptions:['warm','windy','snowing'] } },
    ],
  },
  {
    id: 'X', theme: 'eXclamations', sceneImage: 'scene_x.png',
    chunks: [
      { id: 'x_wow', text: 'Wow', type: 'content', meaningCN: '哇',
        sentence: { text: "Wow, that's amazing.", slots: [{text:'Wow',type:'content'},{text:"that's amazing",type:'content'}], coreWords:['wow'], swapSlotIndex:0, swapOptions:['Cool','Nice','Great'] } },
      { id: 'x_amazing', text: "that's amazing", type: 'content', meaningCN: '太棒了',
        sentence: { text: "Wow, that's amazing.", slots: [{text:'Wow',type:'content'},{text:"that's amazing",type:'content'}], coreWords:['amazing'], swapSlotIndex:1, swapOptions:['great','cool','awesome'] } },
      { id: 'x_ohno', text: 'Oh no', type: 'content', meaningCN: '噢不',
        sentence: { text: "Oh no, it's broken.", slots: [{text:'Oh no',type:'content'},{text:"it's broken",type:'content'}], coreWords:['oh no'], swapSlotIndex:0, swapOptions:['Oops','Uh oh','Damn'] } },
      { id: 'x_broken', text: "it's broken", type: 'content', meaningCN: '坏了',
        sentence: { text: "Oh no, it's broken.", slots: [{text:'Oh no',type:'content'},{text:"it's broken",type:'content'}], coreWords:['broken'], swapSlotIndex:1, swapOptions:['lost','late','wrong'] } },
      { id: 'x_birthday', text: 'Happy birthday', type: 'content', meaningCN: '生日快乐',
        sentence: { text: 'Wow, Happy birthday.', slots: [{text:'Wow',type:'content'},{text:'Happy birthday',type:'content'}], coreWords:['happy','birthday'], swapSlotIndex:1, swapOptions:['New Year','anniversary','holidays'] } },
    ],
  },
  {
    id: 'Y', theme: 'Yes & no', sceneImage: 'scene_y.png',
    chunks: [
      { id: 'y_yes', text: 'Yes', type: 'content', meaningCN: '是的',
        sentence: { text: 'Yes, please.', slots: [{text:'Yes',type:'content'},{text:'please',type:'function'}], coreWords:['yes'], swapSlotIndex:0, swapOptions:['Sure','Okay','Why not'] } },
      { id: 'y_please', text: 'please', type: 'function', meaningCN: '请',
        sentence: { text: 'Yes, please.', slots: [{text:'Yes',type:'content'},{text:'please',type:'function'}], coreWords:['please'], swapSlotIndex:0, swapOptions:['No','Maybe','Sure'] } },
      { id: 'y_no', text: 'No', type: 'content', meaningCN: '不',
        sentence: { text: 'No, thanks.', slots: [{text:'No',type:'content'},{text:'thanks',type:'function'}], coreWords:['no'], swapSlotIndex:0, swapOptions:['Sure','Maybe','Okay'] } },
      { id: 'y_thanks', text: 'thanks', type: 'function', meaningCN: '谢谢',
        sentence: { text: 'No, thanks.', slots: [{text:'No',type:'content'},{text:'thanks',type:'function'}], coreWords:['thanks'], swapSlotIndex:0, swapOptions:['Yes','Maybe','Sure'] } },
      { id: 'y_agree', text: 'I agree', type: 'content', meaningCN: '我同意',
        sentence: { text: 'Yes, I agree.', slots: [{text:'Yes',type:'content'},{text:'I agree',type:'content'}], coreWords:['agree'], swapSlotIndex:1, swapOptions:['disagree','think so','don\'t think so'] } },
    ],
  },
  {
    id: 'Zzz', theme: 'Sleep & rest', sceneImage: 'scene_sleep.png',
    chunks: [
      { id: 'z_im', text: "I'm", type: 'function', meaningCN: '我是…',
        sentence: { text: "I'm sleepy.", slots: [{text:"I'm",type:'function'},{text:'sleepy',type:'content'}], coreWords:['sleepy'], swapSlotIndex:1, swapOptions:['tired','awake','dizzy'] } },
      { id: 'z_sleepy', text: 'sleepy', type: 'content', meaningCN: '困',
        sentence: { text: "I'm sleepy.", slots: [{text:"I'm",type:'function'},{text:'sleepy',type:'content'}], coreWords:['sleepy'], swapSlotIndex:1, swapOptions:['tired','awake','dizzy'] } },
      { id: 'z_night', text: 'Good night', type: 'content', meaningCN: '晚安',
        sentence: { text: "I'm Good night.", slots: [{text:"I'm",type:'function'},{text:'Good night',type:'content'}], coreWords:['good','night'], swapSlotIndex:1, swapOptions:['morning','bye','rest'] } },
      { id: 'z_sleep', text: 'I need to sleep', type: 'content', meaningCN: '我需要睡',
        sentence: { text: 'I need to sleep the light.', slots: [{text:'I need to sleep',type:'content'},{text:'the light',type:'content'}], coreWords:['need','sleep'], swapSlotIndex:1, swapOptions:['to rest','to lie down','to close my eyes'] } },
      { id: 'z_turn', text: 'Turn off', type: 'function', meaningCN: '关掉…',
        sentence: { text: 'Turn off the light.', slots: [{text:'Turn off',type:'function'},{text:'the light',type:'content'}], coreWords:['turn','light'], swapSlotIndex:1, swapOptions:['on','down','up'] } },
      { id: 'z_light', text: 'the light', type: 'content', meaningCN: '灯',
        sentence: { text: 'Turn off the light.', slots: [{text:'Turn off',type:'function'},{text:'the light',type:'content'}], coreWords:['light'], swapSlotIndex:1, swapOptions:['the tv','the music','the fan'] } },
    ],
  },
];

// ---- 校验 ----
const errors = [];
const pack = { version: '1.0.0', levels: LEVELS };
for (const lv of LEVELS) {
  const chunkTexts = new Set(lv.chunks.map(c => c.text));
  const idSet = new Set();
  for (const c of lv.chunks) {
    if (idSet.has(c.id)) errors.push(`[${lv.id}] 重复 chunk id: ${c.id}`);
    idSet.add(c.id);
    for (const s of c.sentence.slots) {
      if (!chunkTexts.has(s.text)) errors.push(`[${lv.id}/${c.id}] slot "${s.text}" 不是本关词块`);
    }
    const joined = c.sentence.slots.map(s => s.text).join(' ');
    const norm = s => s.toLowerCase().replace(/[.,!?]/g, '').replace(/\s+/g, ' ').trim();
    if (norm(c.sentence.text) !== norm(joined)) {
      errors.push(`[${lv.id}/${c.id}] 句子与 slots 不一致: "${c.sentence.text}" vs "${joined}"`);
    }
    if (c.sentence.swapSlotIndex < 0 || c.sentence.swapSlotIndex >= c.sentence.slots.length) {
      errors.push(`[${lv.id}/${c.id}] swapSlotIndex 越界: ${c.sentence.swapSlotIndex}`);
    }
    if (!Array.isArray(c.sentence.swapOptions) || c.sentence.swapOptions.length < 2) {
      errors.push(`[${lv.id}/${c.id}] swapOptions 不足 2 项`);
    }
  }
  if (lv.chunks.length < 4 || lv.chunks.length > 6) errors.push(`[${lv.id}] 词块数 ${lv.chunks.length} 不在 4-6`);
}
if (errors.length) {
  console.log('校验失败：'); errors.forEach(e => console.log('  - ' + e)); process.exit(1);
}
console.log(`校验通过：${LEVELS.length} 关，共 ${LEVELS.reduce((a,l)=>a+l.chunks.length,0)} 词块`);

// ---- 输出 JSON ----
fs.writeFileSync('content_pack.json', JSON.stringify(pack, null, 2), 'utf8');

// ---- 输出内容总表（纯文本，供审校）----
let md = '# ChunkSpoke v2.0 内容总表（Phase 0 审校稿）\n\n';
md += `> 共 ${LEVELS.length} 关，每关 4-6 词块；每词块绑定 1 句可说出口的完整句（句子由本关词块纯拼接）。\n`;
md += `> 词块类型：content 内容 / function 功能 / connector 连接 / timeplace 时间地点（对应 UI 四色双重编码）。\n\n`;
for (const lv of LEVELS) {
  md += `## ${lv.id} · ${lv.theme}\n\n`;
  md += `| # | 词块 | 类型 | 中文 | 绑定句 | 核心词(coreWords) | 可替换槽(swap) | 替换项 |\n`;
  md += `|---|---|---|---|---|---|---|---|\n`;
  lv.chunks.forEach((c, i) => {
    const sw = c.sentence.slots[c.sentence.swapSlotIndex];
    md += `| ${i+1} | ${c.text} | ${c.type} | ${c.meaningCN} | ${c.sentence.text} | ${c.sentence.coreWords.join(', ')} | ${sw ? sw.text : '-'} | ${c.sentence.swapOptions.join(' / ')} |\n`;
  });
  md += `\n`;
}
fs.writeFileSync('content_table.md', md, 'utf8');
console.log('已生成 content_pack.json 与 content_table.md');
