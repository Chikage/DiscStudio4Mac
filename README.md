# BR · 光盘刻录工作台

macOS 原生光盘镜像刻录应用，SwiftUI + Swift 6 + Apple DiscRecording。最低 macOS 14，支持 Apple Silicon 和 Intel Mac。界面使用简体中文，自动适配系统明暗主题，也可在「显示 → 外观」中选择。

## 运行

直接打开 `build/BR.app`，或在项目根目录运行：

```sh
./Scripts/build.sh
./Scripts/run.sh
```

需要 Xcode 16 或更新版本。项目已包含 `BR.xcodeproj`，可直接用 Xcode 打开并运行。若修改 `project.yml`，用 XcodeGen 执行 `xcodegen generate`。应用为本地临时签名版本；面向其他用户分发前需要 Developer ID 签名与公证。

无需光盘即可体验完整的演示流程：点击右上角「界面演示」。演示会标明模拟数据，与真实刻录路径完全分开。命令行也可运行 `./Scripts/run.sh --demo`（需先退出已有实例）。

## 使用

1. 连接刻录机，插入空白可写光盘。
2. 选择或拖入 ISO、DMG、CDR、CUE、TOC 镜像，或按 ⌘O。BIN/IMG 数据请通过配套 CUE/TOC 描述文件导入。
3. 选择设备和介质支持的速度。默认开启封盘、写入后回读校验和完成后弹出。
4. 点击「开始刻录」，核对镜像、目标设备和参数后确认。
5. 观察阶段、系统报告的进度、MB/s、倍速与速度曲线；完成后可导出文本日志。

写入、封盘和校验期间会阻止空闲睡眠。主动停止可能使光盘不可用；程序会等待引擎清理完成，不会立即报告停止成功。刻录期间退出会被阻止，关闭窗口不会终止正在运行的任务，可从「窗口」菜单重新打开。

## 功能与边界

- 实际刻录使用 `DRBurn`，不是命令行输出模拟；设备插拔、介质变化和刻录进度通过 `DRNotificationCenter` 接收。
- 支持 CD、DVD、BD 的程度取决于 macOS、光驱与介质。只有 DiscRecording 成功解析的镜像才可写入。CUE/TOC 引用的数据文件必须存在且可读。
- 刻录前检查设备、空白介质、容量、速度以及主镜像文件的大小、修改时间和文件标识。CUE/TOC 引用的数据文件不会被复制；从选择到校验结束请保持所有源文件不变且可读。
- 容量检查使用轨道扇区数，而不是压缩 DMG 的文件大小。界面容量按扇区数 × 2048 字节显示；音频/混合轨道的物理扇区可以更大。引出区、会话及介质的最终约束仍由刻录引擎检查。
- 封盘通过 `DRBurnAppendableKey = false` 完成。关闭封盘选项仅保留介质可能支持的追加能力。本版本要求空白介质，不提供已有数据盘的追加、擦除或单独封盘操作。
- 校验通过 `DRBurnVerifyDiscKey` 和每条轨道的 `DRVerificationTypeChecksum` 完成：系统对写入的数据计算校验和并回读比对。关闭校验时不会显示「校验通过」。
- 速度来自系统的 KB/s 和介质倍速读数，KB = 1000 字节，超过 5 秒未更新会显示等待读数；准备、封盘、校验阶段不会延用写入速度。
- **缓冲区显示设备报告的容量及欠载保护状态。公开 DiscRecording API 不提供实时占用百分比，界面明确显示「系统未提供」；不会生成虚构占用率。** 容量为零或缺失时显示未知。
- 百分比直接使用系统报告值，不拼装虚假的全流程百分比。阶段转换时可能重置。日志仅保存在本次运行内，需手动导出留存。
- 不执行 USB 闪存盘、硬盘的整盘写入；不自动擦除介质。应用无需网络或管理员权限，直接分发版本关闭 App Sandbox 以使用光驱与镜像关联文件。

## 验证

```sh
./Scripts/test.sh           # 生成 ISO 测试镜像并运行全部测试，不写入光驱
swift test                 # 核心单元测试；ISO 集成测试需 BR_TEST_IMAGE 环境变量
swift build                # SwiftPM 开发构建
```

测试覆盖容量边界、非空白介质、设备不可用、速度变化、缺失/异常读数、校验状态、演示隔离、取消以及真实 ISO 布局解析。硬件验收步骤见 [docs/VALIDATION.md](docs/VALIDATION.md)。

## 结构

- `Sources/BR`：SwiftUI 工作台、文件面板、退出保护。
- `Sources/BRCore`：可观察任务状态、预检查、遥测值与演示引擎。
- `Sources/DiscBridge`：Objective-C DiscRecording 适配器，隔离遗留 API 与异常；镜像解析在后台执行，回调固定在主线程。
- `Tests/BRCoreTests`：Swift Testing 测试。
- `Scripts`：编译、启动、测试及原生图标生成脚本。

底层接口以 Xcode SDK 的 `DiscRecording.framework/Headers` 中的 `DRBurn.h`、`DRBurn_ContentSupport.h`、`DRTrack.h`、`DRDevice.h`、`DRStatus.h` 为依据。
