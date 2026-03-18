# Multi-stage build: Zig builder -> Alpine runtime
# Stage 1: Build with Zig
ARG BUILD_FROM
FROM $BUILD_FROM AS builder

# Install build dependencies
RUN apk add --no-cache curl xz

# Download Zig
RUN curl -L -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/0.14.1/zig-aarch64-linux-0.14.1.tar.xz" && \
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
ARG BUILD_FROM
FROM $BUILD_FROM

# Copy built artifacts
COPY --from=builder /build/zig-out/bin/lvgl-server /usr/local/bin/lvgl-server
COPY --from=builder /build/web/ /app/web/
COPY --from=builder /build/zig-out/bin/dashboard.wasm /app/web/dashboard.wasm

# Copy run script
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

WORKDIR /app
CMD ["/usr/bin/with-contenv", "/app/run.sh"]
