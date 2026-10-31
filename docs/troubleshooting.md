# 踩过的坑（现象 / 原因 / 解法）

这些都是真机上验证过的，不是猜测。按"卡住时长"排序。

## 1. `sh: /path/to/binary: not found` —— 其实是缺 glibc 动态链接器

**现象**：在 Termux 里跑从网上下载的 Linux 二进制（例如某个用 Bun/Go 打包的 CLI），文件明明存在、
`chmod +x` 也做了，却报 `not found`（不是 `Permission denied`）。

**原因**：那个二进制是 **glibc** 链接的：

```
ELF 64-bit LSB executable, ARM aarch64
需要解释器：/lib/ld-linux-aarch64.so.1
依赖：      libc.so.6 (GLIBC_2.17)
```

Android 用的是 **bionic**（`/system/bin/linker64` + `libc.so`），没有 `/lib/ld-linux-aarch64.so.1`，
内核找不到解释器 → shell 报 `not found`。

**判定**：

```bash
pkg install file binutils
file ~/.local/bin/xxx
readelf -l ~/.local/bin/xxx | grep -i interpreter
ls /lib/ld-linux-aarch64.so.1        # 不存在 → 结论确凿
```

**解法**（按可靠性排序）：

1. `pkg install proot-distro && proot-distro install debian && proot-distro login debian`，在 Debian 里装（glibc 齐全）
2. Termux 的 glibc 兼容层（termux-pacman 的 `glibc-runner`）：`grun ./xxx`
3. 换成 Termux 官方仓库里已有的包（`pkg search`）

**通用结论**：Musl 系发行版（Alpine）和 glibc 系可以互不通；判断一个"外国二进制"能不能在手机上跑，
先看它的 ELF interpreter，而不是看架构（arm64 对得上也会挂）。

## 2. `pm list packages` 输出为空

**现象**：`adb shell pm list packages | wc -l` → 0；但 `dumpsys package packages | grep -c "Package \["` → 549。

**原因**：部分 HyperOS/MIUI 机型上 `pm` 被裁剪或受限。

**解法**：改用 `cmd package list packages`（含 `-3`、`-U` 等参数都可用）。

## 3. 不能 `pm disable-user` 系统包

**现象**：`java.lang.SecurityException: Cannot disable system packages.`
（`PackageManagerServiceImpl.canBeDisabled`）。

**原因**：MIUI/HyperOS 在框架层加了白名单，shell 无权停用系统包（AOSP 本来允许）。

**解法**：

- `cmd appops set <pkg> RUN_IN_BACKGROUND ignore`（可回滚，实际能止血）
- 设置里的官方开关（如 设置 → 密码与安全 → 系统安全 → 广告服务）
- 想真正停用需要 Shizuku / root

## 4. 息屏时 UI 树只有一个 `com.android.systemui` 节点

**现象**：`uiautomator dump` 只返回一个 `FrameLayout`，而且耗时反而更久（2.5–9s）。

**原因**：设备处于 Dozing，界面没有可读内容。

**解法**：

```bash
adb shell dumpsys power | grep mWakefulness      # 先花 0.3s 判断
adb shell input keyevent 224                     # KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
```

扩展里就是先判断再唤醒，单次观察从 8s 降到 3.9s。**有密码的锁屏唤不醒到可用状态**，只能请用户手动解锁。

## 5. Git Bash 把 `/sdcard/...` 改写成 `C:/Program Files/Git/sdcard/...`

**现象**：`adb pull /sdcard/DCIM/a.jpg out.jpg` → `failed to stat remote object 'C:/Program Files/Git/sdcard/...'`。

**原因**：MSYS2 的路径自动转换。

**解法**：`export MSYS_NO_PATHCONV=1`；或在输出路径上用 `C:/...` 绝对路径；或用 `//sdcard/...`。

## 6. `adb pull` 输出到 `/tmp/...` 失败

**原因**：Git Bash 里的 `/tmp` 对 Windows 原生程序（adb.exe）不存在。

**解法**：给 adb 的输出参数用 Windows 路径（`C:/Users/.../out.png`），别用 `/tmp`。

## 7. 单引号包整串多命令返回 255

**现象**：`adb shell 'echo A; getprop ro.product.model'` → 无输出、exit 255；改成双引号或单条命令就正常。

**解法**：用双引号；或者一条 adb 调用只跑一次命令（脚本里 `sh_()` 就是这么做的）。

## 8. `adb devices` 解析失败（自己写脚本时）

**现象**：`devices -l` 明明有输出，正则 `^(\S+)\s+(\S+)(.*)$` 却匹配不到。

**原因**：输出行尾是 `\r\n`，而 JS 的 `.` **不匹配** `\r`。

**解法**：先 `line.trim()` 再匹配（扩展里已修）。

## 9. 上滑不生效 / 滑了又弹回

**现象**：`input swipe x1 y1 x2 y2 250` 之后画面没变。

**原因**：

- 停在**直播间**时，滑动被「点击进入直播间」浮层吃掉
- 250ms 的快速短滑被当成 fling，直接弹回

**解法**：用更长更慢的手势 `input swipe 540 2100 540 300 500`（1400–1800px、500ms）；
同时**验证**：滑动前后截图 PSNR 或顶层 Activity 是否变化。

## 10. PSNR 变化 ≠ 换了视频

**现象**：相邻两帧 PSNR 14.2（差异很大），但内容其实是同一条直播。

**原因**：直播/动态画面本身一直在变。

**解法**：判定"新内容"要三件套：**截图 PSNR + 作者/文案是否变化 + 顶层 Activity 是否变化**。
直播场景可以直接读 UI 文本里的 `@作者` 比对。

## 11. 横屏剧集里上滑是"换分集"

**现象**：在 `LandscapeFeedActivity` 里连续上滑，画面一直变，但一直在同一部剧里。

**解法**：看底部有没有「第一集…第 N 集」分集条；要换视频先 `key back` 回竖屏推荐流。

## 12. 关键词判购物类几乎全部命中

**现象**：用 `团购|商城|购物` 判"购物类视频"，10 条里 8 条命中。

**原因**：这几个词是**顶部导航标签**（直播/关注/团购/商城/推荐），每条视频的 UI 树里都有。

**解法**：换成内容级关键词：`广告|立即咨询|点击进入直播间|消费券|已售|讲解中|券后|领券|立即购买|购物车|小店|购物车|下单|¥`。

## 13. `input text` 打不进中文

**原因**：`input text` 只处理 ASCII（还会把空格当分隔符，需要 `%s`）。

**解法**：

- 用 App 的深链 extra：`am start -a android.intent.action.SENDTO -d smsto: --es sms_body '中文'`、
  `am start -a android.intent.action.WEB_SEARCH --es query '我的世界' -p com.android.chrome`（然后 `keyevent 66` 提交）
- 装 ADBKeyboard 并 `settings put secure default_input_method` 切过去，用广播发送文本
- 在手机端有 Termux 时：`termux-clipboard-set "中文"`，再长按输入框粘贴

## 14. `monkey` 启动 App 后前台又变回桌面

**现象**：`am start` 报告成功、`topResumedActivity` 是目标 App，但几秒后又回到桌面/应用抽屉。

**原因**：界面状态被别的窗口接管（例如上一次手势把「应用抽屉」打开了），任务被压到后台。

**解法**：先 `input keyevent 3`（HOME）收干净 → `am start -n pkg/.SplashActivity` → 轮询
`dumpsys activity activities | grep -m1 topResumedActivity` 直到目标 App 稳定在前台（可能要 10–12s）。

## 15. `pi` 没有内置 MCP / 也没有内置 android 工具

**说明**：pi 的设计是"内核小 + 扩展"，MCP 需要靠扩展或外部工具。要让模型获得"控制手机"这种新能力，
必须写 **extension**（`pi.registerTool`），skill 只能教它怎么用已有的工具。

## 16. 在 pi 里改代码时别用 heredoc 传反斜杠

**现象**：用 `python - <<'PY'` 写含 `\r?\n` 的代码，落到文件里变成真正回车 → 语法错误 `Unterminated regexp literal`。

**原因**：命令在传给 bash 之前已经被 JSON 解码过一轮，`\\r` 变 `\r`。

**解法**：改写用编辑工具（精确替换），或者把反斜杠再加倍。

## 17. 微信界面没有任何可访问性节点

**现象**：`uiautomator dump` 对微信返回 0 个带文字节点（连输入框都读不到），但系统分享面板
（`com.android.intentresolver`）、设置页等**有**节点。

**解法**：微信只能"截图 + 坐标"操作；所有核对改成 **OCR 截图**。Windows 自带 OCR 可直接用，
无需安装：`scripts/ocr.ps1`（`Windows.Media.Ocr`），注意传**反斜杠绝对路径**，输出要显式设 UTF-8。

## 18. HyperOS 上 `adb install` 报 INSTALL_FAILED_USER_RESTRICTED

**现象**：`adb install` / `pm install` 都失败，提示 `Install canceled by user`；手机上没有可点的对话框。

**原因**：MIUI 的「USB 安装」开关 + 每次安装会弹 `com.miui.securitycenter/.permcenter.install.AdbInstallActivity`
（标题「USB 安装提示」，按钮「继续安装（8）」带 8 秒倒计时，超时自动取消 = "canceled by user"）。

**解法**：后台跑安装，同时立刻点「继续安装」（`scripts/install_adbkeyboard.sh` 就是这个握手）。
注意 `settings put global adb_install_need_confirm 0` 在这类 ROM 上**无效**。

## 19. 输入法候选法打不准人名

**现象**：打 `woshi'su'hong'bo`，讯飞候选是「我是苏红波 / 我是苏宏博」，**没有「洪」**；
逐字选要点 4–6 次、每次都要截图确认。

**解法**：装 ADBKeyboard，用 `am broadcast -a ADB_INPUT_B64 --es msg <base64>` 一次写入原文（CJK 全支持）。
装好后整个流程只在开头切一次输入法，结尾用 `trap EXIT` 还原。

## 20. 语音模式静默吞掉文本注入

**现象**：`ADB_INPUT_B64` 广播返回成功，但输入框仍显示「按住说话」，内容没进去。

**原因**：输入框处于语音模式，不接受文本注入。

**解法**：点输入框**最左侧**（紧挨"按住说话"左边）的小键盘图标切回文字模式，切完再注入；
并把"是否仍显示按住说话"作为发送前的一个检查点。

## 21. 微信搜索页布局不固定，第 1 行可能是聊天记录

**现象**：搜「李小文」直接点第 1 行，打开的是另一个人「杰」的聊天；搜「李小姐」时联系人行在
y≈546，而搜「阿宿」时在 y≈621（有"最常使用"分组时整体下移）。

**解法**：不要固定行坐标 —— **逐行试探 + 标题核对**：点一行 → OCR 标题 → 不含目标就 `keyevent 4`
退回再试下一行（默认 5 行）。分组标题（"联系人"/"最常使用"）OCR 不稳定，**不要**当硬判据，
只用"目标名字是否出现"。

## 22. 微信绿色发送按钮：视觉位置 ≠ 可点区域

**现象**：按截图里「发送」按钮的视觉中心 `(771, 2301)` 点击毫无反应；纵向扫描后发现命中区在
**y≈2180**（往上约 120px）。`input tap` 和 `input motionevent` 表现一致。

**解法**：不要硬编码 —— 按微信绿 `#07C160` 做**像素定位**（ffmpeg 解 raw RGB + 取中位数），
或做纵向扫描（每 40px 试一次，用顶层 Activity 变化判断是否命中）。

## 23. 无线 adb 端口每次重连都会变

**现象**：`PI_ANDROID_DEVICE=192.168.102.21:38125` 突然报 `device not found`，实际端口已变成 `:44977`。

**解法**：用 **codename/model**（如 `annibale`、`2510DRK44C`）做设备标识；`scripts/lib.sh` 的
`device()` 会在 `adb devices -l` 里把 model/codename 解析成当前 serial。
