/// 场景中文名映射（单一来源：map.dart / level.dart / widgets.dart 共用）。
/// 主标题统一中文，英文 theme 仅作副标题小字。
const Map<String, String> _sceneCN = {
  'Asking for things': '索取东西',
  'Breakfast': '早餐',
  'Coffee & Cafe': '咖啡馆',
  'Directions': '问路',
  'Eating out': '外出就餐',
  'Feelings': '情绪表达',
  'Greetings': '打招呼',
  'Home & Hotel': '住宿·酒店',
  'Invitations': '邀请',
  'Just checking': '确认一下',
  'Kind requests': '委婉请求',
  "Let's go": '出发吧',
  'Morning routine': '晨间日常',
  'Numbers & paying': '数字与付款',
  'Opinions': '表达看法',
  'Places': '地点',
  'Quick responses': '快速回应',
  'Restaurant': '餐厅点餐',
  'Shopping': '购物',
  'Time & plans': '时间与计划',
  'Understanding': '听懂对方',
  'Weekend vibes': '周末时光',
  'Weather': '天气',
  'eXclamations': '感叹语',
  'Yes & no': '是与否',
  'Sleep & rest': '睡眠与休息',
};

String sceneCn(String theme) => _sceneCN[theme] ?? theme;
