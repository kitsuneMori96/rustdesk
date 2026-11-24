# 排障手册（Windows 被控端 / 手机端）

这份文档不是功能说明，是「下次遇到问题怎么自己查」的手册。
里面每一条结论都是真机 + 日志 + 探针验出来的，不是推出来的。
功能与测试项在 `CHECKLIST.md`，构建步骤在 `ANDROID_BUILD_NOTES.md`，协作分工在 `COLLABORATION.md`。
历史案例复盘已移入 `TROUBLESHOOTING-ARCHIVE.md`，本文只留当前有效的排查方法与已知坑。

约定：文档里不写密码、Peer ID、公网 IP。

---

## 0. 四步法

任何「不好使了」的反馈，按这个顺序走，不要跳步：

1. 取证：先证明代码在跑、命令收到了、走到了哪一行。没有日志就先去埋日志，别猜。
2. 归因：把时间线上的所有症状排在一起看。多个症状经常是同一个原因。
3. 最小修复：只改导致现象的那一处。修完能解释全部症状才算找对了。
4. 复测：给出一条能证伪的验证（日志里应该出现哪一行、界面上应该看到什么）。

反例（这次真踩了）：用户报「自动解锁没行动」，我第一反应是逻辑不对，
实际上一半是判定误报、一半是那次根本不该成功（锁屏期间系统禁止改显示模式）。
如果先取证，两条日志就能定死。

---

## 1. 环境与日志地图

### 进程拓扑（这条决定日志在哪）

- `RustDesk.exe --service`：会话 0，SYSTEM。它负责拉起登录会话里的 server。
- `RustDesk.exe --server`：会话 1（当前登录用户），SYSTEM。**被控端功能代码跑在这里**，
  锁屏输入、显示模式、DPI 缩放都必须是这个进程才有权限。
- `RustDesk.exe --tray` / 前台 UI：会话 1，用户权限。
- 只有 `--server` 的日志进 `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log\server\`。
  你在 `%APPDATA%\RustDesk\log\` 里翻不到被控端行为是正常的，那里只有 UI 和 `cm`（剪贴板/文件）。

### 日志路径速查

- 被控端（服务）：`C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log\server\RustDesk_rCURRENT.log`
- 桌面 UI：`%APPDATA%\RustDesk\log\RustDesk_rCURRENT.log`
- 剪贴板 / 文件传输：`%APPDATA%\RustDesk\log\cm\`

### 「部署生效」怎么判定（别信 cp 成功）

已加载的 DLL 可以直接改名替换（本机验证过），但老进程仍跑旧镜像。所以：

1. 覆盖：当前 DLL 改名成 `.old` → 拷新的进去 → 删 `.old`（不要直接 `cp` 覆盖，可能被占用失败）。
2. `Restart-Service rustdesk`，让 `--service` 重新拉起 `--server`。
3. 证据 = 新 `--server` 进程 + 它的日志起始时间在你拷贝之后。
   `Get-CimInstance Win32_Process -Filter "Name='RustDesk.exe'" | Select ProcessId,SessionId,CommandLine`
4. 只看到服务 Running 不够，`--service` 在会话 0，跑旧镜像的往往是会话 1 那个没换。

### 文件被占用

装过 UU远程 / 托盘常驻的 RustDesk.exe 会锁住 DLL；用 QQ 传过的 APK 也会锁住导致 `packageRelease` 失败。
查占用用 Restart Manager（`rstrtmgr`，`RmGetList`），别乱 `kill`，先问用户。

---

## 2. 通用套路

### 2.1 先证明「收到」，再证明「收到后做了什么」

命令通道两端各埋一行日志，行号 + 关键入参的**特征**（不要写明文）。
一条消息「没反应」，先分清是没收到、还是收到了被前面的分支拦掉。

### 2.2 把布尔判定拆成多状态

`is_lock_screen() -> bool` 出问题时你只能猜。改成带状态码 + 把判据本身打进日志：

    -1 打不开输入桌面
     0 输入桌面不是 Winlogon（顺带记桌面名）
     1 是 Winlogon 但桌面里没有 LogonUI 窗口（UAC 安全桌面 / 切换瞬间）
     2 真锁屏

日志里那句 `skipped, state 0 desktop "Default"` 直接把根因指到「桌面名对不上」，
而原来那句 `skipped, not at the lock screen` 只会把人引向「代码逻辑错了」。

### 2.3 别信直觉，用探针独立验证 API 语义

不确定 Win32 API 在你这个编译单元里到底是 A 版还是 W 版、返回什么编码？
写个十几行的 P/Invoke 探针（`pwsh.exe`，不要用 PowerShell 5.1）直接调一次，看返回值。
这次就是探针打出 `desktop=Default`，才确认 `GetUserObjectInformation` 走的是 A 版。

探针脚本放系统临时目录，用完删掉，别留进仓库。

### 2.4 时间线对齐

把所有症状的时间戳抄到一行一行对照，再和日志、和用户操作顺序对。
本次对齐后的结论：22:07:24–29 防窥 commit 连环失败 + 22:07:29 解锁判「未锁屏」+ 22:07:51 `Desktop switched`
→ 电脑当时**确实锁着**，所以防窥必然开不起来，而解锁判定是误报。
症状「我的隐私屏设置又被改成关闭了」其实是「那次开启从没成功」，不是设置被写坏。
这一步省掉了至少一轮错误修复。

### 2.5 重试要有前提：失败原因是否会自己消失

- 会消失（锁屏期间禁止改显示模式、驱动刚插还没 ACTIVE）→ 轮询等待 / 延后重试，重试期间不打扰用户（不弹框、不 toast）。
- 不会消失（版本不支持、没权限）→ 干净失败 + 明确提示，别做 machinery 硬撑。
- 重试链路里**不要重复非幂等的动作**。`plug_in_monitor` 有数量上限、重复插会弹错误框，
  所以客户端要记住「这次会话已经预插过了」。

### 2.6 新旧版本共存用能力位

手机端会连到旧主机（官方 DLL / 旧自编译 DLL）。任何新协议都必须：

- 主机在 `platform_additions` 里报能力位（例如 `uu_auto_unlock`）；
- 客户端先查能力位，缺就走旧路径（旧的一次性盲输），不能让旧主机收到看不懂的命令。

反例：`uu:unlock:` 复用防窥 `impl_key` 通道，旧主机收到会当成隐私模式实现键处理，行为不可预期。

### 2.7 版本号混搭会直接崩

原生层复用官方 1.5.3 的 `librustdesk.so`，Dart/Kotlin 必须基于 tag `1.5.3`。
master 的 Kotlin 调了 1.5.3 里没有的 JNI（`setInputServiceOpen` 等），混搭是 `UnsatisfiedLinkError` 闪退。
所以「升级上游」和「换原生层」必须一起做，不能只换一边。

---

## 3. Windows 侧已知坑（现象 / 根因 / 正确写法）

### 3.1 A/W 宏陷阱：没定义 UNICODE，A/W 后缀函数会走 A 版

- 现象：桌面名比较永远不相等；文本处理看起来「什么都没发生」。
- 根因：`src/platform/windows.cc` 这个编译单元没有定义 `UNICODE`，
  于是 `GetUserObjectInformation`、`GetTextMetrics` 这类不带显式后缀的调用解析到 **A 版**，
  返回 **ANSI**。既有代码本来就用 `char[] + strcmp`，不是随便写的。
- 错误写法：`WCHAR name[256]` + `_wcsicmp(name, L"Winlogon")` → 永远 false。
- 正确写法：`char name[256]` + `_stricmp(name, "Winlogon")`。
- 通用规则：改这个文件之前先看邻居代码用什么类型；要用 W 版就显式写 `...W`。

### 3.2 虚拟屏设备名的 NUL 填充

- 现象：明明只插一块屏，DisplayConfig 里查不到 / 匹配不上；缩放「设了没生效」。
- 根因：`DISPLAY_DEVICEW.DeviceName` 是 `[WCHAR; 32]`，剩下全是 NUL。直接拿整串去匹配必然失败。
- 正确写法：按第一个 NUL 截断，再喂给 DisplayConfig / `change_resolution`。

### 3.3 锁屏（Winlogon 安全桌面）

四条都踩过，合起来才解释得通「密码对，但报密码错」：

1. 输入注入必须先把当前线程切到输入桌面：`SwitchDesktop`（我们的封装 `try_change_desktop()`）。
   只给 Chr 路径切了、Seq 路径没切 → 密码落到用户桌面被丢弃。
2. 通道选择：锁屏密码框只认 **Seq** 通道（`sessionInputString`）；
   逐字符 `inputKey` 走 Chr 路径会被丢。
3. `ChangeDisplaySettingsEx` 在锁屏期间被拒绝：`ret: -1`，`GetLastError: 0`。
   所以防窥在锁屏下必然开不起来，别当成驱动/NUL 回归去修。
4. LogonUI 会吞掉第一击（用来收起锁屏浮层）。注入密码前先 tap 一个无文本效果的修饰键（VK_SHIFT）。
5. 锁屏 vs UAC 安全桌面：两者桌面名都是 Winlogon。
   靠 `EnumDesktopWindows` 里有没有 `LogonUI.exe` 的窗口区分
   （`QueryFullProcessImageNameW` 取文件名比对）。判错会把密码注进 UAC 提示框。

### 3.4 `CDS_RESET` 会点亮别人的残留屏

- 现象：调分辨率/缩放之后，Windows 设置里冒出一堆虚拟屏。
- 根因：`ChangeDisplaySettingsExW` 的 `CDS_RESET` 提交会把其它 IDD 驱动下
  「attached 但没有模式」的显示器一并激活（本机 UU/GameViewer 有 9 个、Amyuni 2 个）。
- 正确写法：提交后主动用 `CDS_UPDATEREGISTRY | CDS_NORESET` 把多余的活动屏禁掉。
  日志行 `Privacy mode disabled extra display ...` 就是这段在工作。
- 顺带：`EnumDisplayDevicesW` 第 2 个参数传设备名字符串指针 = 按该设备过滤，传 NULL 才是全枚举。

### 3.5 Amyuni usbmmidd 虚拟屏

- `plug_in_monitor` **非幂等**、有数量上限，超了返回「already plugged」并弹客户端消息框。
  重试链路必须记住已预插（我们的 `_privacyPreplugged`）。
- 插入后约 6 秒才 ACTIVE，服务端只等 5 秒会误判失败。客户端节奏：预插 → 4s 发 on → 12s 重试 → 20s 回滚。

### 3.6 DPI 缩放

- 写注册表 `PerMonitorSettings` **无效**：系统缓存，要注销才生效（真机实测仍 100%）。
- 正确做法：DisplayConfig 的未公开设备信息类型 `-3`（GET_SOURCE_DPI_SCALE）/ `-4`（SET_SOURCE_DPI_SCALE），
  直接 `DisplayConfigGetDeviceInfo` / `DisplayConfigSetDeviceInfo`。
- 必须在**登录会话的 `--server` 进程**里调。会话 0 的服务进程查询返回 0 条路径（探针实测）。
- 用户可能手动改过缩放：系统仍是推荐值 → 套用存储值；用户改过 → 保留并写回状态。别覆盖用户选择。

### 3.7 音频

- 协议的 `disable-audio` 只停串流，不关电脑扬声器。
- 1.5.3 官方主机没有主机侧静音通道（KEY_MAP 无音量键、`VolumeMute` 在 Translate 模式被丢弃、媒体键是切换语义）。
  要真静音只能自编译主机里用 WASAPI `IAudioEndpointVolume::SetMute`（幂等）。
- 状态要落盘并在服务启动时重放（`uu-host-state.json`），否则重启电脑后静音丢失/残留。

### 3.8 自定义命令怎么发（官方 .so 不能加消息类型）

复用 `TogglePrivacyMode.impl_key`，内容以 `uu:` 前缀，在 `connection.rs::toggle_privacy_mode` 里拦截，
要求 `is_authed_remote_conn()`，拦截后**不要**真的切隐私模式。已有：
`uu:mute` / `uu:restore-audio` / `uu:display:WxH` / `uu:scale:<pct>` / `uu:unlock:<base64 密码>`。
载荷解码用 `crate::common::decode64`（这个 crate 没有可直接用的 base64 依赖）。

### 3.9 敏感数据

- 密码只在内存里 `Vec<u16>`，用完 `fill(0)`；日志只记次数和长度，绝不记明文。
- 手机端密码存 Android Keystore（AES-GCM，alias `uu_auto_unlock_v1`），
  本地 option 只存 `{on, enc}`；旧版本存的明文首次加载时自动迁移。
- 文档/清单/提交信息里不写密码、Peer ID、公网 IP。

---

## 4. 手机端（Flutter）常见坑

- 官方 `.so` 提供的 `bind.session*` 是上限：新交互只能在 Dart/Kotlin 侧做，别指望发新协议消息。
- `SessionID` 是 `UuidValue` 不是 int：写 `sid == 0` / `int sid` 直接编不过。
- 沉浸式全屏用 `MainActivity` 的 `WindowInsetsController` 原生隐藏系统栏；
  Flutter 的 `immersiveSticky` 在部分 ROM 上无效。
- 远控页常驻 `FLAG_ALT_FOCUSABLE_IM`，要弹系统输入法的窗口前用 `_withIme()` 放行；
  点画布外第一次点击只收键盘、不透传鼠标。
- 打开键盘面板时画布**不缩小**（旧的上移缩小方案被否），靠 `ensureCursorVisible()` 做最小平移保证光标可见。
- 效果类问题一定要实测再改：捏合被采样门控饿死、Overlay 缓存子树不重建这类，静态看代码看不出来。

---

## 5. 构建 / 打包 / 校验

### 命令与耗时基线

- 主机 DLL：`C:\Users\Administrator\AppData\Local\Temp\rd-build\build.bat`
  （vcvars64 → `cargo build --release --lib --features flutter`，写 `dll.log`，末尾打 `BUILD_EXIT=`）
  实测增量 3m46s–4m14s。工具链：Rust MSVC（`C:\Users\Administrator\.cargo\bin`，PATH 里没有）、
  MSVC 14.51 `D:\soft\BuildTools`、LLVM 20+ 取 libclang、vcpkg `D:\soft\vcpkg` + `res/vcpkg-win`，triplet `x64-windows-static`。
- APK：`build_apk.bat`（Flutter 3.24.5 + JDK17，写 `apk.log`），Gradle 约 145s。
  `flutter/android/gradle.properties` 必须 `org.gradle.jvmargs=-Xmx2048M`，
  否则 `:app:packageRelease` 在 `IncrementalSplitter` 抛 OOM（1G 时）。

### 成功判据

- 构建后先看 `BUILD_EXIT=` / Gradle 的 `BUILD SUCCESSFUL`，再读产物大小和哈希；
  管道尾巴（`| tail`）会把失败掩盖掉。
- 报「已修好」之前，必须有：产物哈希 + 部署证据（新进程/新日志）+ 一条可证伪的复测项。

### 工件一致性

- 任何一次代码改动，DLL / APK / 主机分发 zip 三处都要重打，只换一边测不出来。
- 构建进行中如果又来了新反馈：**先停构建**，攒齐改动再一次性打包，别出过时的包。
- Git Bash 里没有 `zip`，用 `/c/Windows/System32/tar.exe -a -c -f 目标.zip 内容...`。
- 重打之后要**全文扫一遍旧数字**：清单和 README 里过时的哈希、字节数、提交号、时间点，
  一次清干净，别只改被点到的那一行。被取代的中间包删掉，不留两个「最新」。
- 临时目录用固定命名（`rd-build`、`rd-dist-NNNN`），删除只写字面路径，不用 `mktemp` / 命令替换。

---

## 6. 复测项怎么写（能证伪）

每项包含：动作 → 期望现象 → 期望日志行 → 状态。

    - T40 未锁屏时连接：主机跳过注入（日志 `skipped, state 0 desktop "Default"`），鼠标键盘正常 → ⬜

状态只允许：⬜ 待测 ｜ 🔄 进行中 ｜ ✅ 通过 ｜ ❌ 失败 ｜ ⏸ 阻塞 ｜ 🗑 废弃。
「静态检查过」不是通过；只有真机验证过才打 ✅。
失败时把日志原文抄进条目里（截图也行），别只写「不行」。
负面结论也要记：本次「不是 NUL 截断回归、不是虚拟屏驱动冲突、不是 hwcodec 缺失、不是 Defender 拦的」
都是花时间排除出来的，写下来能防止下次重走。

---


## 案例：锁屏切换瞬间防窥失败与失败提示（2026-11-22 12:50）

**现象**：12:34 包真机，重连自动恢复防窥时约 4s 弹「隐私模式操作失败，请稍后重试」；手动开也可能秒失败。

**主机日志证据**（`ServiceProfiles\LocalService\...\log\server\RustDesk_rCURRENT.log`，12:40 一轮）：
- 12:40:20 手机断开 → 12:40:23 主机 turn_off → 12:40:29 重连 → 12:40:30 `Displays changed` + `Desktop switched`。
- 12:40:31 `[uu-diag] turn_on_privacy`；`win_virtual_display.rs:240 Failed ChangeDisplaySettingsEx, the virtual display, ret: -1, last error: 0`，4 次重试全失败。
- 12:40:35 主机发 `PrvOnFailed`，手机弹 toast；同一时刻 `auto_unlock: lock screen detected, desktop "Winlogon"` → 机器当时确实处于/正在进入锁屏。

**根因**：
1. 锁屏切换有短暂窗口，`OpenInputDesktop` 仍可能读到 Default，`uu:lock-state` 回 0，客户端按「已解锁」立刻提交，随后 Windows 已切到 Winlogon，提交被拒。
2. 客户端把主机的 `PrvOnFailed` 直接映射成 toast，没有回看锁屏态；于是「锁屏期间」的表现仍是失败 + 开关翻回。

**修法（纯 Dart）**：
- `lock-state==0` 不立刻提交：600ms 后重置状态并再探一次，两次都是 0 才 `_commitPrivacyOn()`。
- 主机隐私失败不再直接 toast：`model.dart` 在 chrome 挂载时转给 `uuState.reportHostPrivacyFailure`，chrome 复探锁屏态——非 0 回到「等待被控端解锁」，连续 3 次主机失败才取消并提示；auto 模式静默。
- 有 `uu_host_control` 能力的主机探测无回复时**不再盲目提交**（取消并提示「无法确认电脑是否已解锁」），只有旧主机才回退旧流程。

**教训**：对「正在变化」的资源（锁屏切换、显示拓扑变更）不能用一次瞬时采样做决定；失败通知先归因（查当前状态）再决定是否展示给用户。

---

## 案例：重连自动重发防窥绕过门控 + 自动解锁耗时分布（2026-11-22 14:15）

**现象**：14:07 锁屏重连仍弹「隐私模式操作失败，请稍后重试」，3.4s 后电脑自动解锁成功却不再重试；14:13 换修复包后同场景正常。

**根因（手机探针 + 主机日志对齐）**：
- 官方 `librustdesk.so` 在每会话**首帧**调用 `send_toggle_privacy_mode_msg`（`src/client/io_loop.rs:1503`），按它自己持久化的 `config.privacy_mode=true` 直接向主机发 `turn_on`，**完全绕过 Dart 的 `lock?` 门控**。
- 锁屏下主机 4 次 `ChangeDisplaySettingsEx` 全拒（14:07:23.6→25.76），27.75 回 `PrvOnFailed`；客户端状态被清空 → toast；主机 27.75 起自动解锁、31.17 成功，但客户端重试链已死。
- 次生 bug：新 chrome 先 `initState`、旧实例后 `dispose`，旧 dispose 把 `privacyChromeMounted=false`，导致失败直接 toast。

**修法（纯 Dart，commit a90abdbb5）**：
- 官方防窥报错一律不展示，只转发给状态机。
- 失败且意图仍为开（含 .so 自动重发失败）：静默置 pending 并重新 `lock?` 探测，锁屏则等解锁后自动重提。
- 空状态回显不再清 pending ON；chrome 挂载改计数。
- 终态仅手动模式提示「防窥未能开启，请解锁电脑后再试」。

**自动解锁耗时分布**（`grep auto_unlock.rs`，2026-11-22 共 11 次成功，全部 attempt1 失败、attempt2 成功 10/11）：
- 检测→成功：p50 3.76s，均值 4.04s，min 3.24s，p90≈6.0s，max 6.82s。
- 阶段：检测→attempt1 0.42–0.44s；attempt1 空等 2.06–2.09s（100% 浪费）；退格/间隔 0.62–0.66s；attempt2 注入→确认 0.12–1.85s（120ms 轮询）。
- 端到端（14:13 正常例）：首次解锁请求 18.455 → 主机成功 23.46 → 客户端 23.68；随后固定预插 4s → 27.68 请求 → 28.66 生效。首帧到生效约 12s。

**优化计划（待办）**：
1. 主机 auto_unlock：修 attempt1（开屏后点击密码框/延到 500ms/补发 Enter），预期解锁 5s → 1–1.5s。
2. 主机 turn_on_privacy：先查 `lock_screen_state()==2` 直接快速失败，省掉 4.1s 注定失败的重试（影响 .so 自动重发路径）。
3. 客户端：预插虚拟屏由固定 4s 改为轮询 `RustDeskVirtualDisplays`（~1–1.5s 即提交，保底 4s）；restore 起始 3s 改为 `pi.isSet` 事件驱动。
4. 验证：锁屏重连场景 ≥10 次，p50 ≤6s、无 toast，再定稿。

---

---

## 案例：预插轮询只认 RustDesk 虚拟屏，Amyuni 主机固定等满 4s（2026-11-22 14:40）

**现象**：14:37 锁屏重连轮，客户端日志 `commit ON ... vd=0` → `preplug ready=false after 4000ms`；主机 14:37:22.9 已发出解锁成功，却拖到 26.9 才提交 turn_on，27.65 防窥生效。

**根因**：预插轮询只看 `pi.RustDeskVirtualDisplays`（RustDesk IDD 列表），但本机被控端用的是 Amyuni usbmmidd，其活动屏数量在另一个平台字段 `pi.amyuniVirtualDisplayCount`（`src/virtual_display_manager.rs:64` 仅在计数 >0 时上报；显示拓扑变化时 `display_service.rs:643` 随 PeerInfo 下发）。主机日志同一轮 `disabled extra display \.\DISPLAY20/21` 证明 Amyuni 屏其实存在，客户端只是没看那个字段。

**修法（纯 Dart，uu_chrome.dart `_commitPrivacyOn`）**：
- `hadVirtualDisplay` 与轮询判据都改成 `RustDeskVirtualDisplays.isNotEmpty || amyuniVirtualDisplayCount > 0`；有屏就直接提交，不再重复预插、不再空等 4s（预计每轮省 2–3s）。
- 诊断行加 `isAmyuni=` / `amyuni=<count>`，便于下次一眼定位。

**教训**：平台能力有两个来源字段时，判据要同时覆盖；`vd=0` 不等于没有虚拟屏。

**同轮验证到的其他结论（14:36–14:37 两轮）**：
- 主机 fast-fail 生效：锁屏时 turn_on 17.814 → 17.817 即回 PrvOnFailed（3ms，原为 4.1s）。
- revert 后的 auto_unlock 正常：attempt2 成功 181ms / 1609ms，无「密码不正确」。
- attempt1 补发 Enter 的实验**不安全**（14:29 两轮 3/3 全失败，空密码被提交成错误密码），已回退，不再尝试同类改法。

**14:55 验证结果（APK `ec2ac984`）**：
- 手动开（未锁屏）：37.36 点开关 → 37.97 两次 0 确认 → commit 时 `amyuni=3 hadVD=true` 直接提交 → 38.93 生效，约 1.6s；不再有 `preplug ready=false after 4000ms`。
- 锁屏重连（auto）：56.74 转发失败 → 56.76 探到 `lock-state:2` → 56.79 发解锁 → 02.49 解锁成功（attempt3 仅 135ms，attempt1/2 未离屏）→ 02.70 立即提交 → 04.08 防窥生效。首帧到生效 7.3s，比上一轮 9.8s 少约 2.5s。
- 注意：本次 `injected 1/1 characters`，密码长度就是 1 位；attempt1 被锁屏首击吞掉属预期，attempt2 偶发未离屏，仍由 attempt3 兜底。

---

## 案例：自编译 DLL 导致桌面端常亮「版本较低，点击升级」（2026-11-22 15:03）

**现象**：Windows 客户端首页左侧常驻粉色卡片「状态 / 你安装的版本比当前运行的低 / 点击这里升级」。

**根因**：
- 卡片由 `desktop_home_page.dart:469` 的 `bind.mainIsInstalledLowerVersion()` 驱动，DLL 侧 `ui_interface.rs is_installed_lower_version()` 比较编译期 `BUILD_DATE` 与安装器写入注册表的 `BuildDate`。安装目录仍是官方 1.5.3 安装器，自编译 DLL 的 BUILD_DATE 恒更新 → 永远为真。
- 另一条 `do_check_software_update()` 会请求 rustdesk.com 版本接口，卡片按钮指向上游 release；其 auto-updater 还可能把官方 DLL 覆盖回来。

**修法（DLL `F42E1A9D`）**：
- `is_installed_lower_version()` 恒返回 false（自编译包不参与安装态比较）。
- `do_check_software_update()` 直接返回 Ok，不再写 `SOFTWARE_UPDATE_URL`（不再出现「发现新版本」卡，也不会自动更新覆盖）。

**验证**：15:03 部署后服务重启，新 `--server` 正常拉起、无 panic；客户端首页不再出现该卡。

**教训**：替换官方 DLL 的自编译发行版，所有「安装态/更新态」判断（BUILD_DATE、版本接口、auto-update）都要单独审一遍，否则会给用户一个通往上游的陷阱按钮。

**首个发行**：GitHub release `v1.5.3-uu.1`（fork，APK `ec2ac984…` + 主机包 `407CA12E…` 双资产），发行说明含安装步骤与 SHA256。

---

## 案例：安卓启动更新检查改接 fork release（2026-11-22 15:15）

**背景**：安卓端复用官方 1.5.3 `librustdesk.so`，其 `do_check_software_update()` 无法修改：启动时会请求 api.rustdesk.com，把「下载新版本」横幅指向 rustdesk.com；桌面端则因自编译 DLL 禁检而永不提示。两端口径需统一到 fork release。

**做法（纯 Dart，APK）**：
- `common.dart checkUpdate()`：仅 Android 生效；启动时 `mainSetLocalOption(enable-check-update=N)` 关掉官方检查；1s 后拉 `https://api.github.com/repos/kitsuneMori96/rustdesk/releases/latest`，解析 `tag_name`/`html_url`。
- 版本比较：标签需匹配 `vX.Y.Z-uu.N`，仅当 N 大于内置 `kUuCurrentReleaseTag` 的 N 才把 URL 写入 `stateGlobal.updateUrl`（横幅出现）；不匹配/网络失败一律静默。
- `connection_page.dart _buildUpdateUI`：不再硬编码 rustdesk.com，直接打开传入 URL，并在按钮文字后附版本标签。
- 新版本发布后必须同步把 `consts.dart: kUuCurrentReleaseTag` 改成新标签再打包，否则客户端会重复提示。

**验证**：logcat 启动后应出现 `[uu-diag] fork latest release: v1.5.3-uu.1 (current v1.5.3-uu.1)`；同标签不出现横幅；把常量改小做临时包可验证横幅与跳转。

**回归与修复（16:04）**：首版接线包（`e23c6774`）把整个连接页渲染成灰块。原因：`_buildUpdateUI` 先算 `Uri.parse(url).pathSegments.last` 再判断 `url.isEmpty`，空 URL 时 `last` 在空列表上抛 StateError，Obx 子树整体构建失败（release 下表现为灰色占位）。修法：空 URL 首行直接返回占位，标签解析改为空列表保护。`fad350dd` 已装机：首页正常、logcat 仍打印 fork latest release 行。

---

## 案例：被控端整机鼠标卡顿（虚拟屏重放 → 采集重启 → 掉 GDI）（2026-11-24 19:44）

**现象**：手机通过 uu 客户端连上 Windows 被控端后，主机**整机**鼠标明显卡顿（不只是远控画面内）；同一台机器时好时坏。

**判别（服务日志）**：读 `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log\server\RustDesk_rCURRENT.log`（普通权限打不开，提权复制一份），按关键词过滤：

- `#displays=` 从 1 跳到 3–4；
- `Displays changed` 后紧跟采集器 `SWITCH`；
- 数秒后出现 `No image, fall back to gdi`，之后持续 GDI 采集 2560×1600。

前两条出现即说明拓扑被虚拟屏打乱；第三条决定卡不卡——有 SWITCH 但没掉 GDI 时不卡。

**根因链**：

1. 手机端把工具栏「虚拟屏 +」的结果持久化在会话选项 `virtual-display` 里；
2. 客户端 `send_toggle_virtual_display_msg`（`src/client/io_loop.rs`）在收到首帧后按该选项逐条重放 `ToggleVirtualDisplay{on:true}`；
3. 主机 `toggle_virtual_display` → `virtual_display_manager::plug_in_monitor` 每请求一次插一块 Amyuni 虚拟屏（上限 4）；
4. 拓扑 1→4 触发视频服务 SWITCH、重建采集器；新 DXGI 采集器在 `DXGI_RECOVERY_FRAME_GRACE`（2 秒）宽限期内拿不到帧，永久退回 GDI；
5. GDI 2560×1600@30fps 软拷贝吃满主机，表现为整机鼠标卡。

**规避（已实测有效）**：在**保持连接**的状态下，把手机端虚拟屏计数减到 0（或点「全部拔出」），**确认计数为 0 后再断开重连**。断开状态下操作无效，重连会重放旧条目。按此法重连后日志全程 `#displays=1`，0 次 SWITCH、0 次 `access lost`、0 次 `fall back to gdi`，鼠标第一秒起就流畅。

**易误判**：开关防窥会经 DisplayConfig 顺手清掉多余虚拟屏，于是出现「开一下/关一下防窥鼠标就好了」的假象——好的原因是虚拟屏被清了，不是防窥修好了采集。

**代码出处**：上述重放、采集重启、GDI 回退在 rustdesk/rustdesk `1.5.3` 中同样存在；本 fork 改动前提交的 `src/client/io_loop.rs` 与 `src/server/video_service.rs` 与上游逐字节一致（0 行差异），不是本 fork 引入的。

**未走代码层修复的原因**：

- 客户端不重放 `virtual-display`：改动小，但会改掉 uu 的「恢复上次虚拟屏」交互，属于产品决策；
- 采集侧（拓扑变化不重建 / 新采集器失败时保留旧采集器 / GDI 换 WGC）：能治根，但要动采集生命周期，跨平台跨显卡，单机复现不足以支撑，维护者无法复现时不宜提交；
- 试过的「宽限期加长」不是真修复（只降低概率），已撤回。

