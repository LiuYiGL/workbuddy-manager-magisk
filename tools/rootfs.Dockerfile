# syntax=docker/dockerfile:1
# 构建 Android (arm64) 上运行 WorkBuddy Manager 的 rootfs。
#
# 只在构建期联网：下载 Alpine 包、Python wheel 与 Go 工具链。
# 产物是完整的离线 rootfs，安装模块时不需要网络。
#
# 构建必须指定平台：docker buildx build --platform linux/arm64 ...
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

ARG GO_VERSION=1.27.3
# 可选：Go 下载镜像（例如 https://golang.google.cn/dl/go${GO_VERSION}.linux-arm64.tar.gz）
ARG GO_URL=""

ENV LANG=C.UTF-8 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# bash：上游 login.sh / 我们的脚本；git：Go modules 的 direct 回退；
# python3/py3-pip：管理端；curl：健康检查与更新日志；ca-certificates：HTTPS。
RUN apk add --no-cache \
        bash curl ca-certificates tzdata jq \
        python3 py3-pip libstdc++ \
        git coreutils findutils sed grep gzip tar xz \
    && rm -rf /var/cache/apk/*

# pip 自身也升级，避免旧版解析 musllinux 标签出错
# （--break-system-packages 兼容启用了 PEP 668 的发行版）
RUN python3 -m pip install --no-cache-dir --break-system-packages --upgrade pip

# 离线 wheelhouse：安装时 `pip install --no-index --find-links` 直接用。
# --only-binary 是刻意的：Android 上没有 C 编译器，任何需要现场编译的依赖
# 都应当在构建期失败，而不是产出一个装不起来的模块。
COPY requirements.txt /tmp/requirements.txt
RUN mkdir -p /opt/wbm/wheels \
    && python3 -m pip download --no-cache-dir --only-binary=:all: \
         --dest /opt/wbm/wheels -r /tmp/requirements.txt \
    && test -n "$(ls -A /opt/wbm/wheels)" \
    && rm -f /tmp/requirements.txt

# 官方 Go 工具链：让它能在设备上 `go build` 上游（纯静态、CGO_ENABLED=0）
RUN url="${GO_URL:-https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz}"; \
    echo "下载 Go：$url"; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$url" -o /tmp/go.tgz \
    && tar -C /opt -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz \
    && /opt/go/bin/go version \
    && rm -rf /opt/go/test /opt/go/doc /opt/go/misc /opt/go/api

# chroot 内运行时脚本 + docker/systemctl 垫片
COPY overlay/ /
RUN chmod -R 755 /opt/wbm/bin /usr/local/bin/docker /usr/local/bin/systemctl \
    && mkdir -p /workbuddy /tmp \
    && rm -rf /usr/share/man /usr/share/doc /root/.cache/pip /var/cache/apk/* \
    && rm -f /.dockerenv

# 记录构建信息，便于设备上排障
RUN { echo "alpine=${ALPINE_VERSION}"; echo "python=$(python3 -V 2>&1)"; \
      echo "go=$(/opt/go/bin/go version)"; } > /opt/wbm/build-info.txt

CMD ["/bin/sh"]
