/**
 * LVGL Dashboard — WASM loader and runtime
 *
 * Loads the WASM binary, sets up the Canvas, routes mouse/touch input
 * to LVGL, and runs the render loop via requestAnimationFrame.
 *
 * Communicates with the Zap server via WebSocket for HA state updates.
 * Receives sensor values and pushes them into WASM (update_sensor).
 * Receives sail button clicks from WASM (js_sail_config_changed)
 * and sends them to the server to relay to HA.
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

// WebSocket for HA state relay
let ws = null;

// Sensor entity ID → WASM sensor_id mapping
const SENSOR_MAP = {
    "sensor.primrose_position_latitude_formatted": 0,
    "sensor.primrose_position_longitude_formatted": 1,
    "sensor.primrose_log_change_24h": 2,
    "sensor.average_speed_24h": 3,
};

// Sail input_select entity → sail_id mapping
const SAIL_ENTITIES = {
    0: "input_select.sail_configuration_main",
};

// Sail option value → index mapping
const SAIL_MAIN_OPTIONS = ["100%", "Reef 1", "Reef 2", "Reef 3"];

/**
 * Determine the base path for this app.
 * Under HA ingress: /api/hassio_ingress/<token>/
 * Direct access:    /
 */
function getBasePath() {
    const path = window.location.pathname;
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
        cssH = vh;
        cssW = vh * ASPECT;
    } else {
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
 */
function js_flush(x, y, w, h) {
    // Handled in rAF loop by reading the full framebuffer
}

/**
 * WASM import: return current time in ms (for LVGL tick).
 */
function js_get_time() {
    return performance.now();
}

/**
 * WASM import: called when a sail config button is pressed in the UI.
 * Sends the new selection to the server which relays to HA.
 * sail_id: 0 = main sail
 * option_index: index into the options array
 */
function js_sail_config_changed(sail_id, option_index) {
    const entity_id = SAIL_ENTITIES[sail_id];
    if (!entity_id) return;

    let option_value;
    if (sail_id === 0) {
        option_value = SAIL_MAIN_OPTIONS[option_index];
    }

    if (!option_value) return;

    console.log(`[Sail] ${entity_id} → ${option_value}`);

    // Send to server via WebSocket
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
            type: "call_service",
            domain: "input_select",
            service: "select_option",
            service_data: {
                entity_id: entity_id,
                option: option_value,
            },
        }));
    }
}

/**
 * Write a string into WASM memory and call update_sensor.
 */
function pushSensorValue(sensorId, value) {
    if (!wasm) return;
    const encoder = new TextEncoder();
    const encoded = encoder.encode(value + "\0"); // null-terminated
    const len = encoded.length;

    // Allocate in WASM memory — use a fixed scratch area at the end of
    // the framebuffer region. The framebuffer is at a known location,
    // so we use a region after it. For simplicity, write to a scratch
    // buffer starting at a high offset in WASM linear memory.
    // WASM memory is 64MB initial, we use a 4KB scratch at offset 60MB.
    const SCRATCH_OFFSET = 60 * 1024 * 1024;
    const mem = new Uint8Array(wasmMemory.buffer);

    if (SCRATCH_OFFSET + len > mem.length) return;
    mem.set(encoded, SCRATCH_OFFSET);

    wasm.instance.exports.update_sensor(sensorId, SCRATCH_OFFSET, len - 1);
}

/**
 * Process a state update message from the server.
 */
function handleStateUpdate(entityId, state) {
    // Check sensor map
    const sensorId = SENSOR_MAP[entityId];
    if (sensorId !== undefined) {
        pushSensorValue(sensorId, state);
        return;
    }

    // Check sail entities
    if (entityId === "input_select.sail_configuration_main") {
        const idx = SAIL_MAIN_OPTIONS.indexOf(state);
        if (idx >= 0 && wasm) {
            wasm.instance.exports.update_sail_main(idx);
        }
    }
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
            // Subscribe to the entities we care about
            ws.send(JSON.stringify({
                type: "subscribe",
                entities: [
                    "sensor.primrose_position_latitude_formatted",
                    "sensor.primrose_position_longitude_formatted",
                    "sensor.primrose_log_change_24h",
                    "sensor.average_speed_24h",
                    "input_select.sail_configuration_main",
                ],
            }));
            // Request current states
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
    if (msg.type === "state_changed" || msg.type === "state") {
        // Single entity update
        if (msg.entity_id && msg.state !== undefined) {
            handleStateUpdate(msg.entity_id, String(msg.state));
        }
    } else if (msg.type === "states") {
        // Bulk state response
        if (Array.isArray(msg.data)) {
            for (const entity of msg.data) {
                if (entity.entity_id && entity.state !== undefined) {
                    handleStateUpdate(entity.entity_id, String(entity.state));
                }
            }
        }
    }
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
                js_sail_config_changed: js_sail_config_changed,
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
