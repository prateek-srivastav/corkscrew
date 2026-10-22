import { InvalidReport, isDeviceID, text } from "./report";

/** What the app sends to /device: `DevicePing` in GameCore (DeviceID.swift), as JSON. */
export interface DevicePing {
	/** `DeviceID`: 64 lowercase hex digits. */
	id: string;
	model: string;
	chip: string;
	memoryGB: number;
	osVersion: string;
	appVersion: string;
	appBuild: string;
	isDebug: boolean;
}

/** The largest ping the relay takes, in bytes. */
export const maxPingBytes = 4_096;
/** Pings one network can send in an hour. Each launch sends one. */
export const pingsPerHour = 30;
/** Days a Mac or a report link is kept after it's last seen (the R2 reports' lifecycle rule too). */
export const keptDays = 365;

/** The ping in `value`, checked against the app's format. Throws `InvalidReport`. */
export function parseDevice(value: unknown): DevicePing {
	if (typeof value !== "object" || value === null || Array.isArray(value)) throw new InvalidReport("The ping isn't a JSON object.");
	const fields = value as Record<string, unknown>;
	if (!isDeviceID(fields.id)) throw new InvalidReport('"id" must be 64 lowercase hex digits.');
	const memoryGB = fields.memoryGB;
	if (typeof memoryGB !== "number" || !Number.isInteger(memoryGB) || memoryGB < 0 || memoryGB > 100_000) {
		throw new InvalidReport('"memoryGB" must be a whole number.');
	}
	if (typeof fields.isDebug !== "boolean") throw new InvalidReport('"isDebug" must be true or false.');
	return {
		id: fields.id,
		model: text(fields, "model", 64),
		chip: text(fields, "chip", 128),
		memoryGB,
		osVersion: text(fields, "osVersion", 32),
		appVersion: text(fields, "appVersion", 32),
		appBuild: text(fields, "appBuild", 32),
		isDebug: fields.isDebug,
	};
}

/** Adds the Mac, or updates when it was last seen and its details. */
export async function saveDevice(db: D1Database, ping: DevicePing, country: string | undefined, now: Date): Promise<void> {
	const { id, ...details } = ping;
	const seen = now.toISOString();
	await db
		.prepare(
			"INSERT INTO devices (id, first_seen, last_seen, details) VALUES (?1, ?2, ?2, ?3) " +
				"ON CONFLICT (id) DO UPDATE SET last_seen = excluded.last_seen, details = excluded.details",
		)
		.bind(id, seen, JSON.stringify({ ...details, country: country ?? null }))
		.run();
}

/** Links a kept report, and its issue when there is one, to the Mac that sent it. */
export async function linkReport(db: D1Database, report: { id: string; issue?: string; device: string; received: Date }): Promise<void> {
	const number = report.issue?.match(/\/issues\/(\d+)$/)?.[1];
	await db
		.prepare("INSERT OR REPLACE INTO reports (id, issue, device, received) VALUES (?1, ?2, ?3, ?4)")
		.bind(report.id, number === undefined ? null : Number(number), report.device, report.received.toISOString())
		.run();
}

/** Deletes Macs not seen, and report links older than, `keptDays`. */
export async function prune(db: D1Database, now: Date): Promise<void> {
	const before = new Date(now.getTime() - keptDays * 24 * 60 * 60 * 1000).toISOString();
	await db.batch([
		db.prepare("DELETE FROM devices WHERE last_seen < ?1").bind(before),
		db.prepare("DELETE FROM reports WHERE received < ?1").bind(before),
	]);
}
