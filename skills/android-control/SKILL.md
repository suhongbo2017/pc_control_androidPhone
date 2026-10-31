---
name: android-control
description: 通过 adb 控制已连接的安卓手机（读 UI 树、按文字点击、输入、按键、开关 App、改设置、批量刷视频并归档截图）。当用户说"打开某 App"、"点某个按钮"、"把手机设置改成…"、"刷 N 条视频并记录"、"检查手机状态/设置/广告"、"从手机取图/发短信"等涉及真机操作时使用。依赖 pi-android 扩展提供的 android 工具（或 scripts/phone.sh）。
---

# 安卓真机控制（adb）

配套资源：`extensions/android.ts`（注册 `android` 工具）、`scripts/phone.sh`（人工/脚本用）、
`scripts/capture.sh` + `scripts/montage.sh`（两阶段批量采集与识别）。

## 第一步永远是"看"

- 有工具时：`android action=screen`（先不带参数，必要时用 `query` 过滤）
- 只有 bash 时：`scripts/phone.sh screen`
- 屏幕**息屏/锁屏**时 UI 树只有一个 `com.android.systemui` 根节点 → 先 `action=wake`（或 phone.sh wake）

多设备时必须指定设备（serial 可写全串或 model/codename 子串；Wi-Fi 重连后端口会变，别写死端口）。

## 快路径优先，慢路径兜底

按顺序尝试，前一个能成就别点界面：

1. **直接改状态**：`shell` + `cmd uimode night yes`、`settings put system screen_off_timeout 60000`、`svc wifi disable`
2. **直接起界面**：`am start -a android.settings.DISPLAY_SETTINGS`、`am start -n pkg/.Activity`
3. **带参数的深链**（中文也能带进去）：`am start -a android.intent.action.SENDTO -d smsto: --es sms_body '中文内容'`、`am start -a android.intent.action.WEB_SEARCH --es query '关键词' -p com.android.chrome` 然后 `key enter`
4. 最后才 `screen` → `tap target="文字"` → 再 `screen` 验证

`target` 用**界面文字**，不要记死坐标；点完必须再 `screen` 一次确认跳转（Activity 变了/目标节点出现）。

## 中文输入

`input text` 只支持 ASCII。要输入中文：用 App 的深链 extra（`sms_body`、`query` 等），
或者装 ADBKeyboard 切输入法，或在手机端用 `termux-clipboard-set` + 长按粘贴。不要试图 `input text 中文`。

## Token 纪律

- 默认用 `screen` 的文本树，**不要**用截图；`shot` 一张 1080p 约 500KB base64，几十张就爆上下文
- 截图只在 UI 树没有文字时用（画布、游戏、纯图像界面）
- 需要看多条视频/多张图时走**两阶段**：
  1. `scripts/capture.sh -n N -d 3 --skip-shopping`（只截图 + 写 TSV，不识别）
  2. `scripts/montage.sh -p 5`（拼成一张长图）→ 只读 1 次图，识别 5 条
- 每次观察 `uiautomator dump` 约 2.5–3s，一次"看→点→验"约 8–12s，别设计 50 轮的长循环

## 采样/刷流水的判定规则

- **PSNR 不能单独用来判断"是否新内容"**：直播和动态视频本身在动，相邻帧 PSNR 会很低但内容没换；要同时看**作者/文案是否变化**和**顶层 Activity 是否变化**
- 停在**直播间**时上滑常被"点击进入直播间"浮层吃掉 → 表现为"滑了没反应"
- 横屏剧集（`LandscapeFeedActivity`）里上滑是**切换分集**，不是换视频
- 滑动要足够"慢/长"：`input swipe 540 2100 540 300 500`（1400–1800px、500ms）；250ms 的快速滑动在部分 App 里会被当成 fling 而回弹
- 只按 UI 关键词判"购物/广告"时，**不要**把导航栏词（购物、商城、团购）算进去，否则几乎每条都命中；用 `广告|立即咨询|点击进入直播间|消费券|已售|讲解中|券后|领券|立即购买|购物车|小店|下单`

## HyperOS / MIUI 专项坑

| 现象 | 正确做法 |
|---|---|
| `pm list packages` 输出为空（包数为 0） | 用 `cmd package list packages`（本机 549 个包能正常列出）；`pm` 在这类 ROM 上可能被裁剪/受限 |
| `pm disable-user --user 0 <系统包>` 报 `SecurityException: Cannot disable system packages` | 改用 `cmd appops set <pkg> RUN_IN_BACKGROUND ignore` + UI 开关；要真停用需 Shizuku/root |
| 单引号包整串多命令 `adb shell 'a; b'` 返回 255、无输出 | 改用双引号或每次只跑一条命令 |
| `adb pull /sdcard/...` 在 Git Bash 里路径被改写 | `export MSYS_NO_PATHCONV=1`，或用 `C:/...` 输出路径 |
| 亮屏但 `uiautomator dump` 只返回一个 systemui 节点 | 先 `input keyevent 224` + `wm dismiss-keyguard`，再 dump |
| 锁屏有密码 | 无 root/Shizuku 无法自动解锁，直接告诉用户需要手动解锁 |

## 常见任务的配方

**打开 App**：`action=launch pkg=com.xxx`（或 `monkey -p`）→ 等 2–6s → `action=screen` 确认 `focus=`
**从桌面图标点开**：`screen` 找到 `text="相册"` 之类 → `tap target="相册"`
**改系统设置**：`shell "settings put system ..."` / `cmd uimode night yes`，改完 `settings get` 回读验证
**发短信（中文）**：`am start -a android.intent.action.SENDTO -d smsto: --es sms_body '内容'` → 填收件人 → 让用户确认再发
**取一张照片**：`content query --uri content://media/external/images/media --projection datetaken:_data --where "datetaken>=A AND datetaken<B" --sort "datetaken ASC"`（A/B 为毫秒时间戳，UTC+8）→ `adb pull`
**查看某天照片**：同上范围查询；注意 2026 年 7–9 月这种整段空白说明那段时间确实没照片（先用前后最近项验证，而不是怀疑查询写错）
**检查耗电/存储**：`dumpsys battery`、`dumpsys batterystats --charged | sed -n '/Estimated power use/,/^$/p'`（含 UID 级耗电，再用 `cmd package list packages -U | grep uid:<n>` 映射包名）、`df -h /data`、`du -sk /sdcard/* | sort -n`
**检查广告面**：`dumpsys package com.miui.systemAdSolution | grep -m1 enabled=`、`cmd appops get <pkg> POST_NOTIFICATION`、`settings get global ad_aaid`、`settings get secure enabled_notification_listeners`

## 安全边界

- 不经用户确认**不发送**消息/不删除文件/不卸载应用/不改系统级开关
- `adb` 无线调试端口（5555 / 随机端口）只能待在局域网或 VPN 内，绝不要暴露到公网
- 涉及隐私内容（照片、短信、聊天）只报告用户要求的范围，不主动扩散
