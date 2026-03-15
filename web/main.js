/**
 * LVGL Dashboard — WASM loader and runtime
 *
 * Loads the WASM binary, sets up the Canvas, routes mouse/touch input
 * to LVGL, and runs the render loop via requestAnimationFrame.
 */

const DISPLAY_W = 1280;
const DISPLAY_H = 720;
const ASPECT = DISPLAY_W / DISPLAY_H;

let wasm = null;
let wasmMemory = null;
let canvas = null;
let ctx = null;
let imageData = null;
let running = false;
let lastTime = 0;

// WebSocket for HA state relay (connected after WASM init)
let ws = null;

/**
 * Determine the base path for this app.
 * Under HA ingress: /api/hassio_ingress/<token>/
 * Direct access:    /
 */
function getBasePath() {
    const path = window.location.pathname;
    // HA ingress URLs look like /api/hassio_ingress/<token>/
    const ingressMatch = path.match(/^(\/api\/hassio_ingress\/[^/]+\/)/);
    if (ingressMatch) {
        return ingressMatch[1];
    }
    return "/";
}

/**
 * Scale canvas CSS size to fit viewport while preserving 16:9 aspect ratio.
 */
function resizeCanvas() {
    if (!canvas) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const viewAspect = vw / vh;

    let cssW, cssH;
    if (viewAspect > ASPECT) {
        // Viewport is wider than 16:9 — fit to height
        cssH = vh;
        cssW = vh * ASPECT;
    } else {
        // Viewport is taller — fit to width
        cssW = vw;
        cssH = vw / ASPECT;
    }

    canvas.style.width = cssW + "px";
    canvas.style.height = cssH + "px";
}

/**
 * Convert mouse/touch event coordinates to LVGL display coordinates.
 */
function eventToLVGL(e) {
    const rect = canvas.getBoundingClientRect();
    const scaleX = DISPLAY_W / rect.width;
    const scaleY = DISPLAY_H / rect.height;

    let clientX, clientY;
    if (e.touches && e.touches.length > 0) {
        clientX = e.touches[0].clientX;
        clientY = e.touches[0].clientY;
    } else {
        clientX = e.clientX;
        clientY = e.clientY;
    }

    const x = Math.round((clientX - rect.left) * scaleX);
    const y = Math.round((clientY - rect.top) * scaleY);
    return { x: Math.max(0, Math.min(DISPLAY_W - 1, x)),
             y: Math.max(0, Math.min(DISPLAY_H - 1, y)) };
}

/**
 * WASM import: called by LVGL flush callback to signal a region update.
 * We blit the entire framebuffer to canvas on each frame anyway,
 * but this could be used for partial updates in the future.
 */
function js_flush(x, y, w, h) {
    // Flush is handled in the rAF loop by reading the full framebuffer
}

/**
 * WASM import: return current time in ms (for LVGL tick).
 */
function js_get_time() {
    return performance.now();
}

/**
 * Main render loop.
 */
function frame(timestamp) {
    if (!running) return;

    const dt = lastTime === 0 ? 16 : (timestamp - lastTime);
    lastTime = timestamp;

    // Advance LVGL
    wasm.instance.exports.tick(Math.round(dt));

    // Read framebuffer from WASM memory and blit to canvas
    const fbPtr = wasm.instance.exports.get_framebuffer();
    const fbSize = wasm.instance.exports.get_framebuffer_size();

    if (fbPtr && fbSize > 0) {
        const fbData = new Uint8ClampedArray(wasmMemory.buffer, fbPtr, fbSize);
        imageData.data.set(fbData);
        ctx.putImageData(imageData, 0, 0);
    }

    requestAnimationFrame(frame);
}

/**
 * Set up mouse and touch event handlers on the canvas.
 */
function setupInput() {
    let isPressed = false;

    canvas.addEventListener("mousedown", (e) => {
        isPressed = true;
        const pos = eventToLVGL(e);
        wasm.instance.exports.set_input(pos.x, pos.y, 1);
        e.preventDefault();
    });

    canvas.addEventListener("mousemove", (e) => {
        const pos = eventToLVGL(e);
        wasm.instance.exports.set_input(pos.x, pos.y, isPressed ? 1 : 0);
    });

    canvas.addEventListener("mouseup", (e) => {
        isPressed = false;
        const pos = eventToLVGL(e);
        wasm.instance.exports.set_input(pos.x, pos.y, 0);
    });

    canvas.addEventListener("mouseleave", (e) => {
        isPressed = false;
        const pos = eventToLVGL(e);
        wasm.instance.exports.set_input(pos.x, pos.y, 0);
    });

    // Touch events
    canvas.addEventListener("touchstart", (e) => {
        isPressed = true;
        const pos = eventToLVGL(e);
        wasm.instance.exports.set_input(pos.x, pos.y, 1);
        e.preventDefault();
    }, { passive: false });

    canvas.addEventListener("touchmove", (e) => {
        const pos = eventToLVGL(e);
        wasm.instance.exports.set_input(pos.x, pos.y, isPressed ? 1 : 0);
        e.preventDefault();
    }, { passive: false });

    canvas.addEventListener("touchend", (e) => {
        isPressed = false;
        // Use last known position for release
        wasm.instance.exports.set_input(0, 0, 0);
        e.preventDefault();
    }, { passive: false });

    canvas.addEventListener("touchcancel", (e) => {
        isPressed = false;
        wasm.instance.exports.set_input(0, 0, 0);
    });
}

/**
 * Connect WebSocket for Home Assistant state relay.
 */
function connectWebSocket() {
    const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    const basePath = getBasePath();
    const wsUrl = `${proto}//${window.location.host}${basePath}ws`;

    try {
        ws = new WebSocket(wsUrl);
        ws.onopen = () => {
            console.log("[WS] Connected to server");
            // Request initial states
            ws.send(JSON.stringify({ type: "get_states" }));
        };
        ws.onmessage = (event) => {
            try {
                const msg = JSON.parse(event.data);
                handleWSMessage(msg);
            } catch (e) {
                console.warn("[WS] Failed to parse message:", e);
            }
        };
        ws.onclose = () => {
            console.log("[WS] Disconnected, reconnecting in 5s...");
            setTimeout(connectWebSocket, 5000);
        };
        ws.onerror = (err) => {
            console.warn("[WS] Error:", err);
        };
    } catch (e) {
        console.warn("[WS] Connection failed:", e);
        setTimeout(connectWebSocket, 5000);
    }
}

function handleWSMessage(msg) {
    // Future: update LVGL dashboard widgets based on HA state changes
    console.log("[WS] Received:", msg.type);
}

/**
 * Initialize everything.
 */
async function main() {
    const statusEl = document.getElementById("status");

    // Set up canvas
    canvas = document.getElementById("display");
    canvas.width = DISPLAY_W;
    canvas.height = DISPLAY_H;
    ctx = canvas.getContext("2d");
    imageData = ctx.createImageData(DISPLAY_W, DISPLAY_H);

    resizeCanvas();
    window.addEventListener("resize", resizeCanvas);

    // Load WASM
    statusEl.textContent = "Loading WASM...";

    try {
        const importObject = {
            env: {
                js_flush: js_flush,
                js_get_time: js_get_time,
            },
        };

        const basePath = getBasePath();
        const response = await fetch(basePath + "dashboard.wasm");
        if (!response.ok) throw new Error(`HTTP ${response.status}`);

        wasm = await WebAssembly.instantiateStreaming(response, importObject);
        wasmMemory = wasm.instance.exports.memory;

        statusEl.textContent = "Initializing LVGL...";

        // Initialize LVGL + dashboard
        wasm.instance.exports.init(DISPLAY_W, DISPLAY_H);

        // Set up input handling
        setupInput();

        // Start render loop
        running = true;
        lastTime = 0;
        requestAnimationFrame(frame);

        statusEl.textContent = "Running";
        setTimeout(() => statusEl.classList.add("hidden"), 2000);

        // Connect WebSocket (non-blocking, will retry on failure)
        connectWebSocket();

    } catch (err) {
        statusEl.textContent = "Error: " + err.message;
        console.error("Failed to load WASM:", err);
    }
}

main();
