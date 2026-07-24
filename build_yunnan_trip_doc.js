const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  Header, Footer, AlignmentType, WidthType, BorderStyle, ShadingType,
  VerticalAlign, PageNumber, PageBreak, HeadingLevel, LevelFormat,
} = require('docx');

const OUT_DIR = path.join(__dirname, 'travel_plan_output');
const OUT_FILE = path.join(OUT_DIR, '云南家庭旅行计划_2026年8月8日至15日.docx');
fs.mkdirSync(OUT_DIR, { recursive: true });

// Design preset: compact_reference_guide.
// Named override: Microsoft YaHei is used for reliable Chinese rendering.
const FONT = 'Microsoft YaHei';
const BLUE = '2E74B5';
const DARK_BLUE = '1F4D78';
const NAVY = '0B2545';
const MUTED = '5B6573';
const LIGHT_BLUE = 'E8EEF5';
const LIGHT_GRAY = 'F4F6F9';
const CAUTION = 'FFF5E5';
const RED_FILL = 'FBEAEC';
const GREEN_FILL = 'EEF6F1';
const CONTENT_WIDTH = 9360;
const THIN = { style: BorderStyle.SINGLE, size: 4, color: 'D5DCE5' };
const GRID = { top: THIN, bottom: THIN, left: THIN, right: THIN, insideHorizontal: THIN, insideVertical: THIN };

function run(text, opts = {}) {
  return new TextRun({
    text,
    font: FONT,
    size: opts.size || 22,
    color: opts.color || '1F2937',
    bold: opts.bold || false,
    italics: opts.italics || false,
    break: opts.break,
  });
}

function p(textOrChildren, opts = {}) {
  const children = Array.isArray(textOrChildren) ? textOrChildren : [run(textOrChildren, opts.run || {})];
  return new Paragraph({
    children,
    alignment: opts.alignment || AlignmentType.LEFT,
    style: opts.style,
    keepNext: opts.keepNext || false,
    pageBreakBefore: opts.pageBreakBefore || false,
    spacing: opts.spacing || { after: 120, line: 300 },
    border: opts.border,
  });
}

function bullet(text, level = 0) {
  return new Paragraph({
    children: [run(text)],
    numbering: { reference: 'bullets', level },
    spacing: { after: 80, line: 300 },
  });
}

function numbered(text, level = 0) {
  return new Paragraph({
    children: [run(text)],
    numbering: { reference: 'numbers', level },
    spacing: { after: 80, line: 300 },
  });
}

function cell(text, width, opts = {}) {
  const textChildren = Array.isArray(text) ? text : [p(text, {
    alignment: opts.align || AlignmentType.LEFT,
    spacing: { after: 0, line: 280 },
    run: { size: opts.size || 20, color: opts.color || '1F2937', bold: opts.bold || false },
  })];
  return new TableCell({
    children: textChildren,
    width: { size: width, type: WidthType.DXA },
    borders: opts.borders || GRID,
    shading: opts.fill ? { fill: opts.fill, type: ShadingType.CLEAR } : undefined,
    margins: { top: 95, bottom: 95, left: 120, right: 120 },
    verticalAlign: VerticalAlign.CENTER,
  });
}

function table(headers, rows, widths, opts = {}) {
  const headerRow = new TableRow({
    tableHeader: true,
    children: headers.map((h, i) => cell(h, widths[i], { fill: opts.headerFill || LIGHT_BLUE, bold: true, color: NAVY, align: AlignmentType.CENTER, size: 19 })),
  });
  const bodyRows = rows.map((row, ri) => new TableRow({
    children: row.map((v, i) => cell(v, widths[i], {
      fill: opts.zebra && ri % 2 === 1 ? 'FAFBFC' : undefined,
      align: opts.centerCols && opts.centerCols.includes(i) ? AlignmentType.CENTER : AlignmentType.LEFT,
      size: opts.fontSize || 19,
    })),
  }));
  return new Table({
    width: { size: CONTENT_WIDTH, type: WidthType.DXA },
    columnWidths: widths,
    indent: { size: 120, type: WidthType.DXA },
    borders: GRID,
    rows: [headerRow, ...bodyRows],
  });
}

function callout(label, text, fill = LIGHT_GRAY) {
  return new Table({
    width: { size: CONTENT_WIDTH, type: WidthType.DXA },
    columnWidths: [1550, 7810],
    indent: { size: 120, type: WidthType.DXA },
    borders: GRID,
    rows: [new TableRow({
      children: [
        cell(label, 1550, { fill, bold: true, color: NAVY, align: AlignmentType.CENTER, size: 20 }),
        cell(text, 7810, { fill, size: 20 }),
      ],
    })],
  });
}

const itinerary = [
  ['8/8 周六', '南京 → 昆明 → 大理', '19:30 抵达长水机场。预留至少 75 分钟转场，乘晚间动车至大理；到店后只洗漱休息。', '大理（第1晚）'],
  ['8/9 周日', '苍山', '感通索道上山，玉带路短徒步 1-1.5 小时；下午回酒店休息，不安排夜游古城。', '大理（第2晚）'],
  ['8/10 周一', '洱海环湖 → 丽江', '7座车环洱海看景：喜洲、海舌、双廊、海东；行李放车内，傍晚司机直接送大理站，动车到丽江。', '丽江（第1晚）'],
  ['8/11 周二', '玉龙雪山', '全天：冰川公园大索道、蓝月谷。父母以索道与低强度观景为主；晚上回丽江休息。', '丽江（第2晚）'],
  ['8/12 周三', '丽江 → 香格里拉 → 普达措', '早班动车到香格里拉。7座车接站，放行李后去普达措：属都湖短栈道、弥里塘草甸；晚上早休息。', '香格里拉（第1晚）'],
  ['8/13 周四', '巴拉格宗', '全天7座车往返。峡谷、雪峰、巴拉村；父母走观景台/短步道，年轻人视天气与体力走开放徒步段。', '香格里拉（第2晚）'],
  ['8/14 周五', '香格里拉 → 昆明', '早班动车回昆明，入住长水机场附近酒店。昆明仅作返程缓冲，不强行打卡。', '昆明机场（第1晚）'],
  ['8/15 周六', '昆明 → 南京', '13:45 起飞。建议 10:45 前到机场，留出值机、托运与安检时间。', '—'],
];

const doc = new Document({
  creator: 'Codex',
  title: '云南家庭旅行计划（2026年8月8日至15日）',
  description: '昆明、大理、丽江、香格里拉七晚八天家庭旅行计划',
  styles: {
    default: { document: { run: { font: FONT, size: 22, color: '1F2937' } } },
    paragraphStyles: [
      {
        id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: FONT, size: 32, bold: true, color: BLUE },
        paragraph: { spacing: { before: 360, after: 200, line: 300 }, outlineLevel: 0, keepNext: true },
      },
      {
        id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: FONT, size: 26, bold: true, color: BLUE },
        paragraph: { spacing: { before: 280, after: 140, line: 300 }, outlineLevel: 1, keepNext: true },
      },
      {
        id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: FONT, size: 24, bold: true, color: DARK_BLUE },
        paragraph: { spacing: { before: 200, after: 100, line: 300 }, outlineLevel: 2, keepNext: true },
      },
    ],
  },
  numbering: {
    config: [
      { reference: 'bullets', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 270 }, spacing: { after: 80, line: 300 } } } }] },
      { reference: 'numbers', levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 270 }, spacing: { after: 80, line: 300 } } } }] },
    ],
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 1440, right: 1440, bottom: 1440, left: 1440, header: 709, footer: 709 },
      },
    },
    headers: {
      default: new Header({ children: [p([
        run('Kong 家庭 | 云南旅行计划', { size: 17, color: MUTED }),
        run('\t2026.08.08 - 08.15', { size: 17, color: MUTED }),
      ], { tabStops: [{ type: 'right', position: 9360 }], spacing: { after: 80 }, border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'D7DBE2', space: 1 } } })] }),
    },
    footers: {
      default: new Footer({ children: [p([
        run('家庭旅行手册', { size: 16, color: MUTED }),
        run('\t第 ', { size: 16, color: MUTED }),
        new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: MUTED }),
        run(' 页', { size: 16, color: MUTED }),
      ], { tabStops: [{ type: 'right', position: 9360 }], alignment: AlignmentType.LEFT, spacing: { before: 80 } })] }),
    },
    children: [
      p('家庭旅行计划', { alignment: AlignmentType.CENTER, spacing: { before: 480, after: 110 }, run: { size: 54, bold: true, color: NAVY } }),
      p('云南 | 大理 · 丽江 · 香格里拉', { alignment: AlignmentType.CENTER, spacing: { after: 110 }, run: { size: 30, color: DARK_BLUE } }),
      p('2026 年 8 月 8 日 - 8 月 15 日  |  四人同行：父母、22岁、14岁', { alignment: AlignmentType.CENTER, spacing: { after: 320 }, run: { size: 20, color: MUTED } }),
      callout('行程定位', '以苍山洱海、玉龙雪山和香格里拉自然风景为主。保留必要的转场，但不安排商业化古城打卡；香格里拉先轻后重，降低高反与疲劳风险。', GREEN_FILL),
      p('', { spacing: { after: 120 } }),
      table(['已确定交通', '建议'], [
        ['8/8 19:30 抵达昆明', '以晚班昆明→大理动车为主；落地后直接转车站，不在昆明住宿。'],
        ['8/15 13:45 昆明→南京', '8/14 从香格里拉坐早班高铁回昆明，机场附近住宿，作为返程安全垫。'],
      ], [2600, 6760], { zebra: true, fontSize: 19 }),
      p('', { spacing: { after: 100 } }),
      p('先订什么', { style: 'Heading2' }),
      numbered('酒店与包车：现在优先锁定，暑期周末和高原品质酒店价格波动最大。'),
      numbered('玉龙雪山冰川公园索道：以官方小程序的实际放票规则为准，先抢索道再锁定当天行程。'),
      numbered('动车：请通过 12306 购票；8月8日的晚间昆明→大理需以开售后的实际运行图为准。'),

      p('一、全程行程总览', { style: 'Heading1', pageBreakBefore: true }),
      table(['日期', '核心安排', '当天节奏', '住宿'], itinerary, [1200, 2100, 4450, 1610], { zebra: true, fontSize: 18, centerCols: [0, 3] }),
      p('节奏说明：8月10日晚移至丽江，使8月11日可以完整游玉龙雪山；8月12日安排更容易收缩的普达措，8月13日留给耗时更长的巴拉格宗。', { spacing: { before: 120, after: 120 }, run: { size: 19, color: MUTED, italics: true } }),

      p('二、每日详细安排', { style: 'Heading1', pageBreakBefore: true }),
      p('8月8日（周六）｜南京 - 昆明 - 大理', { style: 'Heading2' }),
      p('目标是当晚抵达大理睡觉，而不是游览昆明。请在出发前把昆明机场到火车站的接送、晚班动车和大理酒店确认好。', { spacing: { after: 80 } }),
      bullet('落地后：取行李、前往车站、安检。建议为转乘预留不少于75分钟；托运行李或航班晚点时更要留余量。'),
      bullet('如没有合适晚班、或航班明显延误：优先改签/退票并住昆明，安全比硬赶车更重要；次日早班转大理将影响行程，需要及时调整。'),
      bullet('酒店：选可晚到办理入住、车能停到门口、能提供简单早餐的舒适型酒店。'),

      p('8月9日（周日）｜苍山：索道上山，轻徒步看洱海', { style: 'Heading2' }),
      bullet('上午晚一点出发：酒店打车至感通索道，乘索道上山。'),
      bullet('徒步只走玉带路平缓的一小段，控制在1-1.5小时；穿防滑运动鞋，雨天不走湿滑岔路。'),
      bullet('下午：下山后回酒店午休、洗衣或在湖边安静喝咖啡。不要再加古城夜游。'),
      callout('当天用车', '不包全天车。酒店 - 感通索道往返打车即可。', LIGHT_BLUE),

      p('8月10日（周一）｜洱海环湖看景，傍晚转丽江', { style: 'Heading2' }),
      bullet('08:30 左右：7座商务车从酒店接人，行李全程放车内。'),
      bullet('推荐顺序：龙龛/才村 - 喜洲 - 海舌生态公园 - 双廊 - 海东观景点 - 大理站。每处只挑1-2个停留点，避免“下车5分钟式”打卡。'),
      bullet('傍晚：司机直接送大理站，乘晚班动车至丽江。入住后只吃晚饭、休息。'),
      callout('当天用车', '建议全天包7座商务车，并在订单中写明“酒店接、行李随车、晚间送大理站、纯玩无购物”。', LIGHT_BLUE),

      p('8月11日（周二）｜玉龙雪山：冰川公园与蓝月谷', { style: 'Heading2' }),
      bullet('早上按冰川公园大索道预约时间出发；酒店送山或预约滴滴即可，不需要全天包车。'),
      bullet('父母：索道上山后以观景、慢走、拍照为主，若头痛、胸闷、明显乏力，立即下撤。'),
      bullet('你和妹妹：身体状态良好再向4680米栈道高处走，绝不比赛登高。'),
      bullet('下午：蓝月谷；下山后回酒店休息。高原段不饮酒、不熬夜。'),
      callout('重要提示', '冰川公园索道是本趟最需要提前锁定的资源。没抢到时，备选为云杉坪 + 蓝月谷，不临时高价找黄牛。', CAUTION),

      p('8月12日（周三）｜丽江 - 香格里拉 - 普达措', { style: 'Heading2' }),
      bullet('早班动车丽江至香格里拉；同一辆7座商务车在车站接站，先到酒店寄放行李。'),
      bullet('中午后去普达措：属都湖短栈道、弥里塘草甸为主，不走完整长线。'),
      bullet('傍晚回独克宗外围酒店，简单晚餐、补水、早休息，给次日巴拉格宗留体力。'),
      callout('当天用车', '香格里拉两天直接订同一车队最省心：第1天站接 + 普达措 + 酒店；第2天巴拉格宗全天。', LIGHT_BLUE),

      p('8月13日（周四）｜巴拉格宗：完整留给峡谷与徒步', { style: 'Heading2' }),
      bullet('早出发，市区往返与景区游览基本占满全天。车上准备雨衣、水、零食、保暖层。'),
      bullet('父母走景区观光车、观景台与短步道；年轻人仅在天气、体力和景区开放条件允许时追加徒步。'),
      bullet('不走未开发路线，不为“拍照”离开景区开放步道。若雨势大或道路提示风险，改为降低活动强度。'),

      p('8月14日（周五）｜香格里拉 - 昆明：返程缓冲日', { style: 'Heading2' }),
      bullet('坐早班高铁回昆明，抵达后直接入住长水机场附近酒店。'),
      bullet('昆明仅作可选半日：如精力好可吃饭、买伴手礼；不建议专程跑远景点。'),
      bullet('晚上整理行李，把次日证件、充电器、药物和登机随身物品单独放好。'),

      p('8月15日（周六）｜昆明 - 南京', { style: 'Heading2' }),
      bullet('13:45起飞，建议10:45前抵达机场。早餐后从容退房，不安排任何景点。'),

      p('三、住宿与用车建议', { style: 'Heading1', pageBreakBefore: true }),
      table(['城市 / 晚数', '建议区域', '家庭订房标准', '两间房含早参考'], [
        ['大理 / 2晚', '感通索道或大理古城外围主路', '安静、车能到门口、有电梯或低楼层；不追求古城内位置。', '¥1,800-2,800'],
        ['丽江 / 2晚', '束河北门外或白沙方向', '便于次日去玉龙雪山；避免古城深巷石板路拖行李。', '¥1,800-3,000'],
        ['香格里拉 / 2晚', '独克宗北门/东门外围', '正规酒店优先：供氧、地暖/稳定热水、早餐、车可直达。', '¥2,200-3,600'],
        ['昆明 / 1晚', '长水机场附近', '品牌酒店或接送机稳定的酒店，方便次日返程。', '¥800-1,300'],
      ], [1500, 2200, 3760, 1900], { zebra: true, fontSize: 18, centerCols: [0, 3] }),
      p('住宿预算上调建议：暑期不要按淡季民宿价预订。建议把两间房7晚的实际预算按 ¥8,000-10,700 留足；若偏好湖景、品质连锁或更大套房，预留到 ¥12,000 更稳。', { spacing: { before: 120, after: 120 }, run: { size: 20, color: NAVY, bold: true } }),
      table(['日期', '车辆安排', '是否包车', '备注'], [
        ['8/9', '酒店 ↔ 感通索道', '否', '打车/酒店代叫。'],
        ['8/10', '洱海环湖 → 大理站', '是，全天7座', '行李随车，终点直接是车站。'],
        ['8/11', '丽江酒店 ↔ 玉龙雪山', '否', '酒店接送或预约打车；按索道时间抵达。'],
        ['8/12-13', '香格里拉站/酒店 ↔ 普达措、巴拉格宗', '是，两天7座', '最好同一车队，写清两天路线、等待与费用。'],
      ], [1200, 3300, 1800, 3060], { zebra: true, fontSize: 18, centerCols: [0, 2] }),

      p('四、全流程预算（不含已购机票）', { style: 'Heading1', pageBreakBefore: true }),
      callout('推荐准备金额', '四人合计建议准备 ¥22,000-26,000，不含已购买的往返机票、购物和个人伴手礼。这个区间已按暑期提升后的酒店预算预留。', GREEN_FILL),
      p('', { spacing: { after: 80 } }),
      table(['类别', '预算（四人）', '计算口径'], [
        ['住宿', '¥8,000-10,700', '两间房、7晚、含早为主；建议预留至¥12,000应对湖景/高品质房。'],
        ['四段动车', '约¥2,300-2,500', '昆明→大理、大理→丽江、丽江→香格里拉、香格里拉→昆明；按全价二等座预留。'],
        ['包车 + 市内接送', '¥3,000-4,200', '洱海全天7座；香格里拉两天7座；机场、车站、苍山、玉龙打车。'],
        ['门票与景交', '¥2,700-3,400', '苍山、玉龙雪山、普达措、巴拉格宗；香巴拉佛塔等可选项目另有费用。'],
        ['餐饮与零食', '¥4,000-5,500', '酒店早餐为主；午晚餐、咖啡、水果、补给。'],
        ['保险 / 雨具 / 氧气 / 杂费', '¥700-1,000', '每人短期旅行意外险、雨具、应急补给。'],
        ['总计', '¥20,700-27,300', '建议实际资金准备¥22,000-26,000，留出价格波动缓冲。'],
      ], [2100, 2050, 5210], { zebra: true, fontSize: 18, centerCols: [1] }),
      p('价格提示：玉龙雪山冰川公园的基础组合通常按“门票 + 大索道 + 环保车”预留；普达措按门票与观光车联票预留；巴拉格宗的佛塔接驳属于可选消费。所有价格以购票当天景区和平台页面为准。', { spacing: { before: 120, after: 120 }, run: { size: 18, color: MUTED, italics: true } }),

      p('五、关键注意事项与行前清单', { style: 'Heading1', pageBreakBefore: true }),
      p('高原与健康', { style: 'Heading2' }),
      bullet('香格里拉海拔高，抵达当天和玉龙雪山当天都不要饮酒、熬夜或剧烈运动。'),
      bullet('出现持续头痛、恶心、明显乏力、胸闷或气短时，停止徒步，休息并及时寻求景区医疗点或就医。已有心肺疾病、高血压控制不佳者应在出行前咨询医生。'),
      bullet('氧气瓶可以作为应急用品，不是“边吸氧边继续硬走”的许可。'),
      p('8月雨季与衣物', { style: 'Heading2' }),
      bullet('每人：防水外层、保暖中层、长裤、防滑运动鞋、遮阳帽、墨镜、防晒霜。玉龙雪山与巴拉格宗早晚温差大。'),
      bullet('随身小包：雨衣、充电宝、纸巾、少量高热量零食、水、常用药。雨伞可带，但山地步道优先用雨衣。'),
      bullet('遇到强降雨、雷电或景区临时管制：服从安排，立刻把徒步改为观景和休息。'),
      p('票务与包车核验', { style: 'Heading2' }),
      bullet('动车只通过12306购买；每段车票确认“出发站、到达站、日期、乘车人证件”无误。'),
      bullet('玉龙雪山先确认冰川公园索道预约成功，再安排酒店接送。'),
      bullet('包车订单写明：7座商务车、4人4行李箱、纯玩无购物、包含/不包含的油费过路费停车费、超时费、司机姓名与车牌。'),
      bullet('不要通过陌生社交账号私下付全款；优先用有订单和售后保障的平台，或酒店确认的正规车队。'),
      p('出发前48小时核对清单', { style: 'Heading2' }),
      numbered('检查天气、道路和景区公告；雨天优先调整巴拉格宗与普达措的先后。'),
      numbered('把各酒店、司机、铁路订单、索道预约截图存到手机并备份给另一位家人。'),
      numbered('确认每段接送的集合点；尤其是8月8日晚昆明机场转动车、8月10日晚大理站、8月12日香格里拉站。'),
      numbered('准备身份证、学生证/优惠证件（如有）、充电线、充电宝、医保/保险信息和常用药。'),

      p('六、最终确认清单', { style: 'Heading1', pageBreakBefore: true }),
      table(['优先级', '需要确认的事项', '建议完成时间'], [
        ['最高', '8/8 晚昆明→大理动车：确认航班落地后的转乘时间是否充足。', '动车开售当天'],
        ['最高', '玉龙雪山冰川公园索道预约。', '按官方放票时间'],
        ['高', '大理2晚、丽江2晚、香格里拉2晚、昆明机场1晚的酒店。', '尽快'],
        ['高', '洱海全天7座车；香格里拉两天7座车。', '酒店确定后'],
        ['中', '四段动车的座位、接送点和行李安排。', '动车开售当天'],
        ['中', '旅行保险、雨具、常用药、保暖层。', '出发前3天'],
      ], [1100, 5800, 2460], { zebra: true, fontSize: 19, centerCols: [0, 2] }),
      p('', { spacing: { after: 120 } }),
      callout('给家人的一句话', '这趟旅行的关键不是多打卡，而是把苍山洱海、玉龙雪山和香格里拉的景色慢慢看好。遇到天气或身体状态不理想时，果断减少步行，就是最好的旅行安排。', GREEN_FILL),
      p('本手册依据 2026年7月可查询的交通、景区与暑期市场信息整理。车次、索道、天气、道路和价格均可能变动，请以12306、景区官方渠道和出行当天公告为准。', { spacing: { before: 240, after: 0 }, run: { size: 17, color: MUTED, italics: true } }),
    ],
  }],
});

Packer.toBuffer(doc).then((buffer) => {
  fs.writeFileSync(OUT_FILE, buffer);
  console.log(OUT_FILE);
});
