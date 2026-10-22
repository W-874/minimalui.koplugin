# Minimal UI for KOReader

A lightweight Home and Library interface for keyboard, button and touch e-readers.

Minimal UI 是 KOReader 插件：接管 Home 与 Library，复用原生阅读器、设置、文件浏览和书籍操作。当前已提交版本为 v0.4；新 Home 的 SVG 方案实现不包含在这些提交中。

## 安装

**这个仓库本身就是插件目录，不需要再套一个 `.koplugin` 子目录。**

```sh
git clone git@github.com:W-874/minimalui.koplugin.git
```

完全退出 KOReader 后，将整个仓库目录 `minimalui.koplugin` 放入 KOReader 的 `plugins/`：

```text
koreader/plugins/minimalui.koplugin/
├── main.lua
├── _meta.lua
├── minimalui/
├── README.md
└── LICENSE
```

也可以下载源码 ZIP，解压后将目录改名为 `minimalui.koplugin` 再安装。`main.lua` 必须直接位于该目录下。

从旧版升级：先备份，再从设备的 `plugins/` 中移走旧 `minimalhome.koplugin`，不要与 `minimalui.koplugin` 并装。插件身份和宿主引用现在均为 `minimalui`；已有阅读排版、书籍和 sidecar 不重置。旧版自动主页禁用偏好仍可读取。

重启 KOReader。原生工具菜单里的 Minimal UI 可启用、禁用或手动显示 Home。卸载时完全退出 KOReader 并移除插件目录，不需要删除书籍或用户设置。

## 功能

- **Home**：继续阅读、真实单书封面、进度条和百分比，Library、History 与 File Browser 入口；顶栏显示时间、电量。
- **Library**：Kindle `documents` 书籍列表，独立于原生文件浏览器。当前保留浅扫描、扩展名筛选、排除隐藏项/目录/符号链接及文件名排序，不扩大扫描范围。
- **原生显示模式**：CoverBrowser 已启用时复用其列表、封面网格、元数据及缓存；不替用户强行启用插件，不建立第二套数据库。未启用则使用 classic 列表。
- **书籍操作**：长按使用原生状态、收藏、删除确认、打开方式、信息、封面和简介。
- **统一顶栏**：文件浏览、History、收藏、搜索、跨书书签、书籍信息及 OPDS 的相关内容页采用共享组件。原生任务选择器、确认框、输入框和设置菜单保留原有提交/取消语义。
- **Files**：左侧 `+` 打开原生目录操作；选择模式用勾号及实时数量提示，可明确退出。
- **OPDS**：当前目录名直接显示在 `KO/` 后；左侧导航位置用 `X` 退出当前页面，下载列表关闭后回 OPDS。键盘设备保留原生 Q/W 等快捷提示及操作，纯触屏不显示硬件键提示。
- **轻量更新**：选择移动局部刷新；整分钟时钟不扫描书库、不读取书籍进度；禁用、挂起和关闭清理待执行任务。

阅读器的正文渲染、翻页、字体、排版和原生文档末尾行为不重写。

## 输入与导航

| 设备能力 | 操作 |
| --- | --- |
| 键盘／方向键 | 方向键移动焦点，Press 激活；Menu 打开设置，Back/Home 执行当前页面返回。 |
| 少键设备 | 按设备能力适配；Home/Library 的 Right 可打开设置，Home 的 Left 返回。 |
| 触屏 | 点击整行或按钮；点顶栏空白或从顶栏下滑打开设置；长按书籍进入原生操作。 |

Home 是根页。Library 和 File Browser 的 Back/Home 返回 Home；Home Back 弹出原生退出确认，取消留在原页。设置菜单直接叠在当前页上方，返回先关闭上层菜单，不穿透退出。

Reader 菜单的 File browser 入口按本插件导航返回 Library；实体 Home 保持返回 Home。

## 版本迭代

**所有版本都逐层覆盖同一套根目录源码，使用 Git 提交和标签追溯；仓库不包含版本副本目录、安装包或本地开发资料。**

| 标签 | 阶段 |
| --- | --- |
| `v0.1` | 键盘优先的 Home，继续阅读、进度、History 和原生入口。 |
| `v0.2-experiment` | 分离 Library 与窗口生命周期的早期实验；普通列表 Home 未被接受。 |
| `v0.2` | 恢复 Home 层级，引入原生封面、共享顶栏及 Library 显示模式。 |
| `v0.3-release` | 减少重复扫描、元数据读取和重建，保留已确认的界面与导航。 |
| `v0.3-baseline` | 阅读返回 Library、原生长按动作、列表重复顶线修复。 |
| `v0.4` | 双输入适配、选择状态、时钟、原生内容页、OPDS 及快捷提示/标题纠正。 |

这些阶段根据保留源码与已知变更重建，提交日期是本次整理时间，不伪装为原始开发提交时间。被纠正的设计在对应提交中如实记录，不用最终版本覆盖其存在过的事实。

```sh
git log --oneline --reverse
git diff v0.3-baseline v0.4 -- main.lua minimalui/
```

查看旧版本可在单独的本地检出目录操作，设备上仍只安装一个版本。

## 验证与限制

- v0.1 有 Kindle 3 用户实机反馈；不能据此声称后续版本已经过 Kindle 验收。
- v0.4 曾使用官方 KOReader v2026.07.1 完整 Linux SDL 运行包验证真实绘制、触摸/按键/少键能力、横竖屏、Library 模式、阅读往返、退出、禁用恢复及 OPDS 本地目录解析。
- SDL 是脚本驱动的原生运行，不是物理 Kindle、电子墨水波形或真实手指测试；契约替身测试也不能替代它。
- 目标设备包括 Kindle 3、4、Touch、8，清单不表示均已验证。具体 KOReader 版本、其他插件组合、大目录、冷缓存高速切换和长期内存仍需设备核对。
- 首次封面解码、原生文件管理器初始化和封面缓存读取仍有成本，不承诺零开销。

本仓库只发布运行源码和必要说明；本地测试、设计草案、交接记录与缓存不随插件发布。

## 许可与致谢

保留仓库原有 [GNU GPL v3 LICENSE](LICENSE)。核心能力来自 [KOReader](https://github.com/koreader/koreader) 的原生组件和服务；界面探索参考 [ZenOS](https://github.com/AnthonyGress/zen_ui.koplugin) 和 [Project: Title](https://github.com/joshuacant/ProjectTitle)。灵感引用不表示移植了这些项目的完整功能。
