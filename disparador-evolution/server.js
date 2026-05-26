import express from "express";
import axios from "axios";
import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { fileURLToPath } from "url";

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function envValue(name, fallback = "") {
  const fileVar = process.env[`${name}_FILE`];
  if (fileVar && fs.existsSync(fileVar)) {
    return fs.readFileSync(fileVar, "utf8").trim();
  }
  return process.env[name] ?? fallback;
}

const PORT = Number(envValue("PORT", "3000"));
const EVOLUTION_URL = envValue("EVOLUTION_URL", "").replace(/\/+$/, "");
const GLOBAL_API_KEY = envValue("GLOBAL_API_KEY", "");

if (!EVOLUTION_URL) {
  console.error("ERRO: EVOLUTION_URL não configurada.");
  process.exit(1);
}

if (!GLOBAL_API_KEY) {
  console.error("ERRO: GLOBAL_API_KEY não configurada.");
  process.exit(1);
}

const app = express();
app.set("trust proxy", true);
app.use(express.json({ limit: "15mb" }));
app.use(express.static(path.join(__dirname, "public")));

const jobs = new Map();

function nowIso() {
  return new Date().toISOString();
}

function onlyDigits(value = "") {
  return String(value).replace(/\D/g, "");
}

function slugKey(value = "") {
  return String(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function randomBetween(min, max) {
  const a = Number(min) || 0;
  const b = Number(max) || 0;
  if (b <= a) return a;
  return Math.floor(Math.random() * (b - a + 1)) + a;
}

function errorMessage(err) {
  return (
    err?.response?.data?.message ||
    err?.response?.data?.error ||
    err?.response?.data?.detail ||
    err?.message ||
    "Erro desconhecido"
  );
}

async function evoRequest({ method = "GET", endpoint, apikey, data }) {
  const response = await axios({
    method,
    url: `${EVOLUTION_URL}${endpoint}`,
    headers: {
      apikey,
      "Content-Type": "application/json"
    },
    data,
    timeout: 60000
  });

  return response.data;
}

async function sendText({ token, number, text, delay = 0 }) {
  return evoRequest({
    method: "POST",
    endpoint: "/send/text",
    apikey: token,
    data: {
      number,
      text,
      delay
    }
  });
}

function buildVars(contact) {
  const vars = { ...(contact.vars || {}) };

  vars.nome = vars.nome || contact.name || "";
  vars.numero = vars.numero || contact.number || "";
  vars.primeiro_nome = vars.primeiro_nome || (vars.nome ? vars.nome.split(/\s+/)[0] : "");

  return vars;
}

function renderTemplate(template, contact) {
  const vars = buildVars(contact);
  return String(template || "").replace(/\{([a-zA-Z0-9_]+)\}/g, (_, key) => {
    return String(vars[key] ?? "");
  });
}

function sanitizeContacts(rawContacts = [], defaultCountryCode = "55") {
  const valid = [];
  const invalid = [];
  const seen = new Set();

  for (const item of rawContacts) {
    const vars = {};
    const sourceVars = item?.vars || {};

    for (const [k, v] of Object.entries(sourceVars)) {
      vars[slugKey(k)] = String(v ?? "").trim();
    }

    let name =
      String(item?.name || vars.nome || vars.name || "").trim();

    let number =
      String(
        item?.number ||
          vars.numero ||
          vars.telefone ||
          vars.celular ||
          vars.whatsapp ||
          vars.phone ||
          ""
      ).trim();

    number = onlyDigits(number);

    const dddPlusNumberLength = number.length;

    if (number && dddPlusNumberLength <= 11 && defaultCountryCode) {
      const cc = onlyDigits(defaultCountryCode);
      if (cc && !number.startsWith(cc)) {
        number = `${cc}${number}`;
      }
    }

    if (!number || number.length < 10) {
      invalid.push({
        input: item,
        reason: "Número ausente ou inválido"
      });
      continue;
    }

    if (!name) {
      name = "";
    }

    if (seen.has(number)) {
      invalid.push({
        input: item,
        reason: "Número duplicado"
      });
      continue;
    }

    seen.add(number);

    valid.push({
      name,
      number,
      vars: {
        ...vars,
        nome: vars.nome || name,
        numero: number
      }
    });
  }

  return { valid, invalid };
}

function publicJob(job) {
  return {
    id: job.id,
    status: job.status,
    createdAt: job.createdAt,
    startedAt: job.startedAt,
    finishedAt: job.finishedAt,
    total: job.total,
    sent: job.sent,
    failed: job.failed,
    current: job.current,
    minDelayMs: job.minDelayMs,
    maxDelayMs: job.maxDelayMs,
    logs: job.logs.slice(-150),
    failures: job.failures.slice(-100),
    cancelRequested: job.cancelRequested
  };
}

function logJob(job, text) {
  job.logs.push(`[${new Date().toLocaleTimeString("pt-BR")}] ${text}`);
  if (job.logs.length > 300) job.logs.shift();
}

async function runJob(job) {
  job.status = "running";
  job.startedAt = nowIso();
  logJob(job, `Início do disparo com ${job.total} contato(s).`);

  for (let i = 0; i < job.contacts.length; i += 1) {
    if (job.cancelRequested) {
      job.status = "canceled";
      job.finishedAt = nowIso();
      logJob(job, "Disparo cancelado pelo usuário.");
      return;
    }

    const contact = job.contacts[i];
    const text = renderTemplate(job.messageTemplate, contact);

    job.current = i + 1;
    logJob(job, `Enviando para ${contact.number} (${job.current}/${job.total})`);

    try {
      await sendText({
        token: job.token,
        number: contact.number,
        text,
        delay: 0
      });

      job.sent += 1;
      logJob(job, `OK: ${contact.number}`);
    } catch (err) {
      job.failed += 1;
      const msg = errorMessage(err);
      job.failures.push({
        number: contact.number,
        name: contact.name,
        error: msg
      });
      logJob(job, `ERRO: ${contact.number} -> ${msg}`);
    }

    if (i < job.contacts.length - 1) {
      const wait = randomBetween(job.minDelayMs, job.maxDelayMs);
      logJob(job, `Aguardando ${wait} ms`);
      await sleep(wait);
    }
  }

  job.status = "completed";
  job.finishedAt = nowIso();
  logJob(job, "Disparo finalizado.");
}

app.get("/api/health", async (_req, res) => {
  res.json({
    ok: true,
    appTime: nowIso(),
    jobs: jobs.size
  });
});

app.get("/api/instances", async (_req, res) => {
  try {
    const data = await evoRequest({
      method: "GET",
      endpoint: "/instance/all",
      apikey: GLOBAL_API_KEY
    });

    const instances = Array.isArray(data?.data) ? data.data : [];

    res.json({
      ok: true,
      instances: instances.map((item) => ({
        id: item.id,
        name: item.name,
        connected: Boolean(item.connected),
        token: item.token || "",
        createdAt: item.createdAt || null
      }))
    });
  } catch (err) {
    res.status(500).json({
      ok: false,
      message: errorMessage(err)
    });
  }
});

app.post("/api/instances", async (req, res) => {
  try {
    const name = String(req.body?.name || "").trim();
    const token = String(req.body?.token || "").trim();

    if (!name) {
      return res.status(400).json({ ok: false, message: "Informe o nome da instância." });
    }

    const payload = { name };
    if (token) payload.token = token;

    const data = await evoRequest({
      method: "POST",
      endpoint: "/instance/create",
      apikey: GLOBAL_API_KEY,
      data: payload
    });

    res.json({
      ok: true,
      data
    });
  } catch (err) {
    res.status(500).json({
      ok: false,
      message: errorMessage(err)
    });
  }
});

app.post("/api/instance/status", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    if (!token) {
      return res.status(400).json({ ok: false, message: "Token da instância é obrigatório." });
    }

    const data = await evoRequest({
      method: "GET",
      endpoint: "/instance/status",
      apikey: token
    });

    res.json({ ok: true, data });
  } catch (err) {
    res.status(500).json({ ok: false, message: errorMessage(err) });
  }
});

app.post("/api/instance/connect", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    const webhookUrl = String(req.body?.webhookUrl || "").trim();
    const immediate = Boolean(req.body?.immediate);
    const phone = String(req.body?.phone || "").trim();
    const subscribe = Array.isArray(req.body?.subscribe) && req.body.subscribe.length
      ? req.body.subscribe
      : ["ALL"];

    if (!token) {
      return res.status(400).json({ ok: false, message: "Token da instância é obrigatório." });
    }

    const payload = {
      subscribe,
      immediate
    };

    if (webhookUrl) payload.webhookUrl = webhookUrl;
    if (phone) payload.phone = onlyDigits(phone);

    const data = await evoRequest({
      method: "POST",
      endpoint: "/instance/connect",
      apikey: token,
      data: payload
    });

    res.json({ ok: true, data });
  } catch (err) {
    res.status(500).json({ ok: false, message: errorMessage(err) });
  }
});

app.post("/api/instance/qr", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    if (!token) {
      return res.status(400).json({ ok: false, message: "Token da instância é obrigatório." });
    }

    const data = await evoRequest({
      method: "GET",
      endpoint: "/instance/qr",
      apikey: token
    });

    res.json({ ok: true, data });
  } catch (err) {
    res.status(500).json({ ok: false, message: errorMessage(err) });
  }
});

app.post("/api/instance/pair", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    const phone = onlyDigits(req.body?.phone || "");
    const subscribe = Array.isArray(req.body?.subscribe) && req.body.subscribe.length
      ? req.body.subscribe
      : ["ALL"];

    if (!token) {
      return res.status(400).json({ ok: false, message: "Token da instância é obrigatório." });
    }

    if (!phone) {
      return res.status(400).json({ ok: false, message: "Informe o telefone para pareamento." });
    }

    const data = await evoRequest({
      method: "POST",
      endpoint: "/instance/pair",
      apikey: token,
      data: {
        phone,
        subscribe
      }
    });

    res.json({ ok: true, data });
  } catch (err) {
    res.status(500).json({ ok: false, message: errorMessage(err) });
  }
});

app.post("/api/send/test", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    const text = String(req.body?.text || "").trim();
    const delay = Number(req.body?.delay || 0);
    const defaultCountryCode = String(req.body?.defaultCountryCode || "55").trim();

    let number = onlyDigits(req.body?.number || "");
    if (number.length <= 11 && defaultCountryCode && !number.startsWith(defaultCountryCode)) {
      number = `${onlyDigits(defaultCountryCode)}${number}`;
    }

    if (!token) {
      return res.status(400).json({ ok: false, message: "Token da instância é obrigatório." });
    }
    if (!number) {
      return res.status(400).json({ ok: false, message: "Número é obrigatório." });
    }
    if (!text) {
      return res.status(400).json({ ok: false, message: "Texto é obrigatório." });
    }

    const data = await sendText({ token, number, text, delay });

    res.json({ ok: true, data });
  } catch (err) {
    res.status(500).json({ ok: false, message: errorMessage(err) });
  }
});

app.post("/api/jobs", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    const messageTemplate = String(req.body?.message || "").trim();
    const minDelayMs = Math.max(0, Number(req.body?.minDelayMs || 5000));
    const maxDelayMs = Math.max(minDelayMs, Number(req.body?.maxDelayMs || 12000));
    const defaultCountryCode = String(req.body?.defaultCountryCode || "55").trim();

    if (!token) {
      return res.status(400).json({ ok: false, message: "Token da instância é obrigatório." });
    }

    if (!messageTemplate) {
      return res.status(400).json({ ok: false, message: "Mensagem é obrigatória." });
    }

    const rawContacts = Array.isArray(req.body?.contacts) ? req.body.contacts : [];
    const { valid, invalid } = sanitizeContacts(rawContacts, defaultCountryCode);

    if (!valid.length) {
      return res.status(400).json({
        ok: false,
        message: "Nenhum contato válido para disparo.",
        invalid
      });
    }

    const id = crypto.randomUUID();

    const job = {
      id,
      status: "queued",
      createdAt: nowIso(),
      startedAt: null,
      finishedAt: null,
      token,
      messageTemplate,
      contacts: valid,
      total: valid.length,
      current: 0,
      sent: 0,
      failed: 0,
      failures: [],
      logs: [],
      minDelayMs,
      maxDelayMs,
      cancelRequested: false
    };

    jobs.set(id, job);

    runJob(job).catch((err) => {
      job.status = "failed";
      job.finishedAt = nowIso();
      logJob(job, `Falha geral do job: ${errorMessage(err)}`);
    });

    res.json({
      ok: true,
      job: publicJob(job),
      invalid
    });
  } catch (err) {
    res.status(500).json({
      ok: false,
      message: errorMessage(err)
    });
  }
});

app.get("/api/jobs/:id", (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) {
    return res.status(404).json({ ok: false, message: "Job não encontrado." });
  }
  res.json({ ok: true, job: publicJob(job) });
});

app.post("/api/jobs/:id/cancel", (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) {
    return res.status(404).json({ ok: false, message: "Job não encontrado." });
  }

  job.cancelRequested = true;
  logJob(job, "Cancelamento solicitado.");
  res.json({ ok: true, job: publicJob(job) });
});

app.get("*", (_req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

app.listen(PORT, () => {
  console.log(`Disparador rodando na porta ${PORT}`);
});
