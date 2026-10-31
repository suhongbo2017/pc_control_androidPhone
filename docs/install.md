# 安装与连接

## 1. 准备 adb

adb 来自 Android SDK platform-tools，或直接用 [scrcpy](https://github.com/Genymobile/scrcpy) 发行包里自带的那份（免装 SDK）。

adb 查找顺序（扩展和脚本一致）：

1. `$PI_ANDROID_ADB`
2. `$ADB`
3. `$ANDROID_HOME/platform-tools/adb`、`$ANDROID_SDK_ROOT/platform-tools/adb`
4. 常见安装位置
   - Windows: `C:/Program Files/scrcpy/adb.exe`、`%LOCALAPPDATA%/Android/Sdk/platform-tools/adb.exe`
   - macOS: `/opt/homebrew/bin/adb`、`/usr/local/bin/adb`、`~/Library/Android/sdk/platform-tools/adb`
   - Linux: `/usr/bin/adb`、`/usr/local/bin/adb`、`~/Android/Sdk/platform-tools/adb`
5. `PATH` 里的 `adb`

## 2. 手机侧开关

设置 → 关于手机 → 连点「版本号」7 次 → 开发者选项：

- 打开 **USB 调试**
- Android 11+：打开 **无线调试**

## 3. 连接

### USB（最稳）

```bash
adb devices -l          # 看到 <serial> device 即成功
adb shell getprop ro.product.model
```

### 无线（Android 11+ 配对，无需 USB）

手机：开发者选项 → 无线调试 → **使用配对码配对设备**，屏幕上会给 `IP:配对端口` 和 6 位码。

```bash
adb pair 192.168.1.50:41234     # 端口是屏幕上的配对端口，不是 5555
adb connect 192.168.1.50:5555   # 连接端口通常是 5555（也可能随机，看屏幕）
adb devices -l
```

### 无线（老办法，需要一次 USB）

```bash
adb devices
adb tcpip 5555
adb connect 192.168.1.50:5555
adb disconnect                  # 拔线后仍走 Wi-Fi
```

注意：Wi-Fi 重连后**端口和 IP 可能变**，所以脚本里不要写死完整串口；用 `device` 的
model/codename 子串（如 `munch`、`22021211RC`）更稳，或用 `PI_ANDROID_DEVICE`。

## 4. 装上扩展 / skill

```bash
# 作为 pi package
pi install git:github.com/suhongbo2017/pc_control_androidPhone

# 或手动
cp extensions/android.ts ~/.pi/agent/extensions/
cp -r skills/android-control ~/.pi/agent/skills/
```

重启 pi。检查：让它执行 `android action=devices`，应列出设备。

## 5. 验证脚本链路

```bash
cd scripts
./phone.sh devices
./phone.sh wake
./phone.sh screen            # 应打印坐标 + class + text/id 的控件列表
```

## 6. 常见连接问题

| 现象 | 处理 |
|---|---|
| `adb devices` 显示 `unauthorized` | 手机上点「允许 USB 调试」，勾选「一律允许」 |
| 显示 `offline` | `adb kill-server && adb start-server`，重新插拔/重连 |
| 无线连不上 | 确认手机与电脑同一子网；部分路由 AP 隔离会挡住；用 `adb connect <ip>:<屏幕上的端口>` |
| 多设备时命令无法执行 | 扩展会强制要求 `device`；脚本用 `PI_ANDROID_DEVICE` |
| 关了「开发者选项」后 adb 全断 | 重新打开；无线调试还需要重新配对 |
