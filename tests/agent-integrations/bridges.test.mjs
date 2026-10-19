import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const resources = join(root, "app/Sources/KeyphoreCore/AgentIntegrationResources");
const fixtures = [];
test.after(() => Promise.all(fixtures.map(directory => rm(directory, { recursive: true, force: true }))));

async function fixture(source, delay = 0) {
  const directory = await mkdtemp(join(tmpdir(), `keyphore-${source}-`));
  fixtures.push(directory);
  const capture = join(directory, "capture.jsonl");
  const helper = join(directory, "keyphore");
  await writeFile(helper, `#!/usr/bin/env node
const fs = require("node:fs");
process.on("SIGTERM", () => {});
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  fs.appendFileSync(${JSON.stringify(capture)}, JSON.stringify({ pid: process.pid, args: process.argv.slice(2), payload: JSON.parse(input) }) + "\\n");
  setTimeout(() => process.exit(0), ${delay});
});
`);
  await chmod(helper, 0o755);

  const extension = source === "pi" ? "ts" : "js";
  const template = await readFile(join(resources, source, `keyphore.${extension}.template`), "utf8");
  const modulePath = join(directory, `keyphore-${Date.now()}.mjs`);
  await writeFile(modulePath, template.replace("__KEYPHORE_HELPER_URL_JSON__", JSON.stringify(helper)));
  const module = await import(`${pathToFileURL(modulePath)}?${Math.random()}`);
  return {
    module,
    async records() {
      const content = await readFile(capture, "utf8").catch(() => "");
      return content.trim() ? content.trim().split("\n").map(JSON.parse) : [];
    },
  };
}

test("Pi maps final settlement without transmitting message content", async () => {
  const { module, records } = await fixture("pi");
  const handlers = new Map();
  module.default({ on: (name, handler) => handlers.set(name, handler) });
  const context = { sessionManager: { getSessionId: () => "pi-session" } };

  await handlers.get("session_start")({}, context);
  await handlers.get("agent_start")({}, context);
  handlers.get("message_end")({
    message: { role: "assistant", stopReason: "error", content: "PRIVATE ERROR BODY" },
  }, context);
  handlers.get("message_end")({
    message: { role: "assistant", stopReason: "stop", content: "PRIVATE RETRY BODY" },
  }, context);
  await handlers.get("agent_settled")({ aborted: false }, context);
  await handlers.get("agent_start")({}, context);
  await handlers.get("agent_settled")({ aborted: true }, context);
  await handlers.get("session_shutdown")({}, context);

  const output = await records();
  assert.deepEqual(output.map(({ args }) => args), output.map(() => ["hook", "pi"]));
  assert.deepEqual(output.map(({ payload }) => payload.event), [
    "sessionStart", "turnStart", "working", "turnComplete",
    "turnStart", "working", "turnCancelled", "sessionEnd",
  ]);
  assert.equal(output[1].payload.turn_id, output[2].payload.turn_id);
  assert.equal(output[4].payload.turn_id, output[5].payload.turn_id);
  assert.doesNotMatch(JSON.stringify(output), /PRIVATE|content|prompt|tool/);
});

test("OpenCode keeps sessions and concurrent attention requests isolated", async () => {
  const { module, records } = await fixture("opencode");
  const plugin = await module.KeyphorePlugin();
  const event = (type, properties) => plugin.event({ event: { type, properties } });

  await event("session.created", { info: { id: "s1", title: "PRIVATE TITLE" } });
  await event("session.created", { info: { id: "s2" } });
  await event("session.status", { sessionID: "s1", status: { type: "busy" } });
  await event("session.status", { sessionID: "s1", status: { type: "busy" } });
  await event("session.status", { sessionID: "s1", status: { type: "retry", message: "PRIVATE ERROR" } });
  await event("session.status", { sessionID: "s2", status: { type: "busy" } });
  await event("permission.asked", { sessionID: "s1", id: "p1", metadata: { command: "PRIVATE COMMAND" } });
  await event("question.asked", { sessionID: "s1", id: "q1", questions: ["PRIVATE QUESTION"] });
  await event("session.status", { sessionID: "s1", status: { type: "idle" } });
  await event("permission.replied", { sessionID: "s1", requestID: "p1", reply: "once" });
  await event("question.rejected", { sessionID: "s1", requestID: "q1" });
  await event("session.error", { sessionID: "s2", error: { message: "PRIVATE FAILURE" } });
  await event("session.status", { sessionID: "s2", status: { type: "idle" } });
  await event("session.deleted", { info: { id: "s1" } });
  await event("session.deleted", { info: { id: "s2" } });

  const output = await records();
  assert.deepEqual(output.map(({ args }) => args), output.map(() => ["hook", "opencode"]));
  const payloads = output.map(({ payload }) => payload);
  assert.equal(payloads.filter(({ event: name, session_id: id }) => name === "turnStart" && id === "s1").length, 1);
  assert.equal(payloads.filter(({ event: name, session_id: id }) => name === "turnStart" && id === "s2").length, 1);
  assert.equal(payloads.filter(({ event: name, session_id: id }) => name === "working" && id === "s1").length, 2);
  assert.deepEqual(
    payloads.filter(({ event: name }) => name === "attention" || name === "attentionResolved")
      .map(({ event: name, request_id: id }) => [name, id]),
    [["attention", "p1"], ["attention", "q1"], ["attentionResolved", "p1"], ["attentionResolved", "q1"]],
  );
  assert.equal(payloads.filter(({ event: name, session_id: id }) => name === "turnComplete" && id === "s1").length, 1);
  assert.equal(payloads.filter(({ event: name, session_id: id }) => name === "turnComplete" && id === "s2").length, 0);
  assert.equal(payloads.filter(({ event: name, session_id: id }) => name === "turnCancelled" && id === "s2").length, 1);
  assert.doesNotMatch(JSON.stringify(output), /PRIVATE|metadata|questions|error/);
});

test("bridge helper calls fail open after the bounded timeout", async () => {
  const { module, records } = await fixture("pi", 10_000);
  const handlers = new Map();
  module.default({ on: (name, handler) => handlers.set(name, handler) });
  const started = Date.now();
  await handlers.get("session_start")({}, { sessionManager: { getSessionId: () => "timeout" } });
  assert.ok(Date.now() - started < 1_800);
  await new Promise(resolve => setTimeout(resolve, 50));
  const [{ pid }] = await records();
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
});

// Native session payloads: OpenCode v1.19.0 packages/schema/src/v1/session.ts.
// https://github.com/anomalyco/opencode/blob/v1.19.0/packages/schema/src/v1/question.ts
// https://github.com/anomalyco/opencode/blob/v1.19.0/packages/schema/src/v1/permission.ts
// https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/session/status.ts
test("OpenCode uses native info.id lifecycle payloads", async () => {
  const { module, records } = await fixture("opencode");
  const plugin = await module.KeyphorePlugin();
  await plugin.event({ event: { type: "session.created", properties: { info: { id: "ses_native" } } } });
  await plugin.event({ event: { type: "session.deleted", properties: { info: { id: "ses_native" } } } });
  assert.deepEqual((await records()).map(x => x.payload), [
    { event: "sessionStart", session_id: "ses_native" },
    { event: "sessionEnd", session_id: "ses_native" },
  ]);
});

test("OpenCode serializes idle and next busy before releasing turn ownership", async () => {
  const { module, records } = await fixture("opencode", 30);
  const plugin = await module.KeyphorePlugin();
  const send = type => plugin.event({ event: { type: "session.status", properties: { sessionID: "s", status: { type } } } });
  await send("busy");
  await Promise.all([send("idle"), send("busy"), send("idle")]);
  const turns = (await records()).map(x => x.payload).filter(x => ["turnStart", "turnComplete"].includes(x.event));
  assert.deepEqual(turns.map(x => x.event), ["turnStart", "turnComplete", "turnStart", "turnComplete"]);
  assert.equal(turns[0].turn_id, turns[1].turn_id);
  assert.equal(turns[2].turn_id, turns[3].turn_id);
  assert.notEqual(turns[0].turn_id, turns[2].turn_id);
});

test("OpenCode new turn drops errored turn requests and ignores old replies", async () => {
  const { module, records } = await fixture("opencode");
  const plugin = await module.KeyphorePlugin();
  const send = (type, properties) => plugin.event({ event: { type, properties: { sessionID: "s", ...properties } } });
  await send("session.status", { status: { type: "busy" } });
  await send("question.asked", { id: "que_old", questions: [] });
  await send("session.error", { error: { name: "MessageAbortedError", data: { message: "aborted" } } });
  await send("session.status", { status: { type: "busy" } });
  await send("session.status", { status: { type: "idle" } });
  await send("question.replied", { requestID: "que_old", answers: [] });
  const output = (await records()).map(x => x.payload);
  assert.equal(output.filter(x => x.event === "turnComplete").length, 1);
  assert.equal(output.filter(x => x.event === "attentionResolved").length, 0);
});

test("Pi serializes settlement with the next run", async () => {
  const { module, records } = await fixture("pi", 30);
  const handlers = new Map();
  module.default({ on: (name, handler) => handlers.set(name, handler) });
  const ctx = { sessionManager: { getSessionId: () => "pi-concurrent" } };
  await handlers.get("agent_start")({ type: "agent_start" }, ctx);
  await Promise.all([
    handlers.get("agent_settled")({ type: "agent_settled", aborted: false }, ctx),
    handlers.get("agent_start")({ type: "agent_start" }, ctx),
  ]);
  // The next settlement arrives after both callbacks: an old settlement must not
  // have cleared the new run while its helper was in flight.
  await handlers.get("agent_settled")({ type: "agent_settled", aborted: false }, ctx);
  const turns = (await records()).map(x => x.payload).filter(x => ["turnStart", "turnComplete"].includes(x.event));
  assert.deepEqual(turns.map(x => x.event), ["turnStart", "turnComplete", "turnStart", "turnComplete"]);
  assert.equal(turns[0].turn_id, turns[1].turn_id);
  assert.equal(turns[2].turn_id, turns[3].turn_id);
  assert.notEqual(turns[0].turn_id, turns[2].turn_id);
});

test("OpenCode ignores malformed and unknown payloads without throwing into host", async () => {
  const { module, records } = await fixture("opencode");
  const plugin = await module.KeyphorePlugin();
  for (const input of [undefined, null, {}, { event: null }, { event: { type: "session.status" } },
    { event: { type: "session.status", properties: { sessionID: "s", status: {} } } },
    { event: { type: "session.created", properties: { sessionID: "incorrect-shape" } } },
    { event: { type: "question.asked", properties: { sessionID: "s", id: 42 } } }]) {
    await assert.doesNotReject(() => plugin.event(input));
  }
  assert.deepEqual(await records(), []);
});

// Pi 1.1.0 extensions/types.d.ts: message_end.message.stopReason, agent_settled.aborted.
test("Pi final error stays cancelled; malformed message cannot erase failure", async () => {
  const { module, records } = await fixture("pi");
  const handlers = new Map();
  module.default({ on: (name, handler) => handlers.set(name, handler) });
  const ctx = { sessionManager: { getSessionId: () => "pi-error" } };
  await handlers.get("agent_start")({ type: "agent_start" }, ctx);
  await handlers.get("message_end")({ type: "message_end", message: { role: "assistant", stopReason: "error" } }, ctx);
  await handlers.get("message_end")({ type: "message_end", message: { role: "assistant" } }, ctx);
  await handlers.get("agent_settled")({ type: "agent_settled", aborted: false }, ctx);
  assert.equal((await records()).at(-1).payload.event, "turnCancelled");
  await assert.doesNotReject(() => handlers.get("agent_start")({}, { sessionManager: { getSessionId() { throw Error("unavailable"); } } }));
  await assert.doesNotReject(() => handlers.get("agent_settled")(null, ctx));
});

test("OpenCode identical request IDs in different sessions remain independent", async () => {
  const { module, records } = await fixture("opencode");
  const plugin = await module.KeyphorePlugin();
  const send = (type, sessionID, extra) => plugin.event({ event: { type, properties: { sessionID, ...extra } } });
  for (const id of ["s1", "s2"]) {
    await send("session.status", id, { status: { type: "busy" } });
    await send("question.asked", id, { id: "same-question-id" });
    await send("session.status", id, { status: { type: "idle" } });
  }
  await send("question.replied", "s1", { requestID: "same-question-id", answers: [] });
  assert.deepEqual((await records()).filter(x => x.payload.event === "turnComplete").map(x => x.payload.session_id), ["s1"]);
  await send("question.replied", "s2", { requestID: "same-question-id", answers: [] });
  assert.deepEqual((await records()).filter(x => x.payload.event === "turnComplete").map(x => x.payload.session_id), ["s1", "s2"]);
});
