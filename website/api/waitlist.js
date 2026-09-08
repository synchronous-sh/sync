import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DATA = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "data", "waitlist.json");

function readList() {
  try {
    return JSON.parse(fs.readFileSync(DATA, "utf8"));
  } catch {
    return [];
  }
}

function writeList(entries) {
  fs.mkdirSync(path.dirname(DATA), { recursive: true });
  fs.writeFileSync(DATA, JSON.stringify(entries, null, 2) + "\n");
}

async function readBody(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") {
    try {
      return JSON.parse(req.body || "{}");
    } catch {
      return null;
    }
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    return null;
  }
}

export default async function handler(req, res) {
  if (req.method === "OPTIONS") {
    res.statusCode = 204;
    res.end();
    return;
  }
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ error: "Method not allowed." }));
    return;
  }

  const body = await readBody(req);
  if (!body) {
    res.statusCode = 400;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ error: "Invalid JSON." }));
    return;
  }

  const email = String(body.email || "").trim().toLowerCase();
  if (!EMAIL.test(email)) {
    res.statusCode = 400;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ error: "Enter a valid email address." }));
    return;
  }

  const webhook = process.env.WAITLIST_WEBHOOK;
  if (webhook) {
    const forwarded = await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email,
        source: body.source || "",
        referrer: body.referrer || "",
        createdAt: new Date().toISOString(),
      }),
    });
    if (!forwarded.ok) {
      res.statusCode = 502;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ error: "Waitlist service is unavailable." }));
      return;
    }
  } else {
    const entries = readList();
    if (!entries.some((entry) => entry.email === email)) {
      entries.push({
        email,
        source: body.source || "",
        referrer: body.referrer || "",
        createdAt: new Date().toISOString(),
      });
      writeList(entries);
    }
  }

  res.statusCode = 200;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify({ ok: true }));
}
