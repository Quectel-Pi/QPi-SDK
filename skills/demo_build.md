---
name: app-demo-build
description: "编译用户指定的任意 C/C++ 工程文件夹：用户会给出一个**随意的文件夹路径**（名字不固定，可能是 app_demo、test、project 等），以该路径为工程根目录，先快速遍历其中的 CMakeLists.txt / Makefile 等构建文件，分析编译逻辑，比对目录下所有 .c/.cpp/.h 源文件，把漏掉未加入编译的源文件补进构建配置，再按工程自身的编译方式（cmake / make / 交叉编译）执行编译并修复报错。当用户说「编译这个文件夹」「编译这个工程」「把这个路径下代码编一下」「把xxx加进编译」「CMakeLists少了文件」「Makefile漏了源文件」「补全编译配置」「编译失败帮我看看」「执行编译」「编译demo」「添加.c文件」「帮我编译一下这个目录」并给出任意路径时使用。WHEN: compile folder, compile project, build directory, CMakeLists.txt, Makefile, add source file, missing .c/.h, cmake build, make build, cross compile, aarch64, 编译, 构建, 补全源文件, 编译报错, 给定路径编译. DO NOT USE FOR: 内核镜像/固件整体打包（用 quectel-m2-kernel-sdk/build.sh），JIRA 工单修复（用 jira-fix-helper），外设参数问题（用 m2-peripherals-guide）。
license: MIT
metadata:
  author: GitHub Copilot
  version: "1.1.0"
---

# 任意 C/C++ 工程编译助手（遍历构建文件 → 补全源文件 → 执行编译）

> 目标：用户给一个**任意路径的 C/C++ 工程文件夹**（名字不固定，不一定是 app_demo），
> 以**该路径为工程根目录**，按下面流程把工程完整编译出来。
> 核心三件事：**看懂构建逻辑 → 补齐遗漏的源文件 → 按正确方式编译**。

## 何时使用

- 用户说「编译这个文件夹 / 工程 / 目录」并给出**一个任意的文件夹路径**
- 用户说「xxx.c 没加进去 / 少了个文件 / 链接报 undefined reference」
- 用户说「CMakeLists.txt / Makefile 帮我改一下再编译」
- 用户给一个新工程目录，要求先看构建逻辑再动手
- 文件夹叫什么名字都行：app_demo、demo、test、myproject……**不要预设名字，以用户给的路径为准**

## 工作流程

### 第 0 步：锁定工程根目录（最重要）

1. **以用户给出的路径作为工程根目录**，不要把路径写死在文档/习惯里，也不要假设在某个固定目录
2. 先 `list_dir` 确认该路径存在且内容符合预期（是源码工程，而非空目录/纯文档目录）
3. 如果用户给的是文件而非目录，取该文件所在目录为根目录
4. 若路径下同时有多个独立工程（如 examples/ 下有多个子目录），先问用户或按构建文件分布判断要编哪个，必要时逐个处理

### 第 1 步：快速遍历构建文件（先全局了解，别急着编译）

1. 用 `file_search` 在**第 0 步锁定的根目录**内查找构建相关文件，glob 示例：
   - `**/CMakeLists.txt`
   - `**/{Makefile,makefile,*.mk,*.cmake,CMakeLists.txt,build.sh,*.sh}`
2. 用 `list_dir` 看顶层结构，确认：
   - 是单个工程还是多个子工程（多级 `CMakeLists.txt` / 多个 Makefile 并行存在）
   - 有没有 `build/`、`out/` 等已存在的构建目录（可能是增量构建）
3. **先读构建文件再读源码**：用 `grep_search` 或 `read_file` 分析每个构建文件的编译逻辑。

### 第 2 步：分析编译逻辑（搞懂"它打算怎么编"）

对每个构建文件提取以下信息：

**CMakeLists.txt：**
- 工程名与目标：`project()` / `add_executable()` / `add_library()` / `add_subdirectory()`
- 源文件收集方式：
  - `file(GLOB ...)` 或 `aux_source_directory()` → 自动收集，一般不会漏（但仍要确认 glob 路径覆盖了新增目录）
  - 逐个列出源文件（最常见）→ **重点检查漏文件**
- `target_sources()` / `target_link_libraries()` / `include_directories()` / `add_definitions()`
- 是否 `set(CMAKE_TOOLCHAIN_FILE ...)` 或要求外部传入 toolchain（交叉编译）
- 顶层是否 `cmake_minimum_required`

**Makefile：**
- 目标与依赖：`TARGET` / `all:` / 每个 target 的依赖列表
- 源文件变量：`SRCS` / `OBJS` / `wildcard` / `$(wildcard *.c)` / `find`
- 编译规则：`$(CC) $(CFLAGS)`、头文件是否列在依赖里
- 交叉编译变量：`CC ?=`、`CROSS_COMPILE`、`SYSROOT`
- 特殊目标：`clean` / `install` / `%.o: %.c` 模式规则
- 子目录递归：`$(MAKE) -C subdir`

**其他构建方式（同样要识别）：**
- `build.sh` / `*.sh`：看里面的实际编译命令
- `meson.build` / `BUILD.bazel` / `Android.mk` 等：同样提取源文件列表逻辑

### 第 3 步：比对源文件与构建配置（找出漏网之鱼）

1. 用 `file_search` 列出目录下全部 C/C++ 源文件：`**/*.{c,cc,cpp,cxx,h,hpp}`
   - **排除**：`build/`、`out/`、`bin/`、`.git/`、CMake 生成目录（`CMakeFiles/`）、交叉编译产物
2. 与构建文件中出现的源文件做差集，找出**存在但未加入编译**的文件。
3. 判断每个漏文件：
   - 是**新功能/新模块**（如 `xxx.c` 带 `xxx.h`，明显独立模块）→ 应加入
   - 是**测试/示例**（`test_*.c`、`example.c`，可能故意不编）→ 询问或跳过
   - 是**构建产物**（生成的 `.c`，如 `lex.yy.c`）→ 不手动加，看构建脚本是否自动生成
   - 是 `.h` 文件 → 一般不需要列进编译（除非项目风格把所有头文件也列进 `SRCS` 以触发依赖），**但若 .h 引用了 .c 才有的符号需确认对应 .c 已加入**
4. 若用户没说目标平台/目标产物，优先按构建文件**已有的默认目标**处理。

### 第 4 步：修改构建文件，把遗漏的源文件加进去

**保持原有风格**，用 `insert_edit_into_file` 修改：

- 原来是**逐行列出源文件** → 按同样格式追加缺失文件（保持缩进/换行风格）
- 原来是 `file(GLOB ...)` → 若 glob 已覆盖新文件则无需改；若 glob 路径没覆盖，扩 glob 路径或改为显式列出
- 原来是 `aux_source_directory()` → 检查是否覆盖新文件所在目录
- 是 Makefile 且用 `SRCS=xxx.c` 列出 → 追加到 `SRCS`
- 涉及链接库时，如果新增源文件引用了外部库，检查 `target_link_libraries` / `LDLIBS` / `LIBS` 是否缺，缺则一并补
- 如果新增源文件需要额外头文件路径，检查 `include_directories` / `CFLAGS -I` 是否缺

改完**先自查**：重新比对一次，确认所有应加入的文件都已进构建配置，且没有引入语法错误。

### 第 5 步：根据编译方式执行编译

> **前提**：先 `cd` 到第 0 步锁定的工程根目录（用户给的路径），所有编译命令都在该目录内执行。

| 构建方式 | 执行命令 | 备注 |
|---------|---------|------|
| CMake（未配置） | `cmake -S . -B build && cmake --build build -j$(nproc)` | 有 toolchain 时：`cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=<toolchain>` |
| CMake（已有 build 目录） | `cmake --build build -j$(nproc)` | 不要重复 configure 丢配置 |
| Makefile | `make -j$(nproc)` | 需要交叉编译环境时先 `source environment-setup.sh`（见下） |
| build.sh | 按脚本内逻辑执行，或用 `bash build.sh` | 先读脚本确认参数 |
| 交叉编译（本仓库 M2 SDK） | `source <sdk>/environment-setup.sh && make` | 见"本仓库注意事项" |

- 若用户给的路径**不在当前工作区**（如 `/tmp/xxx`、`~/xxx`），先确认文件系统可访问，路径不存在就告知用户
- 编译可能较慢，用 `mode='sync'` 等完成，输出超长时用 `tail -n 100` 截取
- **编译失败时按报错逐条修复**：先看第一个错误（后续错误常是它的连锁反应）；undefined reference → 检查漏文件/漏库；找不到头文件 → 检查 include 路径

### 第 6 步：验证结果

1. 编译通过后，确认产物路径（`build/xxx` 或当前目录 `xxx` 可执行文件）
2. 如用户需要，可提供运行/部署方式（如 `adb push` 到板子、scp 到目标机）
3. 汇报时说明：**用户给的路径、改了哪些构建文件、加了哪些源文件、用什么命令编的、产物在哪**

## 本仓库（Quectel M2 / RK3576）注意事项

- 应用 SDK：`quectel-m2-debian-app-sdk/`，交叉编译环境由 `environment-setup.sh` 提供：
  - `source environment-setup.sh` 后自动设置 `CC=aarch64-none-linux-gnu-gcc`、`SYSROOT`、`CFLAGS`、`LDFLAGS`、`CMAKE_TOOLCHAIN_FILE`
  - CMake 工程直接传 `-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE`（即 `cmake/aarch64-m2-debian-toolchain.cmake`）
  - Makefile 工程通常已写死 `CC ?= aarch64-none-linux-gnu-gcc`，直接 `make` 即可
- 示例参考：`examples/hello/`（Makefile 单文件工程）、`examples/hello-module/`（内核模块）
- 目标板是 aarch64（RK3576），**不要**在本机跑交叉编译产物

## 常见坑

- **别乱跑 configure**：已有 `build/` 目录时直接增量 `cmake --build`，重新 `cmake -S . -B build` 可能丢失原 toolchain/选项
- **GLOB 不自动更新**：`file(GLOB)` 在已配置的 build 目录中新增文件后，若不重新 configure 可能不生效；重新跑一次 `cmake -S . -B build` 即可
- **改 Makefile 记得检查依赖**：新增 `.c` 后若 Makefile 用 `SRCS` 变量驱动 `OBJS`，只需加进 `SRCS`；若是硬编码 target 依赖，要同时改依赖列表
- **头文件不用加进 SRCS**（大多数项目）；但若项目把 `.h` 也列进 `SRCS` 以触发头文件依赖跟踪，则跟随项目风格
- **漏文件 ≠ 一定该加**：被 `#if 0` 包起来的、平台专属的（`*_win.c` 在 Linux 上）、故意不编的测试文件，先确认再动
- **交叉编译环境别忘 source**：出现 `gcc: command not found` 或链接到宿主库时，多半是没 source 环境脚本
