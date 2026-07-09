'use strict';

const { randomBytes } = require('crypto');

// dtu-frame.js — builds binary DTU sensor frames matching the wire protocol
// implemented in go-data-receiving (internal/parsing/frame.go, envelope_decoder.go,
// payloads.go, crc16.go) and read by internal/tcp/framereader.go.
//
// Frame layout: SYNC_START(0xAA 0x55) | VER(1) | TYPE(1) | LEN(2 BE) |
//               PAYLOAD(LEN) | CRC(2 BE) | SYNC_END(0x55 0xAA)
// PAYLOAD layout (header + sensor body, no delimiter between them):
//   MSG_ID(16) | PROJ_LEN(1) | PROJ_ID(PROJ_LEN) | SENS_LEN(1) | SENS_ID(SENS_LEN)
//   | TIMESTAMP(8, int64 BE, epoch ms) | SAMPLE_INT(4, uint32 BE) | <sensor body>
//
// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflect, no xorout) over
// bytes [VER, TYPE, LEN, PAYLOAD] — NOT the sync markers.
//
// Reference test vector (go-data-receiving/internal/parsing/crc16.go):
//   CRC16("123456789") === 0x29B1

const SENSOR_TYPE = { gnss: 0x01, rainfall: 0x02, strain: 0x03, soil_pressure: 0x04, deep_displacement: 0x05 };
const PROTOCOL_VERSION = 0x01;
const SYNC_START = [0xaa, 0x55];
const SYNC_END = [0x55, 0xaa];

const CRC16_TABLE = (() => {
  const table = new Uint16Array(256);
  for (let i = 0; i < 256; i++) {
    let crc = i << 8;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
    table[i] = crc;
  }
  return table;
})();

function crc16(buf) {
  let crc = 0xffff;
  for (let i = 0; i < buf.length; i++) {
    crc = ((crc << 8) & 0xffff) ^ CRC16_TABLE[((crc >> 8) ^ buf[i]) & 0xff];
  }
  return crc & 0xffff;
}

function encodeHeader({ msgId, projectId, sensorId, timestampMs, samplingIntervalSeconds }) {
  const msgIdBuf = msgId || randomBytes(16);
  const projectIdBuf = Buffer.from(projectId, 'ascii');
  const sensorIdBuf = Buffer.from(sensorId, 'utf8');
  if (projectIdBuf.length < 3 || projectIdBuf.length > 50) {
    throw new Error(`project_id length ${projectIdBuf.length} out of [3,50]`);
  }
  if (sensorIdBuf.length < 1 || sensorIdBuf.length > 64) {
    throw new Error(`sensor_id length ${sensorIdBuf.length} out of [1,64]`);
  }
  if (samplingIntervalSeconds < 1 || samplingIntervalSeconds > 86400) {
    throw new Error(`sampling_interval_seconds ${samplingIntervalSeconds} out of [1,86400]`);
  }

  const ts = Buffer.alloc(8);
  ts.writeBigInt64BE(BigInt(Math.trunc(timestampMs)));
  const si = Buffer.alloc(4);
  si.writeUInt32BE(samplingIntervalSeconds >>> 0);

  return Buffer.concat([
    Buffer.from(msgIdBuf),
    Buffer.from([projectIdBuf.length]),
    projectIdBuf,
    Buffer.from([sensorIdBuf.length]),
    sensorIdBuf,
    ts,
    si,
  ]);
}

const FIX_QUALITY = { no_fix: 0, single: 1, dgps: 2, rtk_float: 3, rtk_fixed: 4 };

// encodeGnssBody — 21 bytes: 5x float32BE + 1 fix-quality byte.
function encodeGnssBody({
  displacementXMm,
  displacementYMm,
  displacementZMm,
  displacementHorizontalMm,
  cumulativeDisplacementMm,
  fixQuality,
}) {
  if (displacementHorizontalMm < 0) throw new Error('displacement_horizontal_mm must be >= 0');
  if (cumulativeDisplacementMm < 0) throw new Error('cumulative_displacement_mm must be >= 0');
  const fixByte = FIX_QUALITY[fixQuality];
  if (fixByte === undefined) throw new Error(`unknown fix_quality ${fixQuality}`);

  const body = Buffer.alloc(21);
  body.writeFloatBE(displacementXMm, 0);
  body.writeFloatBE(displacementYMm, 4);
  body.writeFloatBE(displacementZMm, 8);
  body.writeFloatBE(displacementHorizontalMm, 12);
  body.writeFloatBE(cumulativeDisplacementMm, 16);
  body.writeUInt8(fixByte, 20);
  return body;
}

// buildGnssFrame — full wire frame for a GNSS sensor reading, ready to write
// to a TCP socket connected to data-receiving's ingestion port.
function buildGnssFrame(fields) {
  const header = encodeHeader(fields);
  const body = encodeGnssBody(fields);
  const payload = Buffer.concat([header, body]);

  if (payload.length < 1 || payload.length > 1024) {
    throw new Error(`payload length ${payload.length} out of [1,1024]`);
  }

  const lenBuf = Buffer.alloc(2);
  lenBuf.writeUInt16BE(payload.length);

  const crcInput = Buffer.concat([
    Buffer.from([PROTOCOL_VERSION, SENSOR_TYPE.gnss]),
    lenBuf,
    payload,
  ]);
  const crc = crc16(crcInput);
  const crcBuf = Buffer.alloc(2);
  crcBuf.writeUInt16BE(crc);

  return Buffer.concat([
    Buffer.from(SYNC_START),
    crcInput,
    crcBuf,
    Buffer.from(SYNC_END),
  ]);
}

// ACK layout: 0xAA 0x55 <status:1> <code:1> 0xAA — always 5 bytes.
function parseAck(buf) {
  if (buf.length !== 5 || buf[0] !== 0xaa || buf[1] !== 0x55 || buf[4] !== 0xaa) {
    return { ok: false, malformed: true };
  }
  return { ok: buf[2] === 0x00 && buf[3] === 0x00, status: buf[2], code: buf[3], malformed: false };
}

module.exports = { crc16, buildGnssFrame, parseAck, SENSOR_TYPE, PROTOCOL_VERSION };
