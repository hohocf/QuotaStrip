# QuotaStrip

**在 MacBook Pro 的 Touch Bar 上实时显示 Claude Code 和 Codex 的额度。**

[English](README.md)

那条几乎没人用的 Touch Bar？QuotaStrip 把它变成 AI 编程助手的实时仪表盘。再也不用猜还剩多少额度，
也不会在干活干到一半时被限流打个措手不及——它一直在那儿，扫一眼就知道。

![QuotaStrip 显示在 Touch Bar 上](docs/screenshot.png)

每个服务一个面板：品牌 logo + 上下两行——**5 小时窗口**和**周配额**——每行都有进度条、精确百分比和重置时间。

---

## 功能

**两个服务、两个窗口，一眼看全**
- Claude 和 Codex 并排显示，各含 **5 小时**和 **7 天**两个窗口。
- 每行 = 进度条 + **右对齐加粗百分比** + 重置时间。
- 品牌 logo 快速区分两个服务。

**会提前预警的颜色分级**
- 进度条和百分比随用量 **绿 → 黄（≥50%）→ 红（≥80%）** 变化。

**重置时间显示得恰到好处**
- 5h 行显示**重置时间点**（24 小时制，无 am/pm）。
- 7d 行显示**剩余时长**（如 `2d9h`），一眼知道还有多久。
- 当 5h 窗口**距重置不到 30 分钟**时，时间变**黄色**——提醒你趁回血前把额度用掉。

**「它在等你」提醒** 🔴
- 当 Claude 或 Codex 停下来**等你输入或确认权限**时，logo（和菜单栏）上会出现红色 `!` 角标。
  你就知道该去回应了，而不是让它一直挂着。
- **双层检测**：零配置的日志启发式（开箱即用，正在跑的会话也认）+ 可选钩子（即时精确）。
- 你一回复、或点一下面板，角标立即消失。

**点击直达**
- 点面板**把对应桌面应用调到前台**（Claude.app / Codex.app）。没装？那就打开用量网页。

**对限流诚实**
- Anthropic 的用量接口有限流。返回 429 时，QuotaStrip 显示上次的数值并加一个**黄色小点**，
  并严格按服务器的 `Retry-After` 等待后再试。重置时间已过的窗口按 0% 显示，绝不用旧的高百分比误导你。
- **连接日志**（菜单 →「查看连接日志」）记录每次真实请求：`ok`、`429` 或网络错误。缓存命中不记。

**不碍事**
- 右侧保留系统 **Control Strip**，左侧保留 **esc** 键。
- 息屏唤醒后自动恢复。
- 菜单栏仪表图标，菜单含：立即刷新（强制）、重新显示 Touch Bar、打开用量页、查看连接日志、开机自启、退出。

---

## 安装

### 方式 A — 下载即用（推荐）

1. 从 [Releases](../../releases) 页面下载 `QuotaStrip.zip` 并解压。
2. 把 **QuotaStrip.app** 拖进**应用程序**文件夹。
3. **首次打开**：右键点 app →**打开**（只需一次，因为 app 未经过 Apple 公证——
   详见下方[为什么会有安全提示](#为什么会有-gatekeeper-安全提示)）。
4. 按提示在**系统设置 → 隐私与安全性 → 辅助功能**里勾选 QuotaStrip
   （仅 **esc** 键需要，额度显示不需要权限）。
5. *（可选）* 运行 `./install-hooks.sh` 开启 Codex 的「等你」提醒。

搞定——面板就出现在你的 Touch Bar 上了。

### 方式 B — 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/hohocf/QuotaStrip.git
cd QuotaStrip
./build.sh --run
```

`build.sh` 会编译**通用二进制**（Intel + Apple Silicon）、打包资源并 ad-hoc 签名。

---

## 工作原理

QuotaStrip 通过与 [MTMR](https://github.com/Toxblh/MTMR)、[Pock](https://github.com/pigigaldi/Pock)
相同的私有 `DFRFoundation` API 常驻 Touch Bar。数据由一个打包在 app 内的小 Python 脚本
（`quota.py`）提供：

- **Claude**——用你**已有的 Claude Code 登录**（macOS 钥匙串里的 OAuth token）调 Anthropic 官方的
  **只读**用量接口。缓存约 10 分钟，绝不高频轮询。
- **Codex**——**100% 本地**解析 `~/.codex/sessions` 日志，**零网络请求**。

app 每 20 秒刷新一次。Codex 和等待提醒是实时的；Claude 的数值来自约 10 分钟的缓存
（随时可通过菜单「立即刷新」强制拉取实时值）。

---

## 兼容性

- 任意**带 Touch Bar 的 MacBook Pro**——Intel（2016–2020）和 Apple Silicon 13"（M1 2020 / M2 2022）。
  发布的是通用二进制，两种芯片都原生运行。
- app 本体需 macOS 11+。**开机自启**需 macOS 13+（其余功能在更低版本也能用）。

---

## 隐私与「会不会被封号？」

简短回答：**风险很低。** QuotaStrip 刻意做得很「礼貌」：

- **只读。** 只*查询*你的用量——和 Claude Code 自己显示 `/usage` 用的是同一个接口。
  从不发推理请求、不伪装客户端、不绕过任何东西。
- **本地优先。** Codex 数据从不离开本机，你的 Claude token 也从不离开本机。
- **尊重限流。** 收到 429 就完全按服务器要求（`Retry-After`）退避。

它和社区里其它用量小工具属于同一类。现实风险是 Anthropic 这个*非公开*用量接口哪天可能变
（最坏情况只是面板显示「no data」直到更新），而不是账号层面的问题。想更保守的话，
把 `quota.py` 里的 `CLAUDE_CACHE_TTL` 调大即可。

---

## 为什么会有 Gatekeeper 安全提示？

这是个免费开源项目，没有付费的 Apple 开发者账号（$99/年），所以 app 是 **ad-hoc 签名**、未公证，
macOS 首次打开会提示。二选一：

- **右键 →「打开」** 一次（之后就信任了），或
- 移除隔离属性：
  ```bash
  xattr -dr com.apple.quarantine /Applications/QuotaStrip.app
  ```

这是独立开源 Mac 工具（MTMR、Pock 等）的通用做法。源码都在这儿——你可以自己读、自己编译。

---

## 许可证

[MIT](LICENSE) © hohocf

Claude 和 Codex 的 logo 分别归 Anthropic 和 OpenAI 所有，此处仅用于标识各自的服务。
