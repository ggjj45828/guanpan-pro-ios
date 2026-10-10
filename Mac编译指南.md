# 观盘 Pro · Mac 编译指南

## 先把话说清楚

这份源码是 **SwiftUI 写的 iPhone 应用**（iOS 17+），不是 macOS 应用。它用 XcodeGen 从 `project.yml` 生成 Xcode 工程，依赖全是苹果系统框架（SwiftUI / Charts / UIKit / CryptoKit / Security 等），**没有任何第三方库**，所以编译本身不需要额外装包。

但有一点必须提前说明：这份代码从没被 Xcode 编译过（原 README 里也是这么写的），所以**第一次跑很可能会报编译错误**。这不是流程问题，是代码本身需要修。CI 的价值就在于——它会把完整的报错日志给你，你拿回来我就能改。

---

## 三条路，选一条

| | 成本 | 能拿到什么 | 适合谁 |
|---|---|---|---|
| **A. GitHub Actions** | 0 元（公开仓库） | 未签名 IPA + 模拟器包 | 你没有 Mac，这是唯一免费可行的路 |
| **B. 本地 Mac** | 借用即可 | 能直接跑模拟器、装真机 | 能借到朋友的 Mac |
| **C. Codemagic** | 0 元（每月 500 分钟） | 构建产物 + 完整日志 | 觉得 GitHub Actions 麻烦 |

---

## 路径 A：GitHub Actions（推荐）

### A1. 建一个**公开**仓库

登录 GitHub → 右上角 `+` → New repository → 填仓库名（比如 `guanpan-pro`）→ **必须选 Public**。

> 为什么强调公开：只有公开仓库的 macOS runner 是**免费且不限时长**的。私有仓库免费额度按 10 倍折算，macOS 实际只有约 200 分钟/月，跑两次就没了。源码里没有密钥（API 密钥存在手机 Keychain，不进代码），公开没有泄露风险。如果确实要私有仓库，见文末说明。

### A2. 把代码推上去

代码已经在我这儿准备好了，仓库根目录就是它。打开 Git Bash 执行（把 `<你的用户名>` 和 `<仓库名>` 换成你的）：

```bash
cd "C:/Users/Administrator/WorkBuddy/2026-10-10-13-36-11/guanpan-ios-build"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git branch -M main
git push -u origin main
```

会弹窗让你登录 GitHub（用浏览器授权即可）。

**如果不想用命令行**，用网页上传也行，但有个坑：GitHub 网页传文件夹时，`.github` 这种点开头的目录经常传不上去，工作流文件就没了。所以工作流建议单独建：

1. 网页上点 `Add file` → `Create new file`
2. 文件名直接输入 `.github/workflows/build-ios.yml`（斜杠会自动变成目录）
3. 把 `guanpan-ios-build/.github/workflows/build-ios.yml` 的内容整个粘进去，提交
4. 其余文件（`Sources/`、`project.yml`、`generate-xcode-project.sh`、`README.md`）直接拖到网页上传框里

### A3. 看它跑

推送完成后，仓库页面点顶部的 **Actions** 标签：

- 会看到一条 `build-ios` 的运行记录，两个任务在并行跑
- 首次运行要装 XcodeGen（`brew install`），大概 3-6 分钟；编译本身 1-3 分钟
- **绿色勾 = 编译通过**；**红色叉 = 有编译错误**，点进去看日志

两个任务分别产出：

| 产物名 | 是什么 | 用途 |
|---|---|---|
| `GuanpanPro-unsigned-ipa` | 未签名 IPA | 重签后装到真 iPhone |
| `GuanpanPro-simulator-app` | 模拟器版 .app | 借到 Mac 时可直接拖进模拟器运行 |

下载方式：点进那次运行 → 页面底部 `Artifacts` 区域 → 点名字下载 zip。**必须登录 GitHub 才能下载。**

### A4. 装到自己的 iPhone（Windows 也能做）

未签名的 IPA 不能直接安装，要用重签工具拿你自己的 Apple ID 签一遍：

1. Windows 上装 [Sideloadly](https://sideloadly.io/)（或 AltStore）
2. 电脑装 iTunes（提供驱动），数据线连上 iPhone
3. 把 `GuanpanPro-unsigned.ipa` 拖进 Sideloadly，填你的 Apple ID
4. 装完后在 iPhone 上：**设置 → 通用 → VPN与设备管理 → 信任你的开发者证书**

**免费 Apple ID 的限制**（心里有数就行）：

- 签出来的应用 **7 天后失效**，到期重新签一次即可
- 最多同时装 3 个自签应用
- 不能上架、不能用 TestFlight

需要 **iOS 17 及以上的 iPhone**。

---

## 路径 B：手上有 Mac（哪怕只借十分钟）

```bash
# 1. 装 XcodeGen（先装 Homebrew: https://brew.sh）
brew install xcodegen

# 2. 生成 Xcode 工程
cd guanpan-ios-build
chmod +x generate-xcode-project.sh
./generate-xcode-project.sh

# 3. 打开
open GuanpanProNative.xcodeproj
```

在 Xcode 里：顶部设备选一个 **iPhone 模拟器** → 按 `⌘R` 直接运行。

要装真机的话，先在 `project.yml` 里填上你的 `DEVELOPMENT_TEAM`（或者直接在 Xcode 的 Signing & Capabilities 里选你的 Personal Team，免费 Apple ID 也能选），然后数据线连手机 `⌘R`。

---

## 路径 C：Codemagic（备选）

觉得 GitHub Actions 的日志太硬核，可以用 [Codemagic](https://codemagic.io/)：

- 每月 **500 分钟 macOS M2 免费额度**，永久免费、每月重置、不用绑信用卡
- 单次构建上限 120 分钟
- 界面化配置，日志比 Actions 好读

它同样能连 GitHub 仓库，需要写一个 `codemagic.yaml`。要走这条我再给你配。

---

## 关于私有仓库

如果你坚持不让代码公开，GitHub 私有仓库也能跑，但要花钱：macOS 超出免费额度后约 **$0.062/分钟**。每次完整跑一遍双任务大约 8-10 分钟，折算下来**一次约 $0.5**（约 3.6 元）。跑几次修编译错误，成本在 20-30 元。

省钱做法：私有仓库里只保留 `build-device` 这一个任务，并把 `runs-on` 改成 `macos-latest`、删掉 `build-simulator` 整个 job，一次大约 4-5 分钟。

---

## 出错了怎么办

**编译报错是最可能发生的情况**，处理方式很简单：

1. 进 Actions → 点红色那次运行 → 点 `编译 (真机 SDK，不签名)` 这一步
2. 把日志里 `error:` 开头的行全部复制出来（或者整段日志另存成 txt）
3. 贴给我，我来改代码

不要只发截图或者一句"报错了"，Swift 编译错误必须看完整报错文本才能定位。

---

## 已确认的工程事实

- 类型：iOS 17+ SwiftUI 应用，iPhone only（`TARGETED_DEVICE_FAMILY: "1"`）
- 工程生成：XcodeGen，配置在 `project.yml`
- 包名：`com.guanpan.pro.native`，显示名"观盘 Pro"
- 代码规模：15 个 Swift 文件，约 5900 行
- 第三方依赖：**无**
- 资源文件：**无**（没有 Assets.xcassets，所以暂时没有 App 图标）
- 入口：`GuanpanProApp.swift` 的 `@main`，唯一
- 编译时必须绕过签名：`CODE_SIGNING_ALLOWED=NO`（工作流里已经配好）
