-- Macs that sent a device ping (`DevicePing` in the app), and which Mac sent each report. Private:
-- nothing here goes into a GitHub issue. The daily cron deletes rows not seen for 365 days.

-- One row per Mac. `id` is the app's `DeviceID`: 64 hex digits, a salted SHA-256 of the Mac's
-- hardware UUID. `details` is JSON: model, chip, memoryGB, osVersion, appVersion, appBuild,
-- isDebug, and the country Cloudflare reads from the connection.
CREATE TABLE devices (
	id TEXT PRIMARY KEY,
	first_seen TEXT NOT NULL,
	last_seen TEXT NOT NULL,
	details TEXT NOT NULL
) STRICT;
CREATE INDEX devices_last_seen ON devices (last_seen);

-- One row per report sent with a device ID. `id` is the report's id in R2 (reports/<id>.json);
-- `issue` is the GitHub issue number, null when the relay kept the report without an issue.
CREATE TABLE reports (
	id TEXT PRIMARY KEY,
	issue INTEGER,
	device TEXT NOT NULL,
	received TEXT NOT NULL
) STRICT;
CREATE INDEX reports_issue ON reports (issue);
CREATE INDEX reports_device ON reports (device);
