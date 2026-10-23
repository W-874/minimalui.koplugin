# Minimal UI for KOReader

轻量的 KOReader Home 与 Library 界面，适用于键盘、少键和触屏电子阅读器。

**v0.6.0** 提供继续阅读、最近阅读、书籍封面与阅读进度，以及统一的书籍列表／网格、文件列表和三区页脚；阅读器、设置、文件操作与元数据仍复用 KOReader 原生能力。

## 安装

1. 使用 `minimalui-v0.6.0.zip` 安装包时，解压后直接使用其中的 `minimalui.koplugin` 目录。也可下载仓库源码 ZIP 并将目录命名为 `minimalui.koplugin`，或使用 Git（仓库版本以其 `_meta.lua` 为准）：

   ```sh
   git clone https://github.com/W-874/minimalui.koplugin.git
   ```

2. 完全退出 KOReader，将 `minimalui.koplugin` 放入 KOReader 的 `plugins/` 目录。
3. 重新启动 KOReader。从原生工具菜单的 **Minimal UI** 中启用插件或选择 **Show home**。

安装后的目录应为：

```text
koreader/plugins/minimalui.koplugin/
├── main.lua
├── _meta.lua
├── minimalui/
├── README.md
└── LICENSE
```

`main.lua` 必须直接位于插件目录下，不要再套一层同名目录。

### 升级与卸载

升级前完全退出 KOReader，备份并替换原插件目录。从旧 `minimalhome.koplugin` 升级时，请先移走旧插件，避免两个版本同时加载。已有书籍、阅读进度和排版设置无需重置。

暂时停用可使用 **Minimal UI → Enable Minimal UI**。卸载时完全退出 KOReader，移除插件目录即可。

## 功能

### Home

- **继续阅读**：打开上次阅读的书籍，显示封面、书名、阅读进度，以及已有的作者和章节信息。
- **最近阅读**：显示最多三本其他最近阅读的书籍，方便快速切换。
- **阅读统计**：启用 KOReader 原生阅读统计插件后，显示已有的今日及本周阅读时长。
- **快捷入口**：Library、History、File Browser。
- **状态顶栏**：时间、电量与原生设置菜单入口。

章节、剩余时间等信息依赖已保存的阅读数据；没有对应数据时不显示。Minimal UI 不会改动正文渲染、字体、排版或翻页方式。

### Library

Library 用于浏览 Kindle `documents` 目录当前层的书籍，不混排子目录。进入 Library 时更新书籍列表，按文件名排序。

启用 KOReader 的 CoverBrowser 插件后，Library、History、单个收藏内容和搜索结果共用原生 **History display mode** 设置，提供书名详细列表或封面网格；已保存的 Classic／文件名列表映射为书名列表，不覆盖原设置。未启用 CoverBrowser 时回退为简单列表，不代为加载封面模块。

**Files** 保留独立显示模式与文件名、目录和文件属性。插件启用时隐藏统一显示模式、收藏独立显示模式及简介提示菜单，不改写其保存值；停用插件后恢复原生。目录浏览、文件移动等操作仍使用独立的 **File Browser** 入口。

已适配的分页页面（含书籍信息、OPDS、Bookmarks）使用 `‹ 当前页/总页数 ›` 页脚。左右区域点按翻页，中间点按／长按复用原生跳页或搜索；一页时仍可使用中间输入。键盘原生首页／尾页组合键保留。

在 Home 或 Library 中长按书籍，可使用原生阅读状态、收藏、删除、打开方式、书籍信息、封面和简介等操作。键盘设备也可使用原生上下文菜单组合键，如 Shift + Press。

## 操作

| 设备 | 操作 |
| --- | --- |
| 键盘／方向键 | 方向键移动选中项；Press／Enter 打开选中项；Menu 打开原生设置。 |
| 少键设备 | 上下移动选中项，确认键打开；Home 的 Left 返回，Right 打开设置。 |
| 触屏 | 点击卡片或入口打开；长按书籍显示操作菜单；点击顶栏空白处或从顶栏下滑打开设置。 |

键盘设备的 Home 快捷键：

| 按键 | 功能 |
| --- | --- |
| Q / W / E | 从左至右打开三本最近阅读的书籍 |
| L | Library |
| H | History |
| F | File Browser |

Press／Enter 始终打开当前选中项，不固定指向继续阅读卡片。

### 页面返回

- Library 和 File Browser 的 Back／Home 返回 Home。
- Home 的 Back 打开退出确认；取消后留在 Home。
- 原生设置菜单直接覆盖当前页，返回时先关闭菜单。
- 阅读器中的 File browser 菜单入口返回 Library；实体 Home 键返回 Home。

## Home 显示设置

打开 **Minimal UI → Home appearance**，可分别开关：

- **Recent books**：最近阅读卡片。
- **Book covers**：书籍封面。
- **Book information**：作者、章节等附加信息。
- **Reading statistics**：阅读时长。
- **Navigation details**：入口旁的数量与路径。

开关只影响 Home 显示，不删除书籍或阅读数据。原生阅读器与 CoverBrowser 的设置仍在各自菜单中调整。

## v0.6.0 更新

- Library、History、Collections、Search 和 Files 使用统一黑白列表／网格；单行书名省略、阅读进度、收藏状态与已读标记沿用原生数据。网格不添加底部详情行。
- 列表用左侧黑条、网格用方框表示焦点；纯触屏不强制显示选中框。页面表面缓存按缓冲格式、inverse 和旋转失效，菜单关闭后恢复完整页面。
- 三区页脚复用原生按钮与输入对话框；书籍信息页在初始化、翻页和旋转后保留页脚，禁用时恢复原字体和控件。
- 封面后台提取按页面实例管理，翻页、模式切换及关闭取消过期任务；关闭停放的旧页面不会终止新页面的提取。
- 不改变 Home 布局、书库范围、排序或阅读排版；不按 Kindle 型号设置性能分支。

本版本使用官方 KOReader v2026.07.1 Linux SDL 验证。桌面绘制／像素检查不能证明 Kindle 实机响应、电子墨水残影或长期稳定性；安装前保留旧版插件以便回退。

## v0.5.3 更新

- Home或Library覆盖文件浏览器时，推迟不可见顶栏的适配；首次进入Files前完成适配，保留原生列表布局。
- 连续的4位灰阶绘制缓冲按整块复制，减少逐行开销；边缘、旋转和不同格式继续按实际缓冲布局处理。

## v0.5.2 更新

- Home 的数量、路径和统计文字变化时直接更新对应文字，减少重复布局；隐藏信息变化不会重建页面。
- JPG/PNG 图片书籍复用原生解码器，减少首次封面加载开销；自定义封面查找结果在一次加载中复用。

## v0.5.1 更新

- 不显示导航数量时，Home 只检查所需的最近阅读文件。
- 阅读统计使用只读变更检测，避免无变化时重复聚合；挂起、关闭和禁用时释放资源。
- Library 减少重复格式匹配，修改状态或收藏时只刷新内容，进入书架仍更新文件列表。

## v0.5 更新

- 新 Home 布局，增加三本最近阅读、章节信息与原生阅读时长。
- 最近阅读使用 Q / W / E 快捷键，高对比文字和选中反馈。
- 从 Library、File Browser 返回时复用 Home，减少重复布局和封面解码。
- 绘制缓存按屏幕像素格式和旋转适配，减少焦点移动时的重复绘制。

首次加载封面、从阅读器返回或切换横竖屏仍需要处理书籍数据与布局；速度会受到设备性能、书籍格式和存储速度影响。

## 许可与致谢

本项目使用 [GNU GPL v3](LICENSE) 许可。

核心能力来自 [KOReader](https://github.com/koreader/koreader) 的原生组件与服务。界面探索参考了 [ZenOS](https://github.com/AnthonyGress/zen_ui.koplugin) 和 [Project: Title](https://github.com/joshuacant/ProjectTitle)。
