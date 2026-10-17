import { DurableObject } from "cloudflare:workers";

/** Counts up to a limit until a time, then deletes itself. One per sender and hour, and one per
 * day for issues: Durable Objects count exactly, where KV could miss a burst. */
export class Counter extends DurableObject {
	/** Counts one, unless `limit` is reached. `until` is when the window ends (ms since 1970). */
	async take(limit: number, until: number): Promise<boolean> {
		const count = (await this.ctx.storage.get<number>("count")) ?? 0;
		if (count >= limit) return false;
		await this.ctx.storage.put("count", count + 1);
		if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(until);
		return true;
	}

	async alarm(): Promise<void> {
		await this.ctx.storage.deleteAll();
	}
}

/** The counter's name for a sender in a window: a keyed hash of both, so the address isn't kept
 * and one sender's counters in different hours can't be linked. */
export async function senderName(address: string, window: number, key: string): Promise<string> {
	const hmac = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const mac = await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(`${window}|${address}`));
	const hex = [...new Uint8Array(mac)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
	return `sender:${window}:${hex.slice(0, 32)}`;
}

/** The part of an address that one home holds: all of an IPv4 address, the first 64 bits of an
 * IPv6 one (a home gets a /64 or more, and can change the rest at will). */
export function network(address: string): string {
	if (!address.includes(":")) return address;
	const [left, right] = address.split("::").map((part) => (part === "" ? [] : part.split(":")));
	const groups = right === undefined ? left : [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
	return `${groups
		.slice(0, 4)
		.map((group) => group.toLowerCase().replace(/^0+(?=.)/, ""))
		.join(":")}::/64`;
}

/** The window `now` is in, for windows of `length` ms, and when it ends. */
export function windowAt(now: number, length: number): { window: number; until: number } {
	const window = Math.floor(now / length);
	return { window, until: (window + 1) * length };
}
