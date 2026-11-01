// server.js

const express = require('express');
const WebSocket = require('ws');
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const app = express();
const port = 8080;

// Middleware to parse JSON bodies for HTTP requests
app.use(express.json());

// Create an HTTP server
const server = http.createServer(app);

// Create WebSocket servers
const wss = new WebSocket.Server({ noServer: true }); // For audio streaming
const notificationWSS = new WebSocket.Server({ noServer: true }); // For notifications

// Store clients per channel and audio messages in memory
const clientsPerChannel = {};
const channelMessages = {};

// Store all connected notification clients
const notificationClients = new Map(); // Map of userId to WebSocket clients

// Recording sessions in progress, keyed by channel name.
// ponytail: in-memory accumulation of raw PCM chunks; ceiling = RECORDING_MAX_BYTES.
// Upgrade path: stream chunks straight to disk if longer sessions are needed.
const recordingState = {};
const SAMPLE_RATE = 16000; // PCM16, mono — matches the Flutter client
const RECORDING_MAX_BYTES = SAMPLE_RATE * 2 * 60 * 60; // ~60 min, ~115MB

// File path for storing channels
const CHANNELS_FILE = path.join(__dirname, 'channels.json');
const RECORDINGS_FILE = path.join(__dirname, 'recordings.json');
const RECORDINGS_DIR = path.join(__dirname, 'recordings');

// Load channels from file or initialize default channels
let channels = {};
if (fs.existsSync(CHANNELS_FILE)) {
  try {
    const data = fs.readFileSync(CHANNELS_FILE);
    channels = JSON.parse(data);
  } catch (e) {
    console.error('Failed to load channels from file:', e);
    channels = {};
  }
}

// Persisted recordings metadata: { [id]: { id, channelName, createdAt, durationMs, members, creatorId, transcript } }
let recordings = {};
if (fs.existsSync(RECORDINGS_FILE)) {
  try {
    recordings = JSON.parse(fs.readFileSync(RECORDINGS_FILE));
  } catch (e) {
    console.error('Failed to load recordings from file:', e);
    recordings = {};
  }
}
if (!fs.existsSync(RECORDINGS_DIR)) {
  fs.mkdirSync(RECORDINGS_DIR);
}

// Ensure default channels exist
['Channel 1', 'Channel 2', 'Channel 3'].forEach((channelName) => {
  if (!channels[channelName]) {
    channels[channelName] = {
      name: channelName,
      creatorId: 'system',
      isDefault: true,
      members: null, // accessible to all
    };
  }
});

function saveChannelsToFile() {
  try {
    fs.writeFileSync(CHANNELS_FILE, JSON.stringify(channels, null, 2));
  } catch (e) {
    console.error('Failed to save channels to file:', e);
  }
}

function saveRecordingsToFile() {
  try {
    fs.writeFileSync(RECORDINGS_FILE, JSON.stringify(recordings, null, 2));
  } catch (e) {
    console.error('Failed to save recordings to file:', e);
  }
}

function recordingFilePath(id) {
  return path.join(RECORDINGS_DIR, `${id}.wav`);
}

function isHost(channel, userId) {
  return channel && channel.creatorId === userId;
}

function channelAccessible(channel, userId) {
  if (!channel) return false;
  if (channel.isDefault) return true;
  if (channel.creatorId === userId) return true;
  if (channel.members && channel.members.includes(userId)) return true;
  return false;
}

// members list that should get access to a recording made on this channel.
// Default (open) channels return null meaning "anyone connected".
function recordingMembers(channel) {
  if (!channel) return [];
  if (channel.members == null) return null; // open channel
  return Array.from(channel.members);
}

function recordingAccessible(rec, userId) {
  if (!rec) return false;
  if (rec.creatorId === userId) return true;
  if (rec.members == null) return true; // open channel recording
  if (Array.isArray(rec.members) && rec.members.includes(userId)) return true;
  return false;
}

// Send a JSON control frame to every live client on a channel (used for notices,
// recording start/stop signals, and kicks).
function sendToChannel(channelName, message) {
  const set = clientsPerChannel[channelName];
  if (!set) return;
  const text = JSON.stringify(message);
  set.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) client.send(text);
  });
}

// Build a WAV buffer from raw little-endian PCM16 mono samples.
function pcmToWav(pcm) {
  const dataLen = pcm.length;
  const buffer = Buffer.alloc(44 + dataLen);
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + dataLen, 4);
  buffer.write('WAVE', 8);
  buffer.write('fmt ', 12);
  buffer.writeUInt32LE(16, 16); // PCM chunk size
  buffer.writeUInt16LE(1, 20); // audio format = PCM
  buffer.writeUInt16LE(1, 22); // mono
  buffer.writeUInt32LE(SAMPLE_RATE, 24);
  buffer.writeUInt32LE(SAMPLE_RATE * 2, 28); // byte rate
  buffer.writeUInt16LE(2, 32); // block align
  buffer.writeUInt16LE(16, 34); // bits per sample
  buffer.write('data', 36);
  buffer.writeUInt32LE(dataLen, 40);
  pcm.copy(buffer, 44);
  return buffer;
}

function flushRecording(channelName) {
  const rec = recordingState[channelName];
  if (!rec) return null;
  const wav = pcmToWav(Buffer.concat(rec.chunks));
  const id = crypto.randomUUID();
  fs.writeFileSync(recordingFilePath(id), wav);
  const createdAt = rec.startedAt;
  const durationMs = Math.round((wav.length - 44) / (SAMPLE_RATE * 2) * 1000);
  const entry = {
    id,
    channelName,
    createdAt,
    durationMs,
    members: rec.members,
    creatorId: rec.hostUserId,
    transcript: null,
  };
  recordings[id] = entry;
  saveRecordingsToFile();
  delete recordingState[channelName];
  return entry;
}

// Transcribe a recording's WAV file using the OpenAI Whisper API.
// Uses native fetch/FormData/Blob (Node >= 18), so no extra npm dependency.
async function transcribeWav(id) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) {
    const err = new Error('Transcription not configured (OPENAI_API_KEY missing on server).');
    err.status = 503;
    throw err;
  }
  const filePath = recordingFilePath(id);
  if (!fs.existsSync(filePath)) {
    const err = new Error('Recording audio not found.');
    err.status = 404;
    throw err;
  }
  const buffer = fs.readFileSync(filePath);
  const blob = new Blob([buffer], { type: 'audio/wav' });
  const form = new FormData();
  form.append('file', blob, `${id}.wav`);
  form.append('model', 'whisper-1');
  const resp = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}` },
    body: form,
  });
  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Transcription API error: ${resp.status} ${txt}`);
    err.status = 502;
    throw err;
  }
  const data = await resp.json();
  return data.text || '';
}

// Handle WebSocket upgrades
server.on('upgrade', (request, socket, head) => {
  const pathname = request.url;

  if (pathname.startsWith('/ws/audio/')) {
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  } else if (pathname === '/ws/notifications') {
    notificationWSS.handleUpgrade(request, socket, head, (ws) => {
      notificationWSS.emit('connection', ws, request);
    });
  } else {
    socket.destroy();
  }
});

// WebSocket connection for live audio streaming
wss.on('connection', (ws, req) => {
  const urlParts = req.url.split('/');
  const channel = decodeURIComponent(urlParts[urlParts.length - 2]); // Extract channel from URL
  const userId = decodeURIComponent(urlParts[urlParts.length - 1]); // Extract userId from URL

  // Check if the user has access to the channel
  const channelData = channels[channel];
  if (!channelData) {
    ws.send(JSON.stringify({ type: 'error', message: 'Channel not found' }));
    ws.close();
    return;
  }

  if (channelData.members && !channelData.members.includes(userId) && channelData.creatorId !== userId) {
    ws.send(JSON.stringify({ type: 'error', message: 'Access denied to channel' }));
    ws.close();
    return;
  }

  ws.channel = channel;
  ws.userId = userId;

  if (!clientsPerChannel[channel]) {
    clientsPerChannel[channel] = new Set();
  }
  clientsPerChannel[channel].add(ws);
  console.log(`Client connected to channel: ${channel}`);

  ws.on('message', (data) => {
    if (clientsPerChannel[channel]) {
      // Accumulate into an active recording session, if any.
      const rec = recordingState[channel];
      if (rec) {
        rec.chunks.push(Buffer.from(data));
        if (Buffer.concat(rec.chunks).length > RECORDING_MAX_BYTES) {
          // Auto-flush at the ceiling to avoid unbounded memory growth.
          const entry = flushRecording(channel);
          if (entry) {
            sendToChannel(channel, { type: 'recording_stopped', recordingId: entry.id, auto: true });
          }
        }
      }

      // Broadcast audio to all clients in the channel except the sender
      clientsPerChannel[channel].forEach((client) => {
        if (client !== ws && client.readyState === WebSocket.OPEN) {
          client.send(data);
        }
      });
    } else {
      // Channel has been deleted; inform the client and close the connection
      ws.send(JSON.stringify({ type: 'error', message: 'Channel has been deleted' }));
      ws.close();
    }
  });

  ws.on('close', () => {
    if (clientsPerChannel[channel]) {
      clientsPerChannel[channel].delete(ws);
      if (clientsPerChannel[channel].size === 0) {
        delete clientsPerChannel[channel];
      }
    }
    console.log(`Client disconnected from channel: ${channel}`);
  });

  ws.on('error', (error) => {
    console.error(`Error on channel ${channel}:`, error);
  });
});

// WebSocket connection for notifications
notificationWSS.on('connection', (ws) => {
  let userId = null;

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      if (data.type === 'register' && data.userId) {
        userId = data.userId;
        notificationClients.set(userId, ws);
        console.log(`User ${userId} registered for notifications`);
      }
    } catch (e) {
      console.error('Error parsing message:', e);
    }
  });

  ws.on('close', () => {
    if (userId) {
      notificationClients.delete(userId);
    }
    console.log('Client disconnected from notification WebSocket');
  });

  ws.on('error', (error) => {
    console.error('Error on notification WebSocket:', error);
  });
});

// =============================================================================
// CRUD endpoints for channels
// =============================================================================

// Create a new channel
app.post('/channels', (req, res) => {
  const { channelName, userId } = req.body;

  if (!channelName || !userId) {
    return res.status(400).json({
      status: 'error',
      message: 'Channel name and user ID are required',
    });
  }

  if (channels[channelName]) {
    return res.status(400).json({
      status: 'error',
      message: 'Channel already exists',
    });
  }

  channels[channelName] = {
    name: channelName,
    creatorId: userId,
    isDefault: false,
    members: [userId],
  };

  saveChannelsToFile();

  res.status(201).json({
    status: 'success',
    channelName,
  });
});

// Get the list of channels
app.get('/channels', (req, res) => {
  const userId = req.query.userId;
  if (!userId) {
    return res.status(400).json({
      status: 'error',
      message: 'User ID is required',
    });
  }

  const accessibleChannels = Object.values(channels).filter(channel => {
    if (channel.isDefault) return true;
    if (channel.creatorId === userId) return true;
    if (channel.members && channel.members.includes(userId)) return true;
    return false;
  });

  res.status(200).json({
    status: 'success',
    channels: accessibleChannels,
  });
});

// Delete a channel
app.delete('/channels/:channelName', (req, res) => {
  const { channelName } = req.params;
  const { userId } = req.body;

  const channel = channels[channelName];

  if (!channel) {
    return res.status(404).json({
      status: 'error',
      message: 'Channel not found',
    });
  }

  if (channel.creatorId !== userId) {
    return res.status(403).json({
      status: 'error',
      message: 'Only the creator can delete this channel',
    });
  }

  delete channels[channelName];
  saveChannelsToFile();

  // Stop any active recording on this channel.
  if (recordingState[channelName]) {
    flushRecording(channelName);
  }

  // Notify and close any clients connected to this channel
  if (clientsPerChannel[channelName]) {
    clientsPerChannel[channelName].forEach((client) => {
      client.send(JSON.stringify({
        type: 'channel_deleted',
        channelName: channelName,
      }));
      client.close(); // This will trigger the 'close' event on client side
    });
    delete clientsPerChannel[channelName];
  }

  // Remove messages associated with the channel
  if (channelMessages[channelName]) {
    delete channelMessages[channelName];
  }

  // Notify only the members of the channel about the deletion
  const membersToNotify = new Set();
  if (channel.members) {
    channel.members.forEach((memberId) => {
      membersToNotify.add(memberId);
    });
  }
  // Also include the creator
  membersToNotify.add(channel.creatorId);

  membersToNotify.forEach((memberId) => {
    const client = notificationClients.get(memberId);
    if (client && client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify({
        type: 'channel_deleted',
        channelName: channelName,
      }));
    }
  });

  res.status(200).json({
    status: 'success',
    message: 'Channel deleted',
  });
});

// Join a channel
app.post('/channels/:channelName/join', (req, res) => {
  const { channelName } = req.params;
  const { userId } = req.body;

  if (!channelName || !userId) {
    return res.status(400).json({
      status: 'error',
      message: 'Channel name and user ID are required',
    });
  }

  const channel = channels[channelName];
  if (!channel) {
    return res.status(404).json({
      status: 'error',
      message: 'Channel not found',
    });
  }

  if (channel.isDefault) {
    return res.status(400).json({
      status: 'error',
      message: 'Cannot join default channels',
    });
  }

  if (!channel.members) {
    channel.members = [];
  }

  if (!channel.members.includes(userId)) {
    channel.members.push(userId);
    saveChannelsToFile();
  }

  res.status(200).json({
    status: 'success',
    message: `Joined channel ${channelName}`,
  });
});

// Leave a channel
app.post('/channels/:channelName/leave', (req, res) => {
  const { channelName } = req.params;
  const { userId } = req.body;

  if (!channelName || !userId) {
    return res.status(400).json({
      status: 'error',
      message: 'Channel name and user ID are required',
    });
  }

  const channel = channels[channelName];
  if (!channel) {
    return res.status(404).json({
      status: 'error',
      message: 'Channel not found',
    });
  }

  if (channel.isDefault) {
    return res.status(400).json({
      status: 'error',
      message: 'Cannot leave default channels',
    });
  }

  if (channel.members && channel.members.includes(userId)) {
    channel.members = channel.members.filter(id => id !== userId);
    saveChannelsToFile();
    res.status(200).json({
      status: 'success',
      message: `Left channel ${channelName}`,
    });
  } else {
    res.status(400).json({
      status: 'error',
      message: 'User is not a member of the channel',
    });
  }
});

// =============================================================================
// Recording endpoints
// =============================================================================

// Start recording a channel (host only)
app.post('/channels/:channelName/recordings/start', (req, res) => {
  const { channelName } = req.params;
  const { userId } = req.body;
  const channel = channels[channelName];

  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can start a recording' });
  }
  if (recordingState[channelName]) {
    return res.status(400).json({ status: 'error', message: 'A recording is already in progress' });
  }

  recordingState[channelName] = {
    chunks: [],
    startedAt: Date.now(),
    hostUserId: userId,
    members: recordingMembers(channel),
  };
  sendToChannel(channelName, { type: 'recording_started', channelName });
  res.status(200).json({ status: 'success', message: 'Recording started' });
});

// Stop recording a channel (host only)
app.post('/channels/:channelName/recordings/stop', (req, res) => {
  const { channelName } = req.params;
  const { userId } = req.body;
  const channel = channels[channelName];

  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can stop a recording' });
  }
  if (!recordingState[channelName]) {
    return res.status(400).json({ status: 'error', message: 'No recording in progress' });
  }

  const entry = flushRecording(channelName);
  sendToChannel(channelName, { type: 'recording_stopped', recordingId: entry ? entry.id : null });
  res.status(200).json({ status: 'success', recordingId: entry ? entry.id : null });
});

// List recordings for a channel (members)
app.get('/channels/:channelName/recordings', (req, res) => {
  const { channelName } = req.params;
  const userId = req.query.userId;
  const channel = channels[channelName];

  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!channelAccessible(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Access denied' });
  }

  const list = Object.values(recordings)
    .filter((r) => r.channelName === channelName)
    .map((r) => ({ id: r.id, channelName: r.channelName, createdAt: r.createdAt, durationMs: r.durationMs, hasTranscript: !!r.transcript }))
    .sort((a, b) => b.createdAt - a.createdAt);
  res.status(200).json({ status: 'success', recordings: list, recording: !!recordingState[channelName] });
});

// Recording metadata (members)
app.get('/recordings/:id', (req, res) => {
  const rec = recordings[req.params.id];
  const userId = req.query.userId;
  if (!rec) return res.status(404).json({ status: 'error', message: 'Recording not found' });
  if (!recordingAccessible(rec, userId)) {
    return res.status(403).json({ status: 'error', message: 'Access denied' });
  }
  res.status(200).json({ status: 'success', recording: { ...rec, transcript: rec.transcript || '' } });
});

// Stream the WAV audio (members)
app.get('/recordings/:id/audio', (req, res) => {
  const rec = recordings[req.params.id];
  const userId = req.query.userId;
  if (!rec) return res.status(404).json({ status: 'error', message: 'Recording not found' });
  if (!recordingAccessible(rec, userId)) {
    return res.status(403).json({ status: 'error', message: 'Access denied' });
  }
  const filePath = recordingFilePath(rec.id);
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ status: 'error', message: 'Audio file missing' });
  }
  res.setHeader('Content-Type', 'audio/wav');
  fs.createReadStream(filePath).pipe(res);
});

// Transcribe a recording (members). Stores the transcript on the server.
app.post('/recordings/:id/transcribe', async (req, res) => {
  const rec = recordings[req.params.id];
  const { userId } = req.body || {};
  if (!rec) return res.status(404).json({ status: 'error', message: 'Recording not found' });
  if (!recordingAccessible(rec, userId)) {
    return res.status(403).json({ status: 'error', message: 'Access denied' });
  }
  try {
    const text = await transcribeWav(rec.id);
    rec.transcript = text;
    saveRecordingsToFile();
    res.status(200).json({ status: 'success', transcript: text });
  } catch (e) {
    res.status(e.status || 500).json({ status: 'error', message: e.message });
  }
});

// Fetch the stored transcript (members)
app.get('/recordings/:id/transcript', (req, res) => {
  const rec = recordings[req.params.id];
  const userId = req.query.userId;
  if (!rec) return res.status(404).json({ status: 'error', message: 'Recording not found' });
  if (!recordingAccessible(rec, userId)) {
    return res.status(403).json({ status: 'error', message: 'Access denied' });
  }
  res.status(200).json({ status: 'success', transcript: rec.transcript || '' });
});

// Delete a recording (host of its channel)
app.delete('/recordings/:id', (req, res) => {
  const rec = recordings[req.params.id];
  const { userId } = req.body || {};
  if (!rec) return res.status(404).json({ status: 'error', message: 'Recording not found' });
  const channel = channels[rec.channelName];
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can delete recordings' });
  }
  const filePath = recordingFilePath(rec.id);
  if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
  delete recordings[rec.id];
  saveRecordingsToFile();
  res.status(200).json({ status: 'success', message: 'Recording deleted' });
});

// =============================================================================
// Host / admin endpoints
// =============================================================================

// List members of a channel (host)
app.get('/channels/:channelName/members', (req, res) => {
  const { channelName } = req.params;
  const userId = req.query.userId;
  const channel = channels[channelName];
  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can view members' });
  }
  const members = channel.members || [];
  res.status(200).json({ status: 'success', members, creatorId: channel.creatorId });
});

// List currently connected clients on a channel (host)
app.get('/channels/:channelName/clients', (req, res) => {
  const { channelName } = req.params;
  const userId = req.query.userId;
  const channel = channels[channelName];
  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can view connected clients' });
  }
  const set = clientsPerChannel[channelName] || new Set();
  const clients = [];
  set.forEach((ws) => {
    if (ws.userId) clients.push({ userId: ws.userId });
  });
  res.status(200).json({ status: 'success', clients });
});

// Kick a member from a channel (host)
app.post('/channels/:channelName/kick', (req, res) => {
  const { channelName } = req.params;
  const { userId, targetUserId } = req.body;
  const channel = channels[channelName];
  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can kick members' });
  }
  if (targetUserId === channel.creatorId) {
    return res.status(400).json({ status: 'error', message: 'Cannot kick the host' });
  }
  if (channel.members) {
    channel.members = channel.members.filter((id) => id !== targetUserId);
    saveChannelsToFile();
  }
  // Force-close the kicked user's live socket on this channel.
  const set = clientsPerChannel[channelName];
  if (set) {
    set.forEach((ws) => {
      if (ws.userId === targetUserId && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'kicked', channelName }));
        ws.close();
      }
    });
  }
  res.status(200).json({ status: 'success', message: 'Member kicked' });
});

// Broadcast a text notice to everyone on a channel (host)
app.post('/channels/:channelName/broadcast', (req, res) => {
  const { channelName } = req.params;
  const { userId, message } = req.body;
  const channel = channels[channelName];
  if (!channel) return res.status(404).json({ status: 'error', message: 'Channel not found' });
  if (!isHost(channel, userId)) {
    return res.status(403).json({ status: 'error', message: 'Only the host can broadcast' });
  }
  const text = String(message || '').slice(0, 500);
  if (!text) return res.status(400).json({ status: 'error', message: 'Message is required' });
  sendToChannel(channelName, { type: 'notice', message: text });
  res.status(200).json({ status: 'success', message: 'Notice sent' });
});

// =============================================================================
// Heartbeat
// =============================================================================

app.get('/heartbeat', (req, res) => {
  res.status(200).json({ status: 'alive' });
});

// Start the server
server.listen(port, '0.0.0.0', () => {
  console.log(`Server running and accessible from any IP on the network at port ${port}`);
});
