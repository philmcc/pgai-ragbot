  // Load & apply persisted retrieval settings once DOM is ready
  const saved = JSON.parse(localStorage.getItem('retrieval_settings') || '{}');
  const retrievalMode = document.getElementById('retrievalMode');
  const pinSem = document.getElementById('pinSem');
  const smartChk = document.getElementById('smartWeight');
  const wLexEl = document.getElementById('wLex');
  const wSemEl = document.getElementById('wSem');
  const stageKEl = document.getElementById('stageK');
  const rerankModelEl = document.getElementById('rerankModel');
  const DEF = {
    mode: 'semantic',
    pin: 3,
    smart: true,
    wLex: 0.3,
    wSem: 0.7,
    stageK: 60,
    rerankModel: 'BAAI/bge-reranker-base'
  };
  if (retrievalMode) retrievalMode.value = saved.mode || DEF.mode;
  if (pinSem) pinSem.value = (Number.isFinite(saved.pin) ? saved.pin : DEF.pin);
  if (smartChk) smartChk.checked = (typeof saved.smart === 'boolean') ? saved.smart : DEF.smart;
  if (wLexEl) wLexEl.value = (Number.isFinite(saved.wLex) ? saved.wLex : DEF.wLex);
  if (wSemEl) wSemEl.value = (Number.isFinite(saved.wSem) ? saved.wSem : DEF.wSem);
  if (stageKEl) stageKEl.value = (Number.isFinite(saved.stageK) ? saved.stageK : DEF.stageK);
  if (rerankModelEl) rerankModelEl.value = saved.rerankModel || DEF.rerankModel;

  const persist = () => {
    const toSave = {
      mode: (retrievalMode?.value || DEF.mode),
      pin: parseInt(pinSem?.value ?? DEF.pin, 10) || DEF.pin,
      smart: !!smartChk?.checked,
      wLex: Number(wLexEl?.value ?? DEF.wLex),
      wSem: Number(wSemEl?.value ?? DEF.wSem),
      stageK: parseInt(stageKEl?.value ?? DEF.stageK, 10) || DEF.stageK,
      rerankModel: (rerankModelEl?.value || DEF.rerankModel),
    };
    localStorage.setItem('retrieval_settings', JSON.stringify(toSave));
  };

  retrievalMode?.addEventListener('change', () => {
    persist();
    updateEffectiveNote(retrievalMode.value, Number(wLexEl?.value), Number(wSemEl?.value), !!smartChk?.checked);
    toggleRerankInputs(retrievalMode.value);
  });
  pinSem?.addEventListener('change', () => { persist(); });
  smartChk?.addEventListener('change', () => { persist(); updateEffectiveNote(retrievalMode?.value, Number(wLexEl?.value), Number(wSemEl?.value), !!smartChk?.checked); });
  stageKEl?.addEventListener('change', () => { persist(); });
  rerankModelEl?.addEventListener('change', () => { persist(); });

function toggleRerankInputs(mode) {
  const show = /rerank/.test(mode || '');
  if (stageKEl) {
    stageKEl.disabled = !show;
    stageKEl.parentElement?.classList?.toggle('disabled', !show);
  }
  if (rerankModelEl) {
    rerankModelEl.disabled = !show;
    rerankModelEl.parentElement?.classList?.toggle('disabled', !show);
  }
}

toggleRerankInputs(retrievalMode?.value || DEF.mode);
// Compute smart weights for a query; base weights are used as a starting point
function computeSmartWeights(q, base = { baseLex: 0.3, baseSem: 0.7 }) {
  const text = (q || '').trim();
  const tokens = text.split(/\s+/).filter(Boolean);
  const isShort = tokens.length > 0 && tokens.length <= 6;
  const hasDigits = /\d/.test(text);
  const hasAcronym = /\b[A-Z]{2,}\b/.test(text);
  const looksLikeCode = /[_#\-\.]/.test(text);

  let wLex = Number(base.baseLex ?? 0.3);
  let wSem = Number(base.baseSem ?? 0.7);

  if (isShort) { wLex += 0.20; wSem -= 0.20; }
  if (hasDigits) { wLex += 0.10; wSem -= 0.10; }
  if (hasAcronym) { wLex += 0.10; wSem -= 0.10; }
  if (looksLikeCode) { wLex += 0.05; wSem -= 0.05; }

  // Clamp and renormalize to sum to 1
  wLex = Math.max(0, Math.min(1, wLex));
  wSem = Math.max(0, Math.min(1, wSem));
  const sum = wLex + wSem;
  if (sum === 0) { wLex = 0.3; wSem = 0.7; }
  else { wLex = wLex / sum; wSem = wSem / sum; }

  return { wLex, wSem };
}
// Update the "Effective weights" note below sliders
function updateEffectiveNote(mode, wLex, wSem, smart) {
  const el = document.getElementById('wEffNote');
  if (!el) return;
  if ((mode || 'semantic') !== 'hybrid') {
    el.textContent = 'Semantic mode: weights are not used';
    return;
  }
  const l = (Number(wLex) || 0).toFixed(2);
  const s = (Number(wSem) || 0).toFixed(2);
  el.textContent = smart ? `Effective weights (smart): lex=${l}, sem=${s}` : `Effective weights: lex=${l}, sem=${s}`;
}

const API = '/api';

function headers() {
  // Keep requests simple to avoid CORS preflight complexities
  return { 'Content-Type': 'application/json' };
}

// Preview retrieval results using selected retrieval mode
async function debugSearch(q, k, th) {
  const pre = document.getElementById('retrievalDebug');
  if (!pre) return;
  pre.textContent = 'Loading...';
  try {
    const mode = (document.getElementById('retrievalMode')?.value || 'semantic').toLowerCase();
    const smart = !!document.getElementById('smartWeight')?.checked;
    let wLex = Number(document.getElementById('wLex')?.value ?? 0.5);
    let wSem = Number(document.getElementById('wSem')?.value ?? 0.5);
    const stageK = parseInt(document.getElementById('stageK')?.value, 10) || 60;
    const rerankModel = document.getElementById('rerankModel')?.value?.trim();
    if (mode === 'hybrid' && smart && q) {
      const { wLex: wl, wSem: ws } = computeSmartWeights(q, { baseLex: wLex, baseSem: wSem });
      wLex = wl; wSem = ws;
    }
    updateEffectiveNote(mode, wLex, wSem, smart);
    let endpoint = `${API}/rpc/search_chunks`;
    let body = { p_query: q, k };
    if (mode === 'hybrid') {
      endpoint = `${API}/rpc/search_chunks_hybrid`;
      body = { p_query: q, k, p_w_lex: wLex, p_w_sem: wSem };
    } else if (mode === 'semantic_rerank' || mode === 'hybrid_rerank') {
      endpoint = `${API}/rpc/search_chunks_rerank`;
      const stageMode = mode === 'semantic_rerank' ? 'semantic' : 'hybrid';
      body = {
        p_query: q,
        k,
        p_stage_k: stageK,
        p_stage_mode: stageMode,
        p_w_lex: wLex,
        p_w_sem: wSem,
        p_rerank_model: rerankModel || null
      };
    }
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify(body)
    });
    if (!res.ok) {
      let t = '';
      try { t = await res.text(); } catch (_) {}
      throw new Error(`HTTP ${res.status} ${t}`);
    }
    const rows = await res.json();

    // Optional threshold: results return a fused distance (lower is better)
    let items = Array.isArray(rows) ? rows : [];
    if (!isNaN(th) && th !== null && th !== undefined) {
      const thr = Number(th);
      if (!Number.isNaN(thr)) items = items.filter(r => typeof r.distance === 'number' && r.distance <= thr);
    }
    if (mode === 'semantic_rerank' || mode === 'hybrid_rerank') {
      items.sort((a, b) => (b.rerank_score ?? -1e6) - (a.rerank_score ?? -1e6));
    } else {
      items.sort((a, b) => (a.distance ?? 0) - (b.distance ?? 0));
    }

    // Fetch doc list to annotate filenames
    let docMap = {};
    try {
      let ld = await fetch(`${API}/rpc/list_documents`);
      if (ld.ok) {
        const arr = await ld.json();
        (Array.isArray(arr) ? arr : []).forEach(d => { docMap[d.id] = d.s3_key; });
      }
    } catch (_) {}

    // Render
    const lines = items.map((r, i) => {
      const key = docMap[r.doc_id] || `doc ${r.doc_id}`;
      const chunk = (r.chunk || '').replace(/\s+/g, ' ').slice(0, 240);
      const dist = (typeof r.distance === 'number') ? r.distance.toFixed(4) : String(r.distance);
      const scorePart = (mode === 'semantic_rerank' || mode === 'hybrid_rerank')
        ? `score=${(r.rerank_score !== null && r.rerank_score !== undefined) ? Number(r.rerank_score).toFixed(4) : 'n/a'}`
        : `dist=${dist}`;
      return `${i+1}. ${key}  #${r.seq}  ${scorePart}\n   ${chunk}`;
    });
    pre.textContent = lines.join('\n\n') || '(no results)';
  } catch (e) {
    pre.textContent = `Error: ${e?.message || e}`;
  }
}

// Promise-based confirm modal
function showConfirm(title, message, confirmText = 'Yes', cancelText = 'Cancel') {
  return new Promise((resolve) => {
    showModal(title, message, {
      buttons: [
        { text: cancelText, variant: 'secondary', onClick: () => resolve(false) },
        { text: confirmText, variant: 'primary', onClick: () => resolve(true) }
      ]
    });
  });
}

// Modal dialog helpers
function hideModal() {
  const overlay = document.getElementById('modalOverlay');
  if (!overlay) return;
  overlay.style.display = 'none';
  overlay.setAttribute('aria-hidden', 'true');
}

function showModal(title, message, opts = {}) {
  const overlay = document.getElementById('modalOverlay');
  const titleEl = document.getElementById('modalTitle');
  const bodyEl = document.getElementById('modalMessage');
  const actions = document.getElementById('modalActions');
  if (!overlay || !titleEl || !bodyEl || !actions) return;
  titleEl.textContent = title || '';
  bodyEl.textContent = message || '';
  actions.innerHTML = '';
  const buttons = opts.buttons && opts.buttons.length ? opts.buttons : [{ text: 'OK', variant: 'primary', onClick: hideModal }];
  buttons.forEach(b => {
    const btn = document.createElement('button');
    btn.textContent = b.text || 'OK';
    btn.className = b.variant === 'secondary' ? 'btn-secondary' : '';
    btn.onclick = () => { try { b.onClick && b.onClick(); } finally { if (!b.keepOpen) hideModal(); } };
    actions.appendChild(btn);
  });
  overlay.style.display = 'flex';
  overlay.setAttribute('aria-hidden', 'false');
}

async function fetchStatus() {
  const res = await fetch(`${API}/v_ingest_status`);
  const data = await res.json();
  document.getElementById('status').textContent = JSON.stringify(data, null, 2);
  updateEmbeddingProgressFromStatus(data);
}

async function fetchVectorizerStatus() {
  try {
    const res = await fetch(`${API}/v_vectorizer_status`);
    const data = await res.json();
    document.getElementById('vecStatus').textContent = JSON.stringify(data, null, 2);
  } catch (e) {
    document.getElementById('vecStatus').textContent = 'Unavailable';
  }
}

async function fetchVectorizerWorker() {
  try {
    const res = await fetch(`${API}/v_vectorizer_worker_progress`);
    const data = await res.json();
    document.getElementById('vecWorker').textContent = JSON.stringify(data, null, 2);
  } catch (e) {
    document.getElementById('vecWorker').textContent = 'Unavailable';
  }
}

function updateChunkModeBadge(mode) {
  const el = document.getElementById('chunkModeBadge');
  if (!el) return;
  const pretty = (mode || '').toLowerCase() === 'llm' ? 'LLM' : 'Heuristic';
  el.textContent = `Chunking: ${pretty}`;
}

async function fetchChunkingMode() {
  try {
    // PostgREST may require POST for volatile functions; send empty JSON body
    const res = await fetch(`${API}/rpc/chunking_mode`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({})
    });
    if (!res.ok) {
      // Try GET as a fallback in case it's exposed as stable
      const tryGet = await fetch(`${API}/rpc/chunking_mode`);
      if (!tryGet.ok) throw new Error(`HTTP ${res.status}`);
      const d2 = await tryGet.json();
      const value2 = typeof d2 === 'string' ? d2 : (Array.isArray(d2) ? d2[0]?.chunking_mode : 'heuristic');
      updateChunkModeBadge(value2);
      return;
    }
    // RPC returning scalar text often comes as JSON string
    const data = await res.json();
    const value = typeof data === 'string' ? data : (Array.isArray(data) ? data[0]?.chunking_mode : 'heuristic');
    updateChunkModeBadge(value);
  } catch (_) {
    updateChunkModeBadge('heuristic');
  }
}

async function listDocs() {
  const container = document.getElementById('docsList');
  if (!container) return;
  container.textContent = 'Loading...';
  try {
    // Prefer GET for no-arg stable function (PostgREST RPC)
    let res = await fetch(`${API}/rpc/list_documents`);
    if (!res.ok) {
      // Fallback to POST with empty body (some setups prefer POST)
      res = await fetch(`${API}/rpc/list_documents`, {
        method: 'POST',
        headers: headers(),
        body: JSON.stringify({})
      });
    }
    if (!res.ok) {
      let errText = '';
      try { errText = await res.text(); } catch (_) {}
      throw new Error(`HTTP ${res.status}: ${errText || 'List documents failed'}`);
    }
    const data = await res.json();
    const docs = Array.isArray(data) ? data : [];
    if (docs.length === 0) {
      container.textContent = '(no documents found)';
      return;
    }
    // Render list with delete buttons
    container.innerHTML = '';
    const ul = document.createElement('div');
    docs.forEach(d => {
      const row = document.createElement('div');
      row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #1e2238;padding:6px 0;gap:8px;';
      const left = document.createElement('div');
      left.textContent = `#${d.id}  ${d.s3_key}  (${new Date(d.created_at).toLocaleString()})`;
      const delBtn = document.createElement('button');
      delBtn.textContent = 'Delete';
      delBtn.style.cssText = 'background:#ef4444';
      delBtn.addEventListener('click', async () => {
        const ok = await showConfirm('Confirm delete', `Delete document ${d.s3_key}? This will remove its chunks/embeddings.`, 'Delete', 'Cancel');
        if (!ok) return;
        await deleteDocument(d.id);
      });
      row.appendChild(left);
      row.appendChild(delBtn);
      ul.appendChild(row);
    });
    container.appendChild(ul);
  } catch (e) {
    container.textContent = `Error: ${e?.message || e}`;
  }
}

async function deleteDocument(id) {
  try {
    const res = await fetch(`${API}/rpc/delete_document`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({ p_id: id })
    });
    if (!res.ok) {
      let t = '';
      try { t = await res.text(); } catch (_) {}
      throw new Error(`HTTP ${res.status} ${t}`);
    }
    showModal('Deleted', `Deleted document #${id}`);
    await fetchStatus();
    await listDocs();
  } catch (e) {
    showModal('Delete failed', `${e?.message || e}`);
  }
}

async function deleteAllDocuments() {
  const ok = await showConfirm('Confirm delete all', 'Delete ALL documents? This removes all chunks/embeddings.', 'Delete all', 'Cancel');
  if (!ok) return;
  try {
    const res = await fetch(`${API}/rpc/delete_all_documents`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({})
    });
    if (!res.ok) {
      let t = '';
      try { t = await res.text(); } catch (_) {}
      throw new Error(`HTTP ${res.status} ${t}`);
    }
    showModal('Deleted', 'Deleted all documents');
    await fetchStatus();
    await listDocs();
  } catch (e) {
    showModal('Delete all failed', `${e?.message || e}`);
  }
}

async function ingestNow() {
  // Call an RPC to run the job once (SECURITY DEFINER)
  try {
    const res = await fetch(`${API}/rpc/run_ingest_once`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({})
    });

    if (!res.ok) {
      // Try to extract error details
      let errText = '';
      try { errText = await res.text(); } catch (_) {}
      throw new Error(`HTTP ${res.status}: ${errText || 'Ingest RPC failed'}`);
    }

    // Some PostgREST configs return 204 No Content; others return JSON or a JSON string
    const ct = res.headers.get('content-type') || '';
    if (ct.includes('application/json')) {
      try { await res.json(); } catch (_) { /* ignore parse issues */ }
    } else {
      try { await res.text(); } catch (_) { /* ignore */ }
    }

    await fetchStatus();
    showModal('Ingest', 'Ingest triggered');
  } catch (e) {
    console.error('Ingest error:', e);
    await fetchStatus();
    showModal('Ingest failed', `${e?.message || e}`);
  }
}

async function ask() {
  const q = document.getElementById('question').value.trim();
  const k = parseInt(document.getElementById('topK').value, 10) || 5;
  if (!q) return;
  const messages = document.getElementById('messages');
  const me = document.createElement('div');
  me.className = 'msg';
  me.innerHTML = `<div class="role">You</div><div class="bubble">${q}</div>`;
  messages.appendChild(me);
  messages.scrollTop = messages.scrollHeight;

  // If the user is asking for documents/files, answer deterministically using the RPC
  const docIntent = /(list|show|which|what).*(document|documents|doc|docs|file|files)|\b(document|documents|doc|docs|file|files)\b.*(do you have|are stored|do you store)/i;
  if (docIntent.test(q)) {
    try {
      // Prefer GET for stable no-arg RPCs; fallback to POST
      let res = await fetch(`${API}/rpc/list_documents`);
      if (!res.ok) {
        res = await fetch(`${API}/rpc/list_documents`, { method: 'POST', headers: headers(), body: JSON.stringify({}) });
      }
      const data = await res.json();
      const lines = (Array.isArray(data) ? data : []).map((d, i) => `${i+1}. ${d.s3_key}`);
      const ans = document.createElement('div');
      ans.className = 'msg';
      ans.innerHTML = `<div class="role">Assistant</div><div class="bubble">The documents I have are:\n\n${lines.join('\n') || '(none)'}</div>`;
      messages.appendChild(ans);
      messages.scrollTop = messages.scrollHeight;
      return;
    } catch (e) {
      showModal('List documents failed', `${e?.message || e}`);
      // Fall through to normal chat as a backup
    }
  }

  // If debug toggle is on, run retrieval preview first
  const show = document.getElementById('showChunks')?.checked;
  const th = parseFloat(document.getElementById('threshold')?.value);
  if (show) {
    await debugSearch(q, k, th);
  }

  const mode = (document.getElementById('retrievalMode')?.value || 'semantic').toLowerCase();
  const smart = !!document.getElementById('smartWeight')?.checked;
  let wLex = Number(document.getElementById('wLex')?.value ?? 0.5);
  let wSem = Number(document.getElementById('wSem')?.value ?? 0.5);
  const stageK = parseInt(document.getElementById('stageK')?.value, 10) || 60;
  const rerankModel = document.getElementById('rerankModel')?.value?.trim() || null;
  if (mode === 'hybrid' && smart && q) {
    const { wLex: wl, wSem: ws } = computeSmartWeights(q, { baseLex: wLex, baseSem: wSem });
    wLex = wl; wSem = ws;
  }
  updateEffectiveNote(mode, wLex, wSem, smart);
  const pinSem = parseInt(document.getElementById('pinSem')?.value, 10) || 3;
  const useRerank = mode === 'semantic_rerank' || mode === 'hybrid_rerank';
  const stageMode = mode === 'semantic_rerank' ? 'semantic' : (mode === 'hybrid_rerank' ? 'hybrid' : null);
  const res = await fetch(`${API}/rpc/chat_rag_opts`, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({
      p_query: q,
      k,
      p_mode: mode,
      p_w_lex: wLex,
      p_w_sem: wSem,
      p_pin_sem: pinSem,
      p_stage_k: stageK,
      p_use_rerank: useRerank,
      p_rerank_stage_mode: stageMode,
      p_rerank_model: rerankModel
    })
  });
  let text;
  const ct = res.headers.get('content-type') || '';
  if (ct.includes('application/json')) {
    const data = await res.json();
    // PostgREST may return a JSON string for scalar text
    if (typeof data === 'string') {
      text = data;
    } else if (Array.isArray(data)) {
      // In some configs, RPC returns array of objects
      text = data[0]?.chat_rag || JSON.stringify(data);
    } else {
      text = JSON.stringify(data);
    }
  } else {
    text = await res.text();
  }
  const ans = document.createElement('div');
  ans.className = 'msg';
  ans.innerHTML = `<div class="role">Assistant</div><div class="bubble">${text}</div>`;
  messages.appendChild(ans);
  messages.scrollTop = messages.scrollHeight;
}

function updateEmbeddingProgressFromStatus(statusRows) {
  try {
    const total = (statusRows || []).reduce((acc, r) => acc + (r.chunks_total || 0), 0);
    const missing = (statusRows || []).reduce((acc, r) => acc + (r.chunks_pending || 0), 0);
    const done = Math.max(total - missing, 0);
    const pct = total > 0 ? Math.round((done / total) * 100) : 0;
    const bar = document.getElementById('embedProgress');
    const txt = document.getElementById('embedProgressText');
    if (bar) bar.style.width = `${pct}%`;
    if (txt) txt.textContent = `${done} / ${total} (${pct}%)`;
  } catch (_) {}
}

function init() {
  document.getElementById('saveModels').onclick = () => {
    localStorage.setItem('embed_model', document.getElementById('embedModel').value.trim() || 'text-embedding-3-small');
    localStorage.setItem('chat_model', document.getElementById('chatModel').value.trim() || 'gpt-4o-mini');
    showModal('Success', 'Models saved');
  };

  document.getElementById('askBtn').onclick = ask;
  document.getElementById('refreshStatus').onclick = fetchStatus;
  document.getElementById('refreshVec').onclick = fetchVectorizerStatus;
  const refreshVW = document.getElementById('refreshVecWorker');
  if (refreshVW) refreshVW.onclick = fetchVectorizerWorker;
  const refreshRerankLogBtn = document.getElementById('refreshRerankLog');
  if (refreshRerankLogBtn) refreshRerankLogBtn.onclick = fetchRerankLog;
  document.getElementById('ingestNow').onclick = (e) => { e.preventDefault(); ingestNow(); };
  const listBtn = document.getElementById('listDocs');
  if (listBtn) listBtn.onclick = listDocs;
  const delAllBtn = document.getElementById('deleteAllDocs');
  if (delAllBtn) delAllBtn.onclick = deleteAllDocuments;

  const showCk = document.getElementById('showChunks');
  if (showCk) showCk.onchange = () => {
    const pre = document.getElementById('retrievalDebug');
    if (!showCk.checked) { if (pre) pre.textContent = ''; return; }
    const q = document.getElementById('question').value.trim();
    const k = parseInt(document.getElementById('topK').value, 10) || 5;
    const th = parseFloat(document.getElementById('threshold')?.value);
    if (q) debugSearch(q, k, th);
  };

  const thInput = document.getElementById('threshold');
  if (thInput) thInput.onchange = () => {
    const show = document.getElementById('showChunks')?.checked;
    if (!show) return;
    const q = document.getElementById('question').value.trim();
    const k = parseInt(document.getElementById('topK').value, 10) || 5;
    const th = parseFloat(thInput.value);
    if (q) debugSearch(q, k, th);
  };

  // Weights sliders
  const wLex = wLexEl;
  const wSem = wSemEl;
  const wLexVal = document.getElementById('wLexVal');
  const wSemVal = document.getElementById('wSemVal');
  const updateWeightsUI = () => {
    if (wLexVal && wLex) wLexVal.textContent = Number(wLex.value).toFixed(2);
    if (wSemVal && wSem) wSemVal.textContent = Number(wSem.value).toFixed(2);
  };
  updateWeightsUI();
  const onWeightChange = () => {
    updateWeightsUI();
    // persist on slider change
    const savedNow = JSON.parse(localStorage.getItem('retrieval_settings') || '{}');
    const merged = Object.assign({}, savedNow, { wLex: Number(wLex?.value ?? 0.5), wSem: Number(wSem?.value ?? 0.5) });
    localStorage.setItem('retrieval_settings', JSON.stringify(merged));
    updateEffectiveNote(retrievalMode?.value || 'semantic', Number(wLex?.value), Number(wSem?.value), !!smartChk?.checked);
    const show = document.getElementById('showChunks')?.checked;
    if (!show) return;
    const q = document.getElementById('question').value.trim();
    const k = parseInt(document.getElementById('topK').value, 10) || 5;
    const th = parseFloat(document.getElementById('threshold')?.value);
    if (q) debugSearch(q, k, th);
  };
  if (wLex) wLex.addEventListener('input', onWeightChange);
  if (wSem) wSem.addEventListener('input', onWeightChange);

  fetchStatus();
  listDocs();
  fetchVectorizerStatus();
  fetchVectorizerWorker();
  fetchChunkingMode();
  fetchRerankLog();
  // Set initial effective note
  updateEffectiveNote(retrievalMode?.value || 'semantic', Number(wLexEl?.value), Number(wSemEl?.value), !!smartChk?.checked);

  // Sidebar resize logic with persistence
  const root = document.documentElement;
  const resizer = document.getElementById('sidebarResizer');
  const SIDEBAR_KEY = 'sidebar_width_px';
  const minW = 240, maxW = 600;
  const applyW = (px) => { root.style.setProperty('--sidebar-w', `${px}px`); };
  const savedW = parseInt(localStorage.getItem(SIDEBAR_KEY) || '340', 10);
  applyW(Math.min(maxW, Math.max(minW, savedW)));
  let dragging = false;
  let startX = 0;
  let startW = savedW;
  const onMove = (e) => {
    if (!dragging) return;
    const x = e.touches ? e.touches[0].clientX : e.clientX;
    const delta = x - startX;
    let w = Math.min(maxW, Math.max(minW, startW + delta));
    applyW(w);
  };
  const onUp = () => {
    if (!dragging) return;
    dragging = false;
    const styles = getComputedStyle(root);
    const col = styles.getPropertyValue('--sidebar-w').trim().replace('px','');
    const px = parseInt(col || '340', 10);
    localStorage.setItem(SIDEBAR_KEY, String(px));
    window.removeEventListener('mousemove', onMove);
    window.removeEventListener('mouseup', onUp);
    window.removeEventListener('touchmove', onMove);
    window.removeEventListener('touchend', onUp);
  };
  const onDown = (e) => {
    dragging = true;
    startX = e.touches ? e.touches[0].clientX : e.clientX;
    startW = parseInt((getComputedStyle(root).getPropertyValue('--sidebar-w') || '340px').replace('px',''),10);
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    window.addEventListener('touchmove', onMove, { passive:false });
    window.addEventListener('touchend', onUp);
    e.preventDefault();
  };
  if (resizer) {
    resizer.addEventListener('mousedown', onDown);
    resizer.addEventListener('touchstart', onDown, { passive:false });
    resizer.addEventListener('keydown', (e) => {
      const step = (e.shiftKey ? 20 : 10);
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        let cur = parseInt((getComputedStyle(root).getPropertyValue('--sidebar-w') || '340px').replace('px',''),10);
        cur += (e.key === 'ArrowLeft' ? -step : step);
        cur = Math.min(maxW, Math.max(minW, cur));
        applyW(cur);
        localStorage.setItem(SIDEBAR_KEY, String(cur));
        e.preventDefault();
      }
    });
  }

  // Attach JS tooltips for reliability (works in browsers with finicky :hover)
  (function attachTooltips(){
    const targets = document.querySelectorAll('.help, .has-tip');
    let tipEl = null;
    const show = (el, evt) => {
      const msg = el.getAttribute('data-tip') || el.getAttribute('title');
      if (!msg) return;
      tipEl = document.createElement('div');
      tipEl.textContent = msg;
      Object.assign(tipEl.style, {
        position: 'fixed',
        left: '0px', top: '0px',
        maxWidth: '320px',
        background: '#0f1530',
        color: '#e6e6eb',
        border: '1px solid #1e2238',
        borderRadius: '6px',
        padding: '8px 10px',
        zIndex: '3000',
        boxShadow: '0 6px 18px rgba(0,0,0,0.35)',
        pointerEvents: 'none',
        fontSize: '12px',
        lineHeight: '1.25'
      });
      document.body.appendChild(tipEl);
      move(evt);
    };
    const hide = () => { if (tipEl && tipEl.parentNode) { tipEl.parentNode.removeChild(tipEl); } tipEl = null; };
    const move = (evt) => {
      if (!tipEl) return;
      const margin = 12;
      let x = evt.clientX + margin;
      let y = evt.clientY + margin;
      const rect = tipEl.getBoundingClientRect();
      const vw = window.innerWidth, vh = window.innerHeight;
      if (x + rect.width + 8 > vw) x = Math.max(8, evt.clientX - rect.width - margin);
      if (y + rect.height + 8 > vh) y = Math.max(8, evt.clientY - rect.height - margin);
      tipEl.style.left = x + 'px';
      tipEl.style.top  = y + 'px';
    };
    targets.forEach(el => {
      el.addEventListener('mouseenter', (e) => show(el, e));
      el.addEventListener('mouseleave', hide);
      el.addEventListener('mousemove', move);
      // Prevent native title from hijacking
      // (keep data-tip as the source of truth)
      if (el.hasAttribute('title')) {
        el.setAttribute('data-tip', el.getAttribute('data-tip') || el.getAttribute('title'));
        el.removeAttribute('title');
      }
    });
  })();

  // (no persistent notices)

  // Collapsible cards
  // 1) Bind handlers
  document.querySelectorAll('.collapseBtn').forEach(btn => {
    btn.addEventListener('click', () => {
      const id = btn.getAttribute('data-target');
      const card = document.getElementById(id);
      if (!card) return;
      const collapsed = card.classList.toggle('collapsed');
      btn.textContent = collapsed ? 'Expand' : 'Collapse';
    });
  });
  // 2) Collapse all by default on first load
  document.querySelectorAll('.collapseBtn').forEach(btn => {
    const id = btn.getAttribute('data-target');
    const card = document.getElementById(id);
    if (!card) return;
    if (!card.classList.contains('collapsed')) {
      card.classList.add('collapsed');
    }
    btn.textContent = 'Expand';
  });
}

window.addEventListener('DOMContentLoaded', init);

async function fetchRerankLog(limit = 50) {
  const pre = document.getElementById('rerankLog');
  if (!pre) return;
  pre.textContent = 'Loading rerank events...';
  try {
    const res = await fetch(`${API}/v_rerank_events?limit=${limit}&order=created_at.desc`);
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`HTTP ${res.status} ${txt}`);
    }
    const rows = await res.json();
    const lines = (Array.isArray(rows) ? rows : []).map(r => {
      const ts = r.created_at ? new Date(r.created_at).toLocaleString() : '';
      const score = (r.rerank_score !== null && r.rerank_score !== undefined) ? Number(r.rerank_score).toFixed(3) : 'n/a';
      const dist = (r.stage_distance !== undefined && r.stage_distance !== null) ? Number(r.stage_distance).toFixed(3) : 'n/a';
      return `${ts}  q="${(r.query || '').slice(0, 48)}" doc=${r.doc_id} seq=${r.seq} score=${score} dist=${dist}`;
    });
    pre.textContent = lines.join('\n') || '(no rerank events yet)';
  } catch (err) {
    pre.textContent = `Rerank log error: ${err?.message || err}`;
  }
}
