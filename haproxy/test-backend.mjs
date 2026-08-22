#!/usr/bin/env node

// Tiny disposable backend used only by the HAProxy integration test. It uses
// Node built-ins so the exact DSH image can supply the architecture-matched
// runtime without pulling a second multi-architecture test image.

import { createHash } from "node:crypto";
import { createServer } from "node:http";

const server = createServer((request, response) => {
  if (request.url === "/stream") {
    response.writeHead(200, {
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "Content-Type": "text/event-stream",
    });
    response.write("data: first\n\n");
    setTimeout(() => {
      response.end("data: second\n\n");
    }, 100);
    return;
  }

  const body = JSON.stringify({
    host: request.headers.host ?? null,
    origin: request.headers.origin ?? null,
    sec_fetch_site: request.headers["sec-fetch-site"] ?? null,
  });
  response.writeHead(200, {
    Connection: "close",
    "Content-Length": Buffer.byteLength(body),
    "Content-Type": "application/json",
  });
  response.end(body);
});

server.on("upgrade", (request, socket) => {
  const key = request.headers["sec-websocket-key"];
  if (typeof key !== "string" || key.length === 0) {
    socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    return;
  }
  const accept = createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n` +
      "websocket-probe",
  );
  setTimeout(() => socket.end(), 100);
});

server.listen(3080, "127.0.0.1");
