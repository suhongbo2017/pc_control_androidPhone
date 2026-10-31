# pi-android

用 **adb** 让 AI agent（[pi](https://github.com/earendil-works/pi-coding-agent) 及兼容 harness）真正操作一台安卓手机：
读 UI 控件树、按文字点击、输入、按键、开关 App、改系统设置、批量刷视频并归档截图。

> Drive a real Android phone (USB or wireless adb) from an AI agent: compact UI trees instead of screenshots,
> tap-by-text, safe multi-device handling, and a two-phase "capture first, recognize once" workflow.

## 这是什么（不是 skill，是扩展）

| 层 | 形态 | 作用 |
|---|---|---|
| `extensions/android.ts` | **pi 扩展**（TypeScript，注册工具） | 提供 `android` 工具：`devices/screen/tap/type/key/swipe/launch/stop/shell/shot/wake/wait` |
| `skills/android-control/` | **skill**（Markdown 说明书） | 告诉模型"该怎么用"：快路径优先、验证闭环、踩过的坑 |
| `scripts/*.sh` | 普通 shell 脚本 | 给没有扩展的场合用（或人工用）：`phone.sh`、`capture.sh`、`montage.sh` |
| `adb` | 外部软件（Android SDK platform-tools / scrcpy 自带） | 真正的执行层 |

扩展提供"手脚"，skill 提供"判断力"，脚本提供"没有 pi 时的兜底"。

## 特性

- **省 token**：`screen` 返回压缩后的文本控件树（坐标 + class + text/id + 状态），不用截图
- **按文字操作**：`tap target="蓝牙"` 每次现读 bounds 取中心点，不硬编码坐标
- **息屏自愈**：先用 `dumpsys power` 判断 `mWakefulness`（0.3s），需要时唤醒再 dump（比盲目 dump 两次省 ~3s）
- **多设备保护**：同时连着多台时**必须**指定 `device`，否则报错并列出候选，避免误操作
- **两阶段流水线**：`capture.sh` 只截图落盘（不识别） → `montage.sh` 拼长图 → 一次读图识别 N 条
- **无依赖**：扩展只用 Node 内置模块（`node:child_process`/`fs`/`os`/`path`）

## 安装

### 1) 准备 adb 与手机

```bash
# 手机：开发者选项 → 开启 USB 调试；Android 11+ 用「无线调试」配对
adb pair 192.168.1.50:41234      # 输入手机屏幕上的 6 位配对码
adb connect 192.168.1.50:5555
adb devices -l                   # 确认出现 <serial>  device
```

adb 可用 Android SDK platform-tools，或直接用 [scrcpy](https://github.com/Genymobile/scrcpy) 压缩包里自带的那份。

### 2) 装扩展

```bash
# 方式 A：把本仓库当 pi package 安装（推荐，会同时装上 skill）
pi install git:github.com/suhongbo2017/pc_control_androidPhone

# 方式 B：手动拷文件
cp extensions/android.ts  ~/.pi/agent/extensions/
cp -r skills/android-control ~/.pi/agent/skills/
```

重启 pi 后，模型就会多出一个 `android` 工具。

### 3) 环境变量（可选）

| 变量 | 作用 |
|---|---|
| `PI_ANDROID_ADB` | 指定 adb 可执行文件路径（默认自动在 PATH / ANDROID_HOME / scrcpy 目录里找） |
| `PI_ANDROID_DEVICE` | 默认设备（serial，或 model/codename 子串），省去每次传 `device` |

## 用法示例

在 pi 里直接说人话即可：

- 「看下手机现在什么界面」→ `android action=screen`
- 「点蓝牙」→ `tap target="蓝牙"`（先 dump 找控件、中心点现算）
- 「把深色模式打开」→ 先试 `shell "cmd uimode night yes"`（一步到位），不成再点界面
- 「打开相册，告诉我 9 月 25 日第一张照片是什么」→ `launch` → 必要时 `content query` 查 MediaStore → `pull` 后看图
- 「每 5 秒刷一条视频，刷 5 条，跳过购物类的」→ `capture.sh -n 5 -d 5 --skip-shopping` + `montage.sh` + 一次识图

只有 bash 的场合：

```bash
./scripts/phone.sh screen                 # 紧凑 UI 树
./scripts/phone.sh tap "蓝牙"              # 按文字点
./scripts/phone.sh shell "settings put system screen_off_timeout 60000"
./scripts/phone.sh shot out.png
```

## 微信发消息（一次调用 ≈12 秒）

```bash
# 需要先装 ADBKeyboard（脚本会处理小米的"继续安装"确认）
./scripts/install_adbkeyboard.sh

# 发消息：搜索词 + 正文都支持中文，正文经 ADBKeyboard 精确注入（不走输入法候选，不会错字）
PI_ANDROID_DEVICE=<serial> ./scripts/wechat_send.sh -q "阿宿" -m "我是苏洪波"

# 只填不发，用于确认目标聊天是否正确
./scripts/wechat_send.sh -q asu -m "测试" --dry
```

实测：**12.1 秒/条**（含 1 张验证截图），对比"逐步截图思考"的 ~10 分钟。
发送按钮不是硬编码坐标，而是按微信绿 `#07C160` 做像素定位，键盘开合都能命中。

## 两阶段批量流水线（省 token 的关键）

```bash
# 阶段 1：只采集。每条：上滑 → 停留 d 秒 → 截图 → 记时间/PSNR/顶层 Activity
./scripts/capture.sh -n 10 -d 3 --skip-shopping

# 阶段 2：拼图，5 条一张长图
./scripts/montage.sh -p 5 -w 300

# 然后只读 1 次图，就能识别 5 条内容
```

产出：`out/captures.tsv`（含 `idx/time/dwell/psnr/shop/activity/shot`）+ `out/shots/*.png`。

实测：5 条采集 ≈ 29 秒（5.8s/条），旧流程（每条截图+读图）需要 10 次工具往返，新流程 3 次。

## 项目结构

```
extensions/android.ts          pi 扩展：android 工具（唯一必需文件）
skills/android-control/        SKILL.md：使用规范 + 已知坑
scripts/lib.sh                 公共函数：找 adb、选设备、wake、紧凑 UI 树
scripts/phone.sh               人工/无扩展时的小工具
scripts/wechat_send.sh         微信发消息（ADBKeyboard 精确输入 + 像素定位发送键）
scripts/install_adbkeyboard.sh 安装/启用 ADBKeyboard（自动点掉 MIUI 的 USB 安装确认）
scripts/capture.sh             阶段 1：批量采集（不识别）
scripts/montage.sh             阶段 2：拼长图（一次识图）
docs/install.md                安装与无线调试细节
docs/troubleshooting.md        踩过的坑全集（含现象/原因/解法）
docs/recipes.md                常用任务配方（发短信、取图、改设置、检查耗电/广告）
docs/architecture.md           为什么这样设计：扩展 vs skill、token 经济、验证闭环
```

## 能力边界

| 限制 | 说明 |
|---|---|
| 锁屏密码 | 无 root / Shizuku 无法自动解锁；`wake` 只能亮屏 + 关无密码 keyguard |
| 中文输入 | `input text` 只支持 ASCII；中文走 App 深链 extra 或 ADBKeyboard |
| 观察成本 | `uiautomator dump` 约 2.5–3s/次；"看→点→验"一轮 8–12s |
| HyperOS/MIUI | `pm` 可能不可用（用 `cmd package`）；系统包不能 `disable-user`（用 `appops` 或 UI 开关） |
| 权限天花板 | `adb shell` 是 shell 用户，读不到其他 App 私有数据、改不了系统分区 |
| 安全 | 无线调试端口只能在局域网/VPN 内，暴露公网等于把手机 shell 交出去 |

## 许可

MIT，见 [LICENSE](LICENSE)。
