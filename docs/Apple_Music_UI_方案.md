# Mineradio × Apple Music 风格 UI 优化方案

> 目标：把现有「深色玻璃赛博」风格升级为「Apple Music 式精致现代」风格，让界面在 iPad 上看起来像 Apple 原生音乐 app，同时保留 Mineradio 独有的视觉器与发现感。

---

## 1. 设计目标

| 维度 | 当前 | 优化后 |
|---|---|---|
| 视觉风格 | 深色玻璃 + 霓虹点缀 + 密集马赛克 | 高留白 + 专辑封面驱动 + 柔和色彩提取 |
| 字体 | 较细、层级不够明显 | 苹果 SF Pro / 苹方层级系统 |
| 内容密度 | 高，方块多 | 中，以专辑封面和卡片为主体 |
| 品牌色彩 | 香槟金/青绿/蓝 | 专辑封面自动取色 + Apple Music 红作为强调 |
| 动效 | 已有玻璃动效 | 增加 iOS 弹性、播放页展开、卡间悬浮 |
| 平台气质 | 自定义音乐 app | 原生 Apple Music 体验 |

---

## 2. 核心设计 DNA

### 2.1 色彩：专辑封面驱动（Apple Music 标志性特征）
- 当前背景从「固定暗色」改为「从当前播放/推荐专辑封面提取主色」的柔焦渐变。
- 取色规则：
  - 主色 `artwork-primary` → 背景渐变起始色（低饱和度、高亮度、半透明）
  - 辅色 `artwork-secondary` → 强调文字/按钮高亮
  - 中性色 → 卡片表面
- 不播放时回退到深灰/黑：
  - `--bg-primary: #000000`
  - `--surface: #121212`
  - `--surface-elevated: #1c1c1e`

### 2.2 字体：Apple 风格层级
- 字体栈：`-apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", "Hiragino Sans GB", sans-serif`
- 标题：粗体、紧凑字距、大字号
- 正文：标准字重、清晰可读
- 标签：小号大写/字母间距略宽

| 层级 | 尺寸 | 字重 | 用途 |
|---|---|---|---|
| Hero Title | 32-40px | 700 | 页面大标题、播放页歌曲名 |
| Section Title | 22-26px | 700 | 区块标题 |
| Card Title | 15px | 600 | 卡片标题/歌曲名 |
| Card Subtitle | 13px | 400 | 艺人名/副标题 |
| Label | 11-12px | 500 | 标签、时间、辅助 |

### 2.3 间距：Apple 8pt 网格
- 页面边距：24px（iPad 横向 32px）
- 卡片间隙：16px
- 卡片内边距：16px
- 行高：1.2-1.4（标题），1.5（正文）
- 底部播放条高度：68px

### 2.4 形状：统一圆角
- 小卡片/按钮：10px
- 中卡片/专辑封面：12px
- 大卡片/模态：16px
- 胶囊/标签：999px
- 播放按钮：圆形

### 2.5 材质：保留玻璃，但克制
- 减少当前大面积 `rgba(255,255,255,0.04)` 玻璃块，改为更沉的 `surface` 色。
- 背景模糊只用于：底部播放条、弹窗、侧边栏（iPad 横屏）。
- 避免过多玻璃层叠，降低视觉噪音。

---

## 3. 设计 Token（建议加入 `:root`）

```css
:root {
  /* 动态取色（JS 根据专辑封面注入） */
  --artwork-primary: #ff4d6d;
  --artwork-secondary: #4d79ff;
  --artwork-gradient: radial-gradient(
    120% 80% at 80% -20%,
    rgba(255, 77, 109, 0.45) 0%,
    rgba(0, 0, 0, 0) 70%
  );

  /* 中性色 */
  --bg-primary: #000000;
  --bg-secondary: #0a0a0a;
  --surface: #121212;
  --surface-elevated: #1c1c1e;
  --surface-highlight: #2c2c2e;
  --divider: rgba(255, 255, 255, 0.08);

  /* 文字 */
  --text-primary: #ffffff;
  --text-secondary: rgba(255, 255, 255, 0.72);
  --text-tertiary: rgba(255, 255, 255, 0.48);

  /* 强调 */
  --accent: #ff2d55;          /* Apple Music 红 */
  --accent-secondary: #34c759; /* 播放/在线绿 */
  --accent-hover: #ff4d6d;

  /* 字体 */
  --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", sans-serif;
  --font-body: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;

  /* 间距 */
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 20px;
  --space-6: 24px;
  --space-8: 32px;
  --space-10: 40px;

  /* 圆角 */
  --radius-sm: 8px;
  --radius-md: 10px;
  --radius-lg: 12px;
  --radius-xl: 16px;
  --radius-full: 999px;

  /* 阴影 */
  --shadow-sm: 0 2px 8px rgba(0, 0, 0, 0.24);
  --shadow-md: 0 8px 24px rgba(0, 0, 0, 0.32);
  --shadow-lg: 0 20px 48px rgba(0, 0, 0, 0.40);

  /* 动效 */
  --ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1);
  --ease-standard: cubic-bezier(0.2, 0, 0, 1);
  --duration-short: 200ms;
  --duration-medium: 300ms;
  --duration-long: 450ms;
}
```

---

## 4. 分页面/分模块优化

### 4.1 Home 首页 → Apple Music「现在就听」

**当前：** 多个功能马赛克、天气/问候卡片、电台入口混杂。

**优化后：**
- 顶部大标题：「现在就听」+ 用户头像（圆形 32px）
- 首屏 Hero 卡片：今日首推/私人电台，占 2/3 宽度，左侧文字，右侧专辑封面
- 分类区块：
  - 最近播放（横向滚动，专辑封面 140px 方图）
  - 为你推荐（2×n 网格）
  - 热门电台（大卡片）
- 每个区块用「区块标题 + 右侧「全部」链接」

**关键改动：**
- 去除零散小方块，改为统一专辑封面卡片。
- 专辑封面统一为 1:1 方图，圆角 12px，带轻微阴影。
- 横向滚动区域隐藏滚动条，支持触控滑动。

### 4.2 搜索页

**优化后 Apple Music 风格：**
- 搜索框：白色背景胶囊/深灰背景圆角，44px 高，带搜索图标，占位符「歌曲、艺人、专辑、歌单」
- 搜索建议分类：最近搜索、热门搜索、分类标签（横向滚动胶囊）
- 结果页：列表项左侧专辑封面 48px，右侧歌曲名/艺人，极简分隔线

### 4.3 资料库/列表页

- 改为 Apple Music 风格列表：
  - 行高 56px，左侧专辑封面 48px，右侧播放按钮/更多按钮
  - 分隔线细且颜色低（`--divider`）
  - 无表格感，强调内容
- 顶部筛选 Tab：「播放列表」「艺人」「专辑」「歌曲」胶囊切换

### 4.4 底部播放条（Mini Player）

**优化后：**
- 高度 68px，背景 `#121212` + 顶部 1px 分隔线，iPad 横屏可加背景模糊
- 左侧：当前专辑封面 48px（圆角 8px）
- 中间：歌曲名 15px bold，艺人名 12px secondary
- 右侧：播放/暂停、下一首按钮（44px 圆形透明按钮）
- 进度条可嵌入播放条顶部或底部，2px 高度

### 4.5 展开播放页（Now Playing）

**Apple Music 播放页核心特征：**
- 全屏渐变背景（从专辑封面取色）
- 顶部：向下收起按钮 + 歌词/队列入口
- 中部：大专辑封面 280-320px，圆角 16px，带柔和阴影
- 标题区：歌曲名 28px bold，艺人名 18px secondary，心形/更多按钮
- 进度条：粉色/取色，已播放部分实色，未播放 `rgba(255,255,255,0.25)`
- 控制区：上一首（30px）、播放/暂停（64px 大按钮，白色背景、黑色图标）、下一首（30px）
- 底部：音量条、设备投放、歌词/播放列表切换

### 4.6 视觉器（Visualizer）

保留 Mineradio 特色，但融入 Apple Music 质感：
- 背景跟随专辑封面主色做柔焦渐变。
- 频谱柱/圆环使用 `color-mix` 混合主色和白色，保持统一。
- 增加「粒子呼吸」动效，避免方块频谱的机械感。
- 可通过点击/设置切换「视觉器模式」与「纯歌词/专辑封面模式」。

---

## 5. 组件升级

### 5.1 专辑封面（Artwork）
```css
.artwork {
  aspect-ratio: 1;
  border-radius: var(--radius-lg);
  object-fit: cover;
  background: var(--surface-elevated);
  box-shadow: var(--shadow-sm);
}
.artwork-lg { width: 100%; max-width: 320px; }
.artwork-md { width: 140px; }
.artwork-sm { width: 48px; border-radius: var(--radius-sm); }
```

### 5.2 卡片
```css
.card {
  background: var(--surface);
  border-radius: var(--radius-xl);
  padding: var(--space-4);
  transition: transform 200ms var(--ease-spring), box-shadow 200ms;
}
.card:hover { transform: translateY(-2px); box-shadow: var(--shadow-md); }
.card:active { transform: scale(0.98); }
```

### 5.3 按钮层级
- 主按钮：白色背景、黑色文字、圆角 10px
- 次按钮：透明背景、白色文字、1px 白色描边
- 图标按钮：44px 圆形，hover 时背景变亮
- 胶囊标签：深色背景、白色文字、小字号、窄内边距

### 5.4 导航
- iPad 横屏：左侧固定侧边栏（宽度 240px），包含「现在就听」「浏览」「电台」「资料库」「搜索」+ 播放列表列表。
- iPad 竖屏/小屏：底部 Tab Bar（高度 56px + 安全区）。

---

## 6. 动效与交互升级

| 场景 | 当前 | 优化后 |
|---|---|---|
| 页面切换 | 直切 | 淡入 200ms + 轻微上移 8px |
| 卡片 hover | 已有 | 增加 `translateY(-2px)` + 阴影加深 |
| 播放按钮按下 | 简单 | scale 0.94 + 光晕扩散 |
| 播放页展开 | 可能是弹出 | 从底部播放条展开（shared element transition），400ms spring |
| 歌曲切换 | 封面切换 | 封面交叉淡入淡出 250ms |
| 背景颜色切换 | 硬切 | 颜色过渡 800ms，配合渐变偏移 |

**关键实现建议：**
- 播放页展开：底部播放条的小封面 → 播放页大封面，用 `FLIP` 动画或简单缩放+淡入。
- 背景取色：使用 `node-vibrant` 或 `<canvas>` 提取专辑封面主色，注入 CSS 变量并配合 `transition`。
- 滚动：使用 `overflow-x: auto` + `scroll-snap-type` 让横向滚动更顺滑。

---

## 7.  before / after 对比

### 7.1 Home 首页
- **Before：** 多模块马赛克、玻璃卡片叠加、颜色多（香槟/青绿/蓝）、信息密度高。
- **After：** 大标题 + 单张 Hero + 横向专辑流 + 区块网格，颜色由专辑封面统一驱动，呼吸感强。

### 7.2 播放页
- **Before：** 当前小封面、控制按钮分散。
- **After：** 全屏渐变、大封面、居中播放控制、清晰的标题层级。

### 7.3 搜索页
- **Before：** 搜索框 + 结果列表较朴素。
- **After：** 胶囊搜索框、最近搜索标签、分类快捷入口、结果列表更 clean。

### 7.4 底部播放条
- **Before：** 已有玻璃质感，但视觉上偏复杂。
- **After：** 简洁单行布局，白色进度条，强可识别性。

---

## 8. 实施路线图

### Phase 1：设计 Token（1 天）
- 在 `:root` 中引入上述 CSS 变量。
- 保留旧变量作为 fallback，避免一次性破坏现有界面。

### Phase 2：全局 Chrome（1-2 天）
- 改造底部播放条为 Apple Music 风格。
- 增加 iPad 横屏侧边栏 / 竖屏 Tab Bar。
- 统一字体和按钮组件。

### Phase 3：Home 改造（2-3 天）
- 重写 home-mosaic 区块为「Hero + 横向滚动 + 网格」。
- 接入专辑封面取色逻辑。
- 保留原有电台/发现入口，但改以卡片形式呈现。

### Phase 4：播放页改造（2-3 天）
- 实现全屏 Now Playing 展开动画。
- 大封面、标题、控制、进度条、音量、设备投放。
- 视觉器与背景渐变融合。

### Phase 5：搜索与列表（1-2 天）
- 搜索页 UI 刷新。
- 统一列表项样式。
- 资料库筛选 Tab。

### Phase 6：动效与打磨（2 天）
- 添加 FLIP/弹簧动效。
- 取色过渡优化。
- 暗黑/亮色模式适配（可选）。

---

## 9. 原型参考

已输出可交互原型：`public/apple-music-prototype.html`
- 包含：首页、搜索、资料库、底部播放条、展开播放页。
- 可直接在浏览器打开，或用 `http://127.0.0.1:3001/apple-music-prototype.html` 查看。
- 原型使用静态数据展示 Apple Music 风格的布局、色彩、字体与动效。

---

## 10. 关键成功标准

- [ ] 界面看起来与 Apple Music 视觉语言一致，但仍有 Mineradio 的识别度（视觉器/电台）。
- [ ] 字体层级清晰，远距离即可识别歌曲名和艺人。
- [ ] 所有可点击区域 ≥ 44px。
- [ ] 专辑封面取色让背景自然过渡，无突兀色彩。
- [ ] 播放页展开/收起动画流畅，不卡顿。
- [ ] iPad 横竖屏布局都合理。

---

> 下一步：可基于该方案直接推进 Phase 1，或先打开原型确认方向后再进入代码实现。
