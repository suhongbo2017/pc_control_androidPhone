# 常用配方

以下命令都假设已连接设备；扩展用户把 `android action=...` 当等价物即可。

## 屏幕与界面

```bash
adb shell dumpsys power | grep mWakefulness        # Awake / Dozing
adb shell input keyevent 224                       # 唤醒
adb shell wm dismiss-keyguard                      # 关无密码锁屏
adb shell uiautomator dump --compressed /dev/tty   # UI 树（直接输出到 stdout，不用 pull）
adb exec-out screencap -p > shot.png               # 截图
adb shell dumpsys activity activities | grep -m1 topResumedActivity
```

## 打开 App / 点按钮

```bash
# 已知包名：直接起
adb shell monkey -p com.android.settings -c android.intent.category.LAUNCHER 1
adb shell am start -n com.android.settings/.Settings

# 未知包名：找一下
adb shell cmd package list packages | grep -i -E "gallery|photos"

# 按文字点击：先 dump 找 bounds，再取中心点
adb shell uiautomator dump --compressed /dev/tty | grep -o 'text="蓝牙"[^>]*bounds="\[[0-9,]*\]\[[0-9,]*\]"'
adb shell input tap 251 1267
```

## 改设置（改完一定回读验证）

```bash
adb shell cmd uimode night yes                     # 深色模式
adb shell settings put system screen_off_timeout 60000
adb shell settings put system peak_refresh_rate 90
adb shell settings put global window_animation_scale 0.5
adb shell settings get system screen_off_timeout   # 回读
```

回滚清单见 `docs/troubleshooting.md` 末尾思路：把每个 `put` 的旧值记下来，用 `settings put/delete` 还原。

## 发短信（中文正文）

```bash
adb shell am start -a android.intent.action.SENDTO -d smsto: \
  --es sms_body '我今天有事不能过来了，你们先吃饭'
# 再填收件人 / 点发送 —— 发送前务必让用户确认
```

## Chrome 搜索（中文关键词）

```bash
adb shell am start -a android.intent.action.WEB_SEARCH --es query '我的世界' -p com.android.chrome
adb shell input keyevent 66      # 回车提交
```

## 取手机里的照片

```bash
# 时间范围（毫秒，UTC+8）内按时间升序，拿到 _data 路径
adb shell content query --uri content://media/external/images/media \
  --projection _id:datetaken:_size:_data \
  --where "datetaken>=1779638400000 AND datetaken<1779724800000" \
  --sort "datetaken ASC"
adb pull /storage/emulated/0/DCIM/Camera/IMG_20260525_090833.jpg ./a.jpg
```

查询技巧：

- 查不到先确认**前后最近的照片**（`--where "datetaken<A" --sort "datetaken DESC"`），别急着怀疑语句写错；
  整段空白通常就是那段时间真没照片
- 图片和视频在两张表：`.../images/media`、`.../video/media`（要合并排序自己拼）
- 名称里带时间的文件也可以直接文件系统找：`find /sdcard/DCIM -iname '*20260925*'`

## 检查耗电

```bash
adb shell dumpsys battery | grep -E "level|temperature|health|status"
adb shell dumpsys batterystats --charged | sed -n "/Estimated power use/,/^$/p" | head -20
# UID 级→包名映射
adb shell cmd package list packages -U | grep -E "uid:10(341|395)(,|$)"
```

## 检查存储

```bash
adb shell df -h /data | tail -1
adb shell du -sk /sdcard/DCIM /sdcard/Download /sdcard/Android/data 2>/dev/null | sort -n
```

## 检查广告面（HyperOS/MIUI）

```bash
for p in com.miui.systemAdSolution com.miui.analytics com.miui.hybrid com.xiaomi.market com.miui.weather2; do
  printf "%-30s " "$p"
  adb shell dumpsys package $p | grep -m1 -o "enabled=[0-9]"
done
adb shell settings get global ad_aaid                 # 个性化广告 ID（非 null = 开着）
adb shell cmd appops get com.miui.hybrid POST_NOTIFICATION
adb shell settings get secure enabled_notification_listeners
adb shell dumpsys activity services com.miui.systemAdSolution | head -3
```

止血（可回滚）：

```bash
adb shell cmd appops set com.miui.systemAdSolution RUN_IN_BACKGROUND ignore
adb shell cmd appops set com.miui.analytics RUN_IN_BACKGROUND ignore
adb shell cmd appops set com.miui.hybrid POST_NOTIFICATION ignore
# 回滚：把 ignore 换成 default
```

## 批量刷视频 + 归档（两阶段）

```bash
./scripts/capture.sh -n 10 -d 3 --skip-shopping   # 只采集，不识别
./scripts/montage.sh -p 5 -w 300                  # 5 条一张长图
# 读那一张图即可识别 5 条；结果写回 out/captures.tsv
```

判定"是否真的换了一条新内容"：

- 相邻帧 PSNR（`ffmpeg -i a.png -i b.png -lavfi psnr -f null -`）→ 低表示差异大
- 但直播会误判 → 还要比 `@作者/文案` 与顶层 Activity
