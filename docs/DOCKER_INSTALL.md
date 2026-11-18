# Docker Engine 安装教程

本文面向使用 Ubuntu x86_64 主机的 QPI M1/L1 SDK 用户。Docker Engine 需要由用户自行安装，不包含在 SDK 中。

## 1. 检查系统环境

```bash
lsb_release -a
uname -m
```

本 SDK 面向 Ubuntu x86_64 主机，`uname -m` 应输出 `x86_64`。如果已经安装 Docker，且以下命令能够正常执行，可以跳过安装步骤：

```bash
docker info
```

## 2. 安装 Docker Engine

安装过程需要管理员权限和网络连接。

两种方式都是安装 Docker Engine，任选一种即可。如果已经安装 Docker，且 `docker info` 正常，则无需重新安装。

不要同时混装 Ubuntu 软件源提供的 `docker.io` 和 Docker 官方软件源提供的 `docker-ce`。如需切换安装方式，请先参考对应的官方文档处理冲突软件包，不要直接覆盖现有安装。

SDK 不强制要求使用 `docker-ce`，只要求 Docker Engine 能够正常运行 `docker build` 和 `docker run`。

### 方式一：Ubuntu 软件源安装（推荐）

Ubuntu 自带的 `docker.io` 软件包已经包含 Docker Engine，不需要额外配置 Docker 官方 APT 软件源。对于 Ubuntu 用户，推荐优先使用这种方式：

```bash
sudo apt update
sudo apt install -y docker.io
```

此方式已在 Ubuntu 22.04.5 LTS x86_64 开发环境中验证，Docker Engine 29.1.3 可以正常运行 QPI M1/L1 SDK。不同 Ubuntu 版本或软件源提供的 Docker 版本可能不同，请在安装后按本文第 5 节验证实际环境。

### 方式二：Docker 官方软件源安装

如需使用 Docker 官方软件源提供的 Docker Engine，先安装基础依赖：

```bash
sudo apt update
sudo apt install -y ca-certificates curl
```

添加 Docker 官方 GPG 密钥：

```bash
sudo install -m 0755 -d /etc/apt/keyrings

sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

sudo chmod a+r /etc/apt/keyrings/docker.asc
```

配置 Docker 官方 APT 软件源：

```bash
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
```

安装 Docker Engine：

```bash
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

如果系统中已经安装可能冲突的 Docker 或 containerd 软件包，请先按照 Docker 官方安装文档识别并处理冲突，不要直接覆盖现有安装。

## 3. 启动 Docker 服务

```bash
sudo systemctl enable --now docker
sudo systemctl status docker
```

## 4. 配置普通用户权限

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

也可以注销并重新登录，使新的用户组权限生效。

> Docker 用户组具有较高的系统权限，只应将可信用户加入该组。

## 5. 验证安装

```bash
docker --version
docker info
docker ps
```

## 6. 在 QPI M1/L1 SDK 中使用

SDK 已提供 Dockerfile 和镜像构建脚本。用户不需要手工下载预制的 `quectel-pi-builder:latest` 镜像。

进入 SDK 根目录后执行：

```bash
source build.sh
buildenv
```

Docker Engine 是运行和构建容器的宿主机服务，需要用户自行安装；`quectel-pi-builder:latest` 是 SDK 根据自带 Dockerfile 构建的编译镜像。SDK 不包含 Docker Engine，也不要求用户手工下载预制的 QPI 编译镜像。

## 7. 参考文档

- [Docker Engine Ubuntu 安装文档](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Linux 安装后配置](https://docs.docker.com/engine/install/linux-postinstall/)
