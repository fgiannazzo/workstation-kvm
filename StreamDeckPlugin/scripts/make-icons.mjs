/*
 * Generates every PNG the manifest references, with no dependencies beyond Node. Run `npm run icons`
 * after changing a shape. Stream Deck wants each image at 1x and 2x:
 *   action icon 20/40, category icon 28/56, key image 72/144, marketplace icon 256/512.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";

const imgs = join(dirname(fileURLToPath(import.meta.url)), "..", "io.github.fgiannazzo.switchboard.sdPlugin", "imgs");

const WHITE = [255, 255, 255, 1];
const ACCENT = [78, 205, 196, 1]; // teal, reads well on the black Stream Deck key
const KEY_BG = [28, 28, 30, 1];
const BRAND_BG = [34, 72, 110, 1];
const ACTIVE_BG = [21, 128, 61, 1]; // green, the lit Run key; white titles stay legible on it

// --- PNG encoding -----------------------------------------------------------------------------

const CRC_TABLE = new Int32Array(256).map((_, n) => {
	let c = n;
	for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
	return c;
});

function crc32(bytes) {
	let crc = -1;
	for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
	return (crc ^ -1) >>> 0;
}

function chunk(type, data) {
	const length = Buffer.alloc(4);
	length.writeUInt32BE(data.length);
	const typeAndData = Buffer.concat([Buffer.from(type, "ascii"), data]);
	const crc = Buffer.alloc(4);
	crc.writeUInt32BE(crc32(typeAndData));
	return Buffer.concat([length, typeAndData, crc]);
}

function encodePng(size, rgba) {
	const header = Buffer.alloc(13);
	header.writeUInt32BE(size, 0);
	header.writeUInt32BE(size, 4);
	header[8] = 8; // bit depth
	header[9] = 6; // RGBA
	const raw = Buffer.alloc((size * 4 + 1) * size);
	for (let y = 0; y < size; y++) {
		raw[y * (size * 4 + 1)] = 0; // filter: none
		rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
	}
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk("IHDR", header),
		chunk("IDAT", deflateSync(raw, { level: 9 })),
		chunk("IEND", Buffer.alloc(0)),
	]);
}

// --- Tiny anti-aliased rasteriser over predicates in unit coordinates ---------------------------

const SUB = 4;

class Canvas {
	constructor(size) {
		this.size = size;
		this.px = new Float64Array(size * size * 4);
	}

	/** Paints `color` wherever `inside(x, y)` holds, with x and y in 0..1; 16 samples per pixel. */
	fill(inside, [r, g, b, a]) {
		const { size, px } = this;
		for (let y = 0; y < size; y++) {
			for (let x = 0; x < size; x++) {
				let hits = 0;
				for (let sy = 0; sy < SUB; sy++) {
					for (let sx = 0; sx < SUB; sx++) {
						if (inside((x + (sx + 0.5) / SUB) / size, (y + (sy + 0.5) / SUB) / size)) hits++;
					}
				}
				if (hits === 0) continue;
				const alpha = (a * hits) / (SUB * SUB);
				const i = (y * size + x) * 4;
				const dstA = px[i + 3];
				const outA = alpha + dstA * (1 - alpha);
				px[i] = (r * alpha + px[i] * dstA * (1 - alpha)) / outA;
				px[i + 1] = (g * alpha + px[i + 1] * dstA * (1 - alpha)) / outA;
				px[i + 2] = (b * alpha + px[i + 2] * dstA * (1 - alpha)) / outA;
				px[i + 3] = outA;
			}
		}
	}

	toPng() {
		const out = Buffer.alloc(this.size * this.size * 4);
		for (let i = 0; i < out.length; i += 4) {
			out[i] = Math.round(this.px[i]);
			out[i + 1] = Math.round(this.px[i + 1]);
			out[i + 2] = Math.round(this.px[i + 2]);
			out[i + 3] = Math.round(this.px[i + 3] * 255);
		}
		return encodePng(this.size, out);
	}
}

const circle = (cx, cy, r) => (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= r * r;
const ring = (cx, cy, r, stroke) => (x, y) => {
	const d2 = (x - cx) ** 2 + (y - cy) ** 2;
	return d2 <= r * r && d2 >= (r - stroke) ** 2;
};
const roundedRect = (cx, cy, w, h, r) => (x, y) => {
	const dx = Math.max(Math.abs(x - cx) - w / 2 + r, 0);
	const dy = Math.max(Math.abs(y - cy) - h / 2 + r, 0);
	return dx * dx + dy * dy <= r * r;
};
const pillStroke = (cx, cy, w, h, stroke) => (x, y) =>
	roundedRect(cx, cy, w, h, h / 2)(x, y) && !roundedRect(cx, cy, w - 2 * stroke, h - 2 * stroke, (h - 2 * stroke) / 2)(x, y);
const triangle = (ax, ay, bx, by, cx, cy) => (x, y) => {
	const s1 = (bx - ax) * (y - ay) - (by - ay) * (x - ax);
	const s2 = (cx - bx) * (y - by) - (cy - by) * (x - bx);
	const s3 = (ax - cx) * (y - cy) - (ay - cy) * (x - cx);
	return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0);
};

// --- Shapes ----------------------------------------------------------------------------------------

/** Switchboard mark: a toggle switch, knob on. */
function toggle(canvas, color, scale = 1, cy = 0.5) {
	canvas.fill(pillStroke(0.5, cy, 0.72 * scale, 0.36 * scale, 0.07 * scale), color);
	canvas.fill(circle(0.5 + 0.18 * scale, cy, 0.1 * scale), color);
}

function play(canvas, color, scale = 1, cy = 0.5) {
	canvas.fill(triangle(0.5 - 0.22 * scale, cy - 0.3 * scale, 0.5 - 0.22 * scale, cy + 0.3 * scale, 0.5 + 0.32 * scale, cy), color);
}

/** A USB plug, connector up. */
function plug(canvas, color, scale = 1, cy = 0.5) {
	const s = scale;
	const head = (x, y) => roundedRect(0.5, cy - 0.22 * s, 0.32 * s, 0.24 * s, 0.02 * s)(x, y) && !roundedRect(0.5, cy - 0.22 * s, 0.18 * s, 0.1 * s, 0.01 * s)(x, y);
	canvas.fill(head, color);
	canvas.fill(roundedRect(0.5, cy + 0.06 * s, 0.44 * s, 0.32 * s, 0.06 * s), color);
	canvas.fill(roundedRect(0.5, cy + 0.3 * s, 0.1 * s, 0.18 * s, 0.03 * s), color);
}

function status(canvas, color, scale = 1, cy = 0.5) {
	canvas.fill(ring(0.5, cy, 0.34 * scale, 0.1 * scale), color);
	canvas.fill(circle(0.5, cy, 0.13 * scale), color);
}

const files = {
	"plugin/category-icon": [28, (c) => toggle(c, WHITE)],
	"plugin/marketplace": [
		256,
		(c) => {
			c.fill(roundedRect(0.5, 0.5, 1, 1, 0.18), BRAND_BG);
			toggle(c, WHITE, 0.9);
		},
	],
	"actions/run/icon": [20, (c) => play(c, WHITE)],
	"actions/run/key": [
		72,
		(c) => {
			c.fill(roundedRect(0.5, 0.5, 1, 1, 0.16), KEY_BG);
			play(c, ACCENT, 0.7, 0.42);
		},
	],
	"actions/run/key-active": [
		72,
		(c) => {
			c.fill(roundedRect(0.5, 0.5, 1, 1, 0.16), ACTIVE_BG);
			play(c, WHITE, 0.7, 0.42);
		},
	],
	"actions/state/icon": [20, (c) => status(c, WHITE)],
	"actions/state/key": [
		72,
		(c) => {
			c.fill(roundedRect(0.5, 0.5, 1, 1, 0.16), KEY_BG);
			status(c, ACCENT, 0.32, 0.2);
		},
	],
	"actions/usb/icon": [20, (c) => plug(c, WHITE, 0.95)],
	"actions/usb/key": [
		72,
		(c) => {
			c.fill(roundedRect(0.5, 0.5, 1, 1, 0.16), KEY_BG);
			plug(c, ACCENT, 0.7, 0.5);
		},
	],
};

for (const [name, [size, draw]] of Object.entries(files)) {
	for (const scale of [1, 2]) {
		const canvas = new Canvas(size * scale);
		draw(canvas);
		const file = join(imgs, `${name}${scale === 2 ? "@2x" : ""}.png`);
		mkdirSync(dirname(file), { recursive: true });
		writeFileSync(file, canvas.toPng());
		console.log(`wrote ${file} (${size * scale}x${size * scale})`);
	}
}
