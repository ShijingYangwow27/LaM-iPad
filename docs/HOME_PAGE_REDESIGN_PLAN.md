# Mineradio 主页改造计划 (Home Page Redesign Plan)

> 创建日期：2026-07-03
> 状态：待用户确认后实施
> 适用范围：仅 `public/index.html` 的 `#empty-home` 区域
> 触发原因：当前主页在窗口/全屏两种模式下布局参数不一致、信息密度过高、不符合 Apple 设计语言

## 文档用途

这是给 AI 代理阅读的"主页改造施工图"。新对话处理 Mineradio 主页前，先读本文件再读代码。文件结构与 `docs/GLASS_SVG_TEXTURE.md`、`docs/3D_PLAYLIST_SHELF_MEMORY.md` 保持一致。

## 1. 设计原则

1. 借鉴 Apple 设计语言：**少即是多**、**清晰层级**、**精准字重对比**、**减少装饰**
2. 保持现有气质：暗色、精致、流畅、有质感
3. 保护已有成就：玻璃 SVG 质感、底部控制台、3D 歌单架、视觉控制台、粒子视觉**一律不动**
4. 定点优化：不重写 `public/index.html` 大块结构，只改主页相关 CSS
5. 测试安全：先在 `public/index.apple-test.html` 验证，再合回主文件

## 2. 已知问题清单（按优先级）

### P0 - 必修
- **A1** 主页 `#empty-home` 在窗口/全屏两种模式下用两套独立 CSS 参数，切换时形变
- **A2** `home-card` 没有 `aspect-ratio` 约束，在 fr 单位下被任意拉宽
- **A3** `.home-mosaic` 在全屏模式下被压扁（`clamp(146px, 16vh, 208px)`），反而比窗口模式更小
- **A4** 主页和视觉控制台使用两套不同的 accent 变量（`--home-accent` vs `--fc-accent`），互不引用

### P1 - 重要
- **B1** 5-cell mosaic 把"内容入口"和"工具入口"混在一起（天气电台 + 4 个 shortcut）
- **B2** 字体层级字重对比度不足（kicker/title 都是 760 起步，缺轻盈字重）
- **B3** 主页配色噪点过多（4-5 种 accent 同时出现：青绿/香槟金/浅蓝/紫蓝/灰蓝）
- **B4** hero 区元素堆叠过密（kicker + title + sub + meta + disc + mosaic + 装饰渐变）
- **B5** 装饰性元素过载（hero::before 三层渐变 + 两套网格线 + 卡片竖条纹）

### P2 - 打磨
- **C1** 4 个 shortcut 用 emoji 图标（🌌📝🎬💿），不符合 Apple 风格
- **C2** 顶部 `#top-right` 控件分散在屏幕四角
- **C3** home-card 卡片 2 列 3 行布局信息密度过高
- **C4** 13px 主体文字偏小
- **C5** 空状态文案不精致（"登录后同步你的今日歌曲"语序稍长）

## 3. 关键问题 A1 详细分析（窗口/全屏布局参数不一致）

### 3.1 容器宽度

[public/index.html:240](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/public/index.html#L240) — 窗口模式：
```css
#empty-home{
  top: 158px; bottom: 58px;
  width: min(1240px, calc(100vw - 72px));
}
```

[public/index.html:392](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/public/index.html#L392) — 全屏模式：
```css
body.desktop-shell.desktop-fullscreen #empty-home{
  top: 96px; bottom: 52px;
  width: min(1480px, calc(100vw - 96px));
}
```

**问题**：容器从 1240px → 1480px，宽度 +19%，但内部元素没同步放大。切换时出现"被拉伸"感。

### 3.2 Grid 列宽

窗口模式（line 246）：
```css
grid-template-columns: minmax(370px, .94fr) minmax(520px, 1.06fr);
```

全屏模式（line 393）：
```css
grid-template-columns: minmax(380px, .92fr) minmax(560px, 1.08fr);
```

**问题**：min 从 370+520=890 改到 380+560=940，fr 比例从 .94/1.06 改到 .92/1.08。**两套参数跳变**，不是连续过渡。

### 3.3 Mosaic 高度

窗口模式（line 278）：
```css
.home-mosaic{
  height: min(260px, 32vh);
  min-height: 190px;
}
```

全屏模式（line 394）：
```css
body.desktop-shell.desktop-fullscreen .home-mosaic{
  height: clamp(146px, 16vh, 208px);
}
```

**问题**：**全屏反而被压扁**（最大 208px，窗口最大 260px），违反"全屏 = 更舒展"的直觉。这是用户最直观的"换了样"感受。

## 4. 视觉 Token 现状

### 4.1 颜色 Token

```
--fc-bg:           #08090B   深色背景
--fc-paper:        #0E1014   纸面
--fc-ink:          #E8ECEF   主文字
--fc-ink-2:        #D2D7DC   次文字
--fc-muted:        #8A9099   弱文字
--fc-hair:         #1A1D22   细分隔线
--fc-hair-2:       #262A31   粗分隔线
--fc-accent:       #00F5D4   主 accent（青绿）
--fc-accent-hov:   #00E0BE   hover
--fc-blue:         #2442FF   蓝
--fc-warm:         #F8F4EE   暖白
--home-accent:     #00F5D4   重复定义（合并目标）
--home-icon-color: #F4D28A   香槟金
--visual-tint:     #9DB8CF   灰蓝
--source-netease:  #D95B67   网易红
--source-qq:       #00F5D4   QQ 青
```

**问题**：accent 颜色重复定义；多套颜色角色命名不一致。

### 4.2 字体 Token

```
--font-sans: "Noto Sans SC", "PingFang SC", "Inter", -apple-system, BlinkMacSystemFont, ...
--font-mono: "JetBrains Mono", "Geist Mono", "SF Mono", ui-monospace, ...
```

### 4.3 当前字重跨度

```
560, 600, 650, 680, 700, 720, 760, 780, 800
```

**问题**：跨度密集、缺轻盈感。Apple 风格典型 4 级：300 / 400 / 600 / 700。

## 5. 主页改造方案

### 5.1 改造目标

1. **窗口/全屏连续**：用 `clamp()` 让布局参数随视口连续变化，删除全屏模式独立覆盖
2. **去除形变**：卡片加 `max-width` 约束，art 用 clamp 跟随视口
3. **降低密度**：从 6 个核心元素降到 3 个（hero + 1 row + 1 rail）
4. **统一 token**：合并 `--home-accent` 到 `--fc-accent`，新建 `--accent` 作为唯一来源
5. **Apple 化**：单 accent、精准字重、删除装饰渐变和网格线

### 5.2 新结构

```
[Hero - 单焦点]
  - kicker (eyebrow text)
  - 标题 (display)
  - 副标题 (sub)
  - [大封面/disc RIGHT]
  - 1 个主 CTA + 1 个副 CTA
  - 删除 5-cell mosaic

[继续听 - 横向 rail]
  - 4-5 张小卡
  - 横向滚动

[为你准备 - 横向 rail]
  - 5 张小卡
  - 横向滚动（保留原结构）

[底部行 - 4 个工具入口]（可选）
  - 壁纸 / 歌词 / 预设 / 3D 歌单
  - 用 SVG 线性 1.5px stroke 图标，非 emoji
```

### 5.3 Token 调整建议

**A. 合并 accent（破坏性变更，需谨慎）**
```css
:root{
  --accent: #00F5D4;          /* 统一主 accent */
  --accent-hov: #00E0BE;
  --accent-rgb: 0, 245, 212;
  --accent-soft: rgba(0, 245, 212, 0.08);
  /* 废除 --home-accent, --fc-accent 重复定义 */
}
```

**B. 字体层级（Apple 4 级）**
```css
--font-display: 700;     /* Display: 32-58px */
--font-headline: 600;    /* Headline: 19-22px */
--font-body: 400;        /* Body: 14-15px */
--font-caption: 500;     /* Caption: 11-12px */
--font-mono: 600;        /* Mono: 11-12px */
```

### 5.4 布局参数 - 用 clamp() 替代两套参数

#### 容器宽度

```css
/* 改前：3 套独立规则 */
#empty-home { width: min(1240px, calc(100vw - 72px)); }
body.desktop-shell #empty-home { width: calc(100vw - 44px); }
body.desktop-shell.desktop-fullscreen #empty-home { width: min(1480px, calc(100vw - 96px)); }

/* 改后：1 套连续规则 */
#empty-home {
  width: clamp(960px, 92vw, 1480px);
  top: clamp(96px, 8vh, 158px);
  bottom: clamp(46px, 4vh, 58px);
}
```

#### Grid 列宽

```css
/* 改前：2 套独立规则 */
.empty-home-shell { grid-template-columns: minmax(370px, .94fr) minmax(520px, 1.06fr); }
body.desktop-shell.desktop-fullscreen .empty-home-shell { grid-template-columns: minmax(380px, .92fr) minmax(560px, 1.08fr); }

/* 改后：1 套自适应 */
.empty-home-shell {
  grid-template-columns: minmax(clamp(280px, 32vw, 380px), 1fr) minmax(clamp(420px, 44vw, 580px), 1.2fr);
  gap: clamp(14px, 1.2vw, 22px);
}
```

#### Mosaic 高度

```css
/* 改前：2 套，全屏反而更小 */
.home-mosaic { height: min(260px, 32vh); min-height: 190px; }
body.desktop-shell.desktop-fullscreen .home-mosaic { height: clamp(146px, 16vh, 208px); }

/* 改后：连续，全屏更大 */
.home-mosaic {
  height: clamp(190px, 26vh, 280px);
  min-height: 190px;
}
```

#### Home card（关键修复：防拉宽）

```css
/* 改前：无 aspect-ratio，fr 单位下任意拉伸 */
.home-card { min-height: 152px; }
body.desktop-shell .home-card { min-height: 148px; }

/* 改后：max-width 约束 + art 跟随视口 */
.home-card {
  min-height: clamp(140px, 16vh, 180px);
  max-width: 100%;
}

.home-card-art {
  width: clamp(72px, 7vw, 104px);
  height: clamp(72px, 7vw, 104px);
}
```

## 6. 预期效果对比表

### 表 6.1：容器与布局（改前 vs 改后）

| 元素 | 模式 | 改前 | 改后 | 改善点 |
|------|------|------|------|--------|
| `#empty-home` 宽 | 窗口 (1200px) | 1128px | 1104px | 略微瘦身 |
| `#empty-home` 宽 | 全屏 (1920px) | 1480px | 1480px | 保持 |
| `#empty-home` top | 窗口 | 132px | 124px | 减小顶部留白 |
| `#empty-home` top | 全屏 | 96px | 96px | 保持 |
| `.empty-home-shell` 列宽 min | 窗口 | 370/520px | 280/420px | min 减小 |
| `.empty-home-shell` 列宽 min | 全屏 | 380/560px | 380/580px | 跟随视口 |
| `.home-hero` min-height | 窗口 | 390px | 380px | 略微降低 |
| `.home-hero` min-height | 全屏 | 438px (默认) | 420px | 降低 |
| `.home-mosaic` 高度 | 窗口 | 190-260px | 190-280px | 跟随视口 |
| `.home-mosaic` 高度 | 全屏 | 146-208px | 220-280px | **全屏不再被压扁** |
| `.home-card` 高 | 窗口 | 148-200px | 140-180px | 跟随视口 |
| `.home-card` 高 | 全屏 | 148-200px | 160-200px | 全屏更大 |
| `.home-card` 宽 | 窗口 | ~620px | 随 max-width 约束 | **不被任意拉宽** |
| `.home-card` 宽 | 全屏 | ~735px | 随 max-width 约束 | **不被任意拉宽** |
| `.home-card-art` 尺寸 | 窗口 | 88×88 固定 | 86×86 (7vw) | 跟随视口 |
| `.home-card-art` 尺寸 | 全屏 | 88×88 固定 | 104×104 (7vw) | 全屏更大 |

### 表 6.2：字体层级（改前 vs 改后）

| 元素 | 模式 | 改前 | 改后 | 改善点 |
|------|------|------|------|--------|
| `.home-title` font-size | 窗口 (1200px) | 50.6px (clamp 34-58) | 50.6px 保持 | 不变 |
| `.home-title` font-size | 全屏 (1920px) | 58px (max) | 58px 保持 | 不变 |
| `.home-title` font-weight | 全部 | 760 | 700 | **精准字重** |
| `.home-sub` font-size | 窗口 | 13px | 15px | 放大 |
| `.home-sub` font-size | 全屏 | 13px | 16px | 跟随放大 |
| `.home-kicker` font-weight | 全部 | 780 | 600 | **对比度更强** |
| `.home-card-title` font-size | 窗口 | 19px | 19px | 不变 |
| `.home-card-title` font-size | 全屏 | 19px | 22px | 跟随放大 |
| `.home-card-title` font-weight | 全部 | 780 | 700 | 精准字重 |
| `.home-card-sub` font-size | 窗口 | 11.5px | 12.5px | 略微放大 |
| `.home-card-sub` font-size | 全屏 | 11.5px | 14px | 跟随放大 |

### 表 6.3：装饰与配色（改前 vs 改后）

| 维度 | 改前 | 改后 | 改善点 |
|------|------|------|--------|
| 主 accent 数量 | 4-5 种（青绿/香槟金/浅蓝/紫蓝/灰蓝）| 1 种（青绿）| **降噪** |
| accent 变量来源 | `--home-accent` / `--fc-accent` 重复 | `--accent` 统一 | 单一来源 |
| hero 装饰层 | 3 层渐变 + 2 套网格线 | 1 层极弱渐变 | **去掉网格线** |
| `home-card::after` 装饰 | 竖条纹 | 删除 | 减少装饰 |
| 4 个 shortcut 图标 | emoji (🌌📝🎬💿) | SVG 1.5px stroke | **Apple 风格** |
| mosaic 高度逻辑 | 窗口大 / 全屏小 | 窗口中等 / 全屏大 | **符合直觉** |
| 切换窗口↔全屏 | 形变、跳变 | 连续过渡 | **平滑** |

## 7. 实施步骤

### 阶段 1：实验（不破坏主文件）
1. 复制 `public/index.html` → `public/index.apple-test.html`
2. 在 test 文件中替换以下 5 个 CSS 块：
   - `:root` token 块
   - `#empty-home` 容器
   - `.empty-home-shell` grid
   - `.home-mosaic` 高度
   - `.home-card` 尺寸
3. 在 `desktop/main.js` 临时指向 test 文件验证
4. 视觉对比窗口/全屏，截图保存

### 阶段 2：合回主文件
1. `git diff` 检查变更范围
2. 用户确认后合回
3. 删除 test 文件
4. 更新 `CHANGELOG.md` 顶部中文说明

### 阶段 3：监控
1. 实机运行验证：
   - 窗口模式 1200×800
   - 全屏 1920×1080
   - 拖动窗口边缘验证 `clamp()` 连续变化
2. 帧数监控（确认不引入性能问题）
3. 验证底部栏、视觉控制台、3D 歌单架、粒子视觉**未被影响**

## 8. Guardrails（与 AGENTS.md 一致并扩展）

### 禁止回退或改坏的点
- **不要**改 `docs/GLASS_SVG_TEXTURE.md` 列出的玻璃 SVG 质感基线
- **不要**改底部控制台 (`#bottom-bar`)、3D 歌单架、视觉控制台 (`#fx-panel`)、粒子视觉
- **不要**把 `home-card` 的 `aspect-ratio: auto` 改为固定值（应让内容驱动）
- **不要**把 `--home-accent` 重新单独定义（必须合入 `--fc-accent` 或新建 `--accent`）
- **不要**改 emoji 为 emoji 风格 SVG（必须是 1.5px stroke 线性 SVG）
- **不要**保留网格线装饰（hero::before 的 grid gradient 必须删）
- **不要**在主页加 `backdrop-filter` 模糊（影响帧数，玻璃质感仅限底部栏和视觉控制台）
- **不要**恢复旧的侧边栏闪烁、控制台播放暂停失效、3D 歌单架强制切回星河等问题

### 必做验证项
- 改前/改后用同一组截图对比窗口模式和全屏模式
- 拖动窗口边缘验证 `clamp()` 连续变化是否平滑
- 帧数监控不下降
- 底部栏、视觉控制台、3D 歌单架、粒子视觉**视觉无变化**

## 9. 相关文件

- 主文件：[public/index.html](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/public/index.html)
- 主页 CSS 关键行：240-410
- 玻璃质感参考：[docs/GLASS_SVG_TEXTURE.md](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/docs/GLASS_SVG_TEXTURE.md)
- 3D 歌单架：[docs/3D_PLAYLIST_SHELF_MEMORY.md](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/docs/3D_PLAYLIST_SHELF_MEMORY.md)
- 项目记忆：[docs/PROJECT_MEMORY.md](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/docs/PROJECT_MEMORY.md)
- AGENTS.md 主页 Guardrails：[AGENTS.md](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/AGENTS.md)
- 桌面歌词视觉：[docs/DESKTOP_LYRICS_VISUAL.md](file:///Users/yangshijing/Documents/trae_projects/cyberaudioDemo/Mineradio-%20macOS/docs/DESKTOP_LYRICS_VISUAL.md)

## 10. 后续可选工作（不在本次范围）

- 写 `DESIGN.md`（项目级视觉系统文档）— 见 PROJECT_MEMORY.md 的"设计系统未统一"问题
- 顶部 `#top-right` 整合到底部栏
- home-card 改为横向 rail（3-4 张大卡 + 1 行 rail）
- 视觉控制台与主页 token 统一
- emoji → SVG 线性图标资源替换
