# Multi-stage build: Zig builder -> Alpine runtime
# Stage 1: Build with Zig
ARG BUILD_FROM
FROM ${BUILD_FROM} AS builder

ARG ZIG_VERSION=0.14.1

# Install build dependencies
RUN apk add --no-cache curl xz

# Detect architecture and download Zig
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then ZIG_ARCH="aarch64"; \
    elif [ "$ARCH" = "x86_64" ]; then ZIG_ARCH="x86_64"; \
    else echo "Unsupported arch: $ARCH" && exit 1; fi && \
    curl -L -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" && \
    mkdir -p /opt/zig && \
    tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

# Copy source
WORKDIR /build
COPY build.zig build.zig.zon lv_conf.h ./
COPY src/ src/
COPY web/ web/

# Build WASM module
RUN zig build wasm -Doptimize=ReleaseSmall

# Build native server
RUN zig build server -Doptimize=ReleaseSafe

# Stage 2: Runtime
FROM ${BUILD_FROM}

# Install runtime dependencies (minimal)
RUN apk add --no-cache \
    bash \
    jq

# Copy built artifacts
COPY --from=builder /build/zig-out/bin/lvgl-server /usr/local/bin/lvgl-server
COPY --from=builder /build/web/ /usr/local/share/lvgl-dashboard/web/
COPY --from=builder /build/zig-out/bin/dashboard.wasm /usr/local/share/lvgl-dashboard/web/dashboard.wasm

# Copy rootfs (S6 services, etc.)
COPY ha_app/rootfs/ /

# Make service scripts executable
RUN chmod +x /etc/services.d/lvgl_dashboard/run /etc/services.d/lvgl_dashboard/finish

# Working directory
WORKDIR /usr/local/share/lvgl-dashboard

# Expose port
EXPOSE 8765
