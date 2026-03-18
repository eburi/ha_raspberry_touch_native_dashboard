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

const NAV_WIDTH = 128;
const ANCHOR_MAP_W = DISPLAY_W - NAV_WIDTH - 40;
const ANCHOR_MAP_H = DISPLAY_H - 40;
const ANCHOR_CENTER_X = Math.round(ANCHOR_MAP_W / 2);
const ANCHOR_CENTER_Y = Math.round(ANCHOR_MAP_H / 2 - 36);

let anchorZoomMeters = 1;
let anchorAlarmRadiusMeters = 60;
let anchorAnchorPos = null;
let anchorSelfPos = null;
let anchorWindDirRad = null;
let anchorSelfTrack = [];
let anchorOther = new Map();

// Sensor entity ID → WASM sensor_id mapping
const SENSOR_MAP = {
    "sensor.primrose_latitude": 0,
    "sensor.primrose_longitude": 1,
    "sensor.primrose_log": 2,
    "sensor.primrose_heading_true": 3,
    "sensor.primrose_stw": 4,
    "sensor.primrose_sog": 5,
    "sensor.primrose_cog": 6,
    "sensor.primrose_aws": 7,
    "sensor.primrose_awa": 8,
    "sensor.tws_mean_15min": 9,
    "sensor.twd_mean_15min": 10,
    "sensor.barometric_pressure": 11,
    "sensor.primrose_log_change_24h": 12,
    "sensor.average_speed_over_24h": 13,
};
const HA_DATETIME_ENTITY = "sensor.date_time_iso";
const SENSOR_ID_DATETIME = 14;

// Sail and toggle entities (used only for subscribe list and routing state updates)
const SAIL_SELECT_ENTITIES = [
    "input_select.sail_configuration_main",
    "input_select.sail_configuration_jib",
];
const TOGGLE_ENTITY = "input_boolean.sail_configuration_code_0_set";

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
 * Read a UTF-8 string from WASM linear memory.
 */
function readWasmString(ptr, len) {
    const bytes = new Uint8Array(wasmMemory.buffer, ptr, len);
    return new TextDecoder().decode(bytes);
}

/**
 * WASM import: called when a sail config button is pressed in the UI.
 * WASM passes entity_id and option value as raw strings (ptr+len pairs).
 */
function js_sail_config_changed(entity_ptr, entity_len, option_ptr, option_len) {
    const entity_id = readWasmString(entity_ptr, entity_len);
    const option_value = readWasmString(option_ptr, option_len);

    console.log(`[Sail] ${entity_id} → ${option_value}`);

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
 * WASM import: called when a sail toggle button is pressed in the UI.
 * WASM passes entity_id as a raw string (ptr+len) and state as 0/1.
 */
function js_sail_toggle_changed(entity_ptr, entity_len, state) {
    const entity_id = readWasmString(entity_ptr, entity_len);
    const service = state ? "turn_on" : "turn_off";

    console.log(`[Toggle] ${entity_id} → ${service}`);

    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
            type: "call_service",
            domain: "input_boolean",
            service: service,
            service_data: {
                entity_id: entity_id,
            },
        }));
    }
}

function js_anchor_action(action_ptr, action_len, value) {
    const action = readWasmString(action_ptr, action_len);

    if (action === "zoom_inc") {
        anchorZoomMeters = Math.max(0.2, anchorZoomMeters * 0.8);
        redrawAnchorOverlay();
        return;
    }
    if (action === "zoom_dec") {
        anchorZoomMeters = Math.min(200, anchorZoomMeters * 1.25);
        redrawAnchorOverlay();
        return;
    }

    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
            type: "anchor_action",
            action,
            value,
        }));
    }
}

/**
 * Write a string into WASM scratch memory and return { ptr, len }.
 * Uses a fixed scratch area at offset 60MB in WASM linear memory.
 */
const SCRATCH_OFFSET = 60 * 1024 * 1024;
function writeStringToWasm(value, offset) {
    const encoder = new TextEncoder();
    const encoded = encoder.encode(value);
    const mem = new Uint8Array(wasmMemory.buffer);
    const ptr = SCRATCH_OFFSET + (offset || 0);

    if (ptr + encoded.length > mem.length) return null;
    mem.set(encoded, ptr);
    return { ptr, len: encoded.length };
}

/**
 * Write a string into WASM memory and call update_sensor.
 */
function pushSensorValue(sensorId, value) {
    if (!wasm) return;
    const encoder = new TextEncoder();
    const encoded = encoder.encode(value + "\0"); // null-terminated for LVGL
    const mem = new Uint8Array(wasmMemory.buffer);

    if (SCRATCH_OFFSET + encoded.length > mem.length) return;
    mem.set(encoded, SCRATCH_OFFSET);

    wasm.instance.exports.update_sensor(sensorId, SCRATCH_OFFSET, encoded.length - 1);
}

function formatHaDateTime(state) {
    const m = String(state).match(
        /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::\d{2})?(?:\.\d+)?([+-])(\d{2}):(\d{2})$/,
    );
    if (!m) return null;

    const year = m[1];
    const month = m[2];
    const day = m[3];
    const hour = m[4];
    const minute = m[5];
    const sign = m[6];
    const offsetHour = String(Number(m[7]));
    const offsetMin = m[8];

    const tz = offsetMin === "00"
        ? `UTC${sign}${offsetHour}`
        : `UTC${sign}${offsetHour}:${offsetMin}`;

    return `${hour}:${minute} ${day}.${month}.${year} (${tz})`;
}

/**
 * Process a state update message from the server.
 * Routes entity state to the appropriate WASM export.
 * All knowledge of options/values lives in WASM — JS just passes raw strings.
 */
function toConfiguredPrecision(value, attributes) {
    if (!attributes || typeof attributes !== "object") return null;

    const rawPrecision = attributes.display_precision ?? attributes.suggested_display_precision;
    const precision = Number(rawPrecision);
    if (!Number.isInteger(precision) || precision < 0 || precision > 12) return null;

    const numericValue = Number(value);
    if (!Number.isFinite(numericValue)) return null;

    return numericValue.toFixed(precision);
}

function formatSensorState(state, attributes) {
    const stateText = String(state);
    if (stateText === "unknown" || stateText === "unavailable") {
        return stateText;
    }

    const preciseValue = toConfiguredPrecision(stateText, attributes);
    const valueText = preciseValue ?? stateText;

    const unit = attributes && typeof attributes.unit_of_measurement === "string"
        ? attributes.unit_of_measurement.trim()
        : "";

    if (!unit) return valueText;
    if (valueText.endsWith(` ${unit}`)) return valueText;
    return `${valueText} ${unit}`;
}

function handleStateUpdate(entityId, state, attributes) {
    if (!wasm) return;

    if (entityId === HA_DATETIME_ENTITY) {
        const formatted = formatHaDateTime(state);
        if (formatted) {
            pushSensorValue(SENSOR_ID_DATETIME, formatted);
        }
        return;
    }

    // Check sensor map
    const sensorId = SENSOR_MAP[entityId];
    if (sensorId !== undefined) {
        pushSensorValue(sensorId, formatSensorState(state, attributes));
        return;
    }

    // Sail input_select entities — pass raw state string to WASM
    if (entityId === "input_select.sail_configuration_main") {
        const s = writeStringToWasm(state);
        if (s) wasm.instance.exports.update_sail_main(s.ptr, s.len);
        return;
    }

    if (entityId === "input_select.sail_configuration_jib") {
        const s = writeStringToWasm(state);
        if (s) wasm.instance.exports.update_sail_jib(s.ptr, s.len);
        return;
    }

    // Toggle entity — pass raw state string to WASM
    if (entityId === "input_boolean.sail_configuration_code_0_set") {
        const s = writeStringToWasm(state);
        if (s) wasm.instance.exports.update_code0(s.ptr, s.len);
        return;
    }
}

function pushWasmStringExport(fnName, text) {
    if (!wasm || !wasm.instance.exports[fnName]) return;
    const s = writeStringToWasm(String(text));
    if (!s) return;
    wasm.instance.exports[fnName](s.ptr, s.len);
}

function toMeters(lat1, lon1, lat2, lon2) {
    const R = 6371000;
    const dLat = (lat2 - lat1) * Math.PI / 180;
    const dLon = (lon2 - lon1) * Math.PI / 180;
    const avgLat = ((lat1 + lat2) / 2) * Math.PI / 180;
    const dy = dLat * R;
    const dx = dLon * R * Math.cos(avgLat);
    return { dx, dy };
}

function drawLineDots(fromX, fromY, toX, toY) {
    const steps = 40;
    for (let i = 0; i < steps; i += 1) {
        const t = i / (steps - 1);
        const x = Math.round(fromX + (toX - fromX) * t);
        const y = Math.round(fromY + (toY - fromY) * t);
        wasm.instance.exports.update_anchor_line_point(i, x, y, 1);
    }
}

function hideLineDots() {
    for (let i = 0; i < 40; i += 1) {
        wasm.instance.exports.update_anchor_line_point(i, 0, 0, 0);
    }
}

function pushTrack(track, maxPoints, updateFn) {
    for (let i = 0; i < maxPoints; i += 1) {
        const p = track[track.length - maxPoints + i];
        if (!p || !anchorAnchorPos) {
            updateFn(i, 0, 0, 0);
            continue;
        }
        const { dx, dy } = toMeters(anchorAnchorPos.latitude, anchorAnchorPos.longitude, p.latitude, p.longitude);
        const x = Math.round(ANCHOR_CENTER_X + dx / anchorZoomMeters);
        const y = Math.round(ANCHOR_CENTER_Y - dy / anchorZoomMeters);
        const visible = x >= -10 && y >= -10 && x <= ANCHOR_MAP_W + 10 && y <= ANCHOR_MAP_H + 10;
        updateFn(i, x, y, visible ? 1 : 0);
    }
}

function redrawAnchorOverlay() {
    if (!wasm || !anchorAnchorPos || !anchorSelfPos) {
        hideLineDots();
        pushWasmStringExport("update_anchor_info", "Distance -- m");
        return;
    }

    const ringDiameter = Math.round((anchorAlarmRadiusMeters * 2) / anchorZoomMeters);
    wasm.instance.exports.update_anchor_ring_px(ringDiameter);

    const offset = toMeters(anchorAnchorPos.latitude, anchorAnchorPos.longitude, anchorSelfPos.latitude, anchorSelfPos.longitude);
    const boatX = Math.round(ANCHOR_CENTER_X + offset.dx / anchorZoomMeters);
    const boatY = Math.round(ANCHOR_CENTER_Y - offset.dy / anchorZoomMeters);
    wasm.instance.exports.update_anchor_boat_px(boatX, boatY);

    drawLineDots(ANCHOR_CENTER_X, ANCHOR_CENTER_Y, boatX, boatY);

    const distance = Math.round(Math.sqrt(offset.dx * offset.dx + offset.dy * offset.dy));
    pushWasmStringExport("update_anchor_info", `Distance ${distance} m`);

    pushTrack(anchorSelfTrack, 48, (i, x, y, v) => wasm.instance.exports.update_anchor_track_point(i, x, y, v));

    const others = Array.from(anchorOther.values())
        .filter((v) => v.position)
        .map((v) => {
            const o = toMeters(anchorAnchorPos.latitude, anchorAnchorPos.longitude, v.position.latitude, v.position.longitude);
            const dist = Math.sqrt(o.dx * o.dx + o.dy * o.dy);
            return { v, o, dist };
        })
        .sort((a, b) => a.dist - b.dist)
        .slice(0, 6);

    for (let i = 0; i < 6; i += 1) {
        const item = others[i];
        if (!item) {
            wasm.instance.exports.update_anchor_other_boat(i, 0, 0, 0);
            for (let j = 0; j < 20; j += 1) {
                wasm.instance.exports.update_anchor_other_track_point(i, j, 0, 0, 0);
            }
            continue;
        }
        const x = Math.round(ANCHOR_CENTER_X + item.o.dx / anchorZoomMeters);
        const y = Math.round(ANCHOR_CENTER_Y - item.o.dy / anchorZoomMeters);
        const visible = x >= -20 && y >= -20 && x <= ANCHOR_MAP_W + 20 && y <= ANCHOR_MAP_H + 20;
        wasm.instance.exports.update_anchor_other_boat(i, x, y, visible ? 1 : 0);

        const tr = item.v.track || [];
        for (let j = 0; j < 20; j += 1) {
            const p = tr[tr.length - 20 + j];
            if (!p) {
                wasm.instance.exports.update_anchor_other_track_point(i, j, 0, 0, 0);
                continue;
            }
            const po = toMeters(anchorAnchorPos.latitude, anchorAnchorPos.longitude, p.latitude, p.longitude);
            const tx = Math.round(ANCHOR_CENTER_X + po.dx / anchorZoomMeters);
            const ty = Math.round(ANCHOR_CENTER_Y - po.dy / anchorZoomMeters);
            const tv = tx >= -10 && ty >= -10 && tx <= ANCHOR_MAP_W + 10 && ty <= ANCHOR_MAP_H + 10;
            wasm.instance.exports.update_anchor_other_track_point(i, j, tx, ty, tv ? 1 : 0);
        }
    }
}

function upsertTrack(track, pos, maxSize) {
    const last = track[track.length - 1];
    if (!last || last.latitude !== pos.latitude || last.longitude !== pos.longitude) {
        track.push({ latitude: pos.latitude, longitude: pos.longitude });
        if (track.length > maxSize) {
            track.splice(0, track.length - maxSize);
        }
    }
}

function ingestSignalKData(data) {
    if (!data || !data.self) return;

    const self = data.self;
    const nav = self.navigation || {};
    const env = self.environment || {};
    const pos = nav.position && nav.position.value;
    if (pos && typeof pos.latitude === "number" && typeof pos.longitude === "number") {
        anchorSelfPos = { latitude: pos.latitude, longitude: pos.longitude };
        upsertTrack(anchorSelfTrack, anchorSelfPos, 48);
    }

    const wind = env.wind && env.wind.directionTrue && env.wind.directionTrue.value;
    if (typeof wind === "number") {
        anchorWindDirRad = wind;
    }

    const anchor = nav.anchor || {};
    const anchorPos = anchor.position && anchor.position.value;
    const anchorRadius = anchor.maxRadius && anchor.maxRadius.value;
    const anchorState = anchor.state && anchor.state.value;

    if (anchorPos && typeof anchorPos.latitude === "number" && typeof anchorPos.longitude === "number") {
        anchorAnchorPos = { latitude: anchorPos.latitude, longitude: anchorPos.longitude };
    } else if (!anchorAnchorPos && anchorSelfPos) {
        anchorAnchorPos = { ...anchorSelfPos };
    }

    if (typeof anchorRadius === "number" && Number.isFinite(anchorRadius) && anchorRadius > 0) {
        anchorAlarmRadiusMeters = anchorRadius;
        const target = (ANCHOR_MAP_H * 0.70) / (anchorAlarmRadiusMeters * 2);
        anchorZoomMeters = Math.max(0.2, 1 / target);
    }

    wasm.instance.exports.update_anchor_mode(anchorState === "on" ? 1 : 0);

    if (data.vessels && typeof data.vessels === "object") {
        const nextOther = new Map();
        for (const [key, vessel] of Object.entries(data.vessels)) {
            const vNav = vessel.navigation;
            if (!vNav || !vNav.position || !vNav.position.value) continue;

            const p = vNav.position.value;
            if (typeof p.latitude !== "number" || typeof p.longitude !== "number") continue;
            const id = vessel.mmsi || key;
            let entry = anchorOther.get(id);
            if (!entry) entry = { position: null, track: [] };
            entry.position = { latitude: p.latitude, longitude: p.longitude };
            upsertTrack(entry.track, entry.position, 20);
            nextOther.set(id, entry);
        }
        anchorOther = nextOther;
    }

    redrawAnchorOverlay();
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
                    ...Object.keys(SENSOR_MAP),
                    HA_DATETIME_ENTITY,
                    ...SAIL_SELECT_ENTITIES,
                    TOGGLE_ENTITY,
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
    if (msg.type === "state_changed") {
        // Real-time state change from HA — msg.data is the full new_state object
        if (msg.data && msg.data.entity_id && msg.data.state !== undefined) {
            handleStateUpdate(
                msg.data.entity_id,
                String(msg.data.state),
                msg.data.attributes,
            );
        } else if (msg.entity_id && msg.state !== undefined) {
            // Fallback for simple format
            handleStateUpdate(msg.entity_id, String(msg.state), null);
        }
    } else if (msg.type === "states") {
        // Bulk state response — msg.data is an array of full HA state objects
        if (Array.isArray(msg.data)) {
            console.log(`[WS] Received bulk states: ${msg.data.length} entities`);
            for (const entity of msg.data) {
                if (entity.entity_id && entity.state !== undefined) {
                    handleStateUpdate(
                        entity.entity_id,
                        String(entity.state),
                        entity.attributes,
                    );
                }
            }
        }
    } else if (msg.type === "signalk_status") {
        pushWasmStringExport("update_anchor_status", msg.message || "SignalK status");
        if (msg.state === "not_found") {
            pushWasmStringExport("update_anchor_info", "SignalK app not detected");
        }
    } else if (msg.type === "signalk_data") {
        ingestSignalKData(msg);
    } else if (msg.type === "anchor_action_result") {
        if (!msg.ok) {
            pushWasmStringExport("update_anchor_status", `Action failed: ${msg.error || "unknown"}`);
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
                js_sail_toggle_changed: js_sail_toggle_changed,
                js_anchor_action: js_anchor_action,
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
