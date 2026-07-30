import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => (error ? reject(error) : resolve(port)));
    });
  });
}

function waitForMongo(port, processHandle) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15_000;
    const attempt = () => {
      if (processHandle.exitCode !== null) {
        reject(new Error("mongod exited before accepting connections"));
        return;
      }
      const connection = createConnection(
        { port, host: "127.0.0.1" },
        () => {
          connection.destroy();
          resolve();
        }
      );
      connection.once("error", () => {
        connection.destroy();
        if (Date.now() >= deadline) {
          reject(new Error("timed out waiting for mongod"));
        } else {
          setTimeout(attempt, 100);
        }
      });
    };
    attempt();
  });
}

function waitForExit(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null) {
      resolve(child.exitCode);
      return;
    }
    child.once("exit", (code) => resolve(code));
  });
}

const databaseDirectory = await mkdtemp(
  path.join(tmpdir(), "commonplate-mongo-")
);
const port = await freePort();
const mongod = spawn(
  "mongod",
  [
    "--dbpath",
    databaseDirectory,
    "--port",
    String(port),
    "--bind_ip",
    "127.0.0.1",
    "--quiet",
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
);
let mongoError = "";
mongod.stderr.on("data", (chunk) => {
  mongoError += String(chunk);
});

let exitCode = 1;
try {
  await waitForMongo(port, mongod);
  const vitest = spawn(
    path.join(process.cwd(), "node_modules", ".bin", "vitest"),
    ["run", ".mongo.test.ts"],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        MONGO_INTEGRATION_URI: `mongodb://127.0.0.1:${port}/commonplate_claim_test`,
        CLAIM_TOKEN_HMAC_SECRET:
          "real-mongo-test-secret-material-32-bytes",
      },
      stdio: "inherit",
    }
  );
  exitCode = (await waitForExit(vitest)) ?? 1;
} catch (error) {
  console.error(
    error instanceof Error ? error.message : "MongoDB integration failed"
  );
  if (mongoError) console.error(mongoError);
} finally {
  mongod.kill("SIGTERM");
  await waitForExit(mongod);
  await rm(databaseDirectory, { recursive: true, force: true });
}

process.exitCode = exitCode;
