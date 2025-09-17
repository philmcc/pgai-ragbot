const API = '/api';

function headers() {
  const h = { 'Content-Type': 'application/json' };
  const embed = localStorage.getItem('embed_model');
  const chat = localStorage.getItem('chat_model');
  if (embed) h['X-Embedding-Model'] = embed;
  if (chat) h['X-Chat-Model'] = chat;
  return h;
}

async function fetchStatus() {
  const res = await fetch(`${API}/v_ingest_status`, { headers: headers() });
  const data = await res.json();
  document.getElementById('status').textContent = JSON.stringify(data, null, 2);
}

async function fetchVectorizerStatus() {
  try {
    const res = await fetch(`${API}/v_vectorizer_status`, { headers: headers() });
    const data = await res.json();
    document.getElementById('vecStatus').textContent = JSON.stringify(data, null, 2);
  } catch (e) {
    document.getElementById('vecStatus').textContent = 'Unavailable';
  }
}

async function listDocs() {
  const pre = document.getElementById('docsList');
  if (!pre) return;
  pre.textContent = 'Loading...';
  try {
    // Prefer GET for no-arg stable function (PostgREST RPC)
    let res = await fetch(`${API}/rpc/list_documents`, { headers: headers() });
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
    const lines = (Array.isArray(data) ? data : [])
      .map(d => `#${d.id}  ${d.s3_key}  (${new Date(d.created_at).toLocaleString()})`);
    pre.textContent = lines.join('\n') || '(no documents found)';
  } catch (e) {
    pre.textContent = `Error: ${e?.message || e}`;
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
    alert('Ingest triggered');
  } catch (e) {
    console.error('Ingest error:', e);
    await fetchStatus();
    alert(`Ingest failed: ${e?.message || e}`);
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

  // If debug toggle is on, run retrieval preview first
  const show = document.getElementById('showChunks')?.checked;
  const th = parseFloat(document.getElementById('threshold')?.value);
  if (show) {
    await debugSearch(q, k, th);
  }

  const res = await fetch(`${API}/rpc/chat_rag`, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({ p_query: q, k })
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

function init() {
  // Key storage is in DB now
  document.getElementById('saveKey').onclick = async () => {
    const key = document.getElementById('apiKey').value.trim();
    try {
      const res = await fetch(`${API}/rpc/set_openai_key`, {
        method: 'POST', headers: headers(), body: JSON.stringify({ p_key: key })
      });
      if (!res.ok) throw new Error(await res.text());
      await refreshKeyStatus();
      alert('Saved to database');
    } catch (e) {
      alert(`Save failed: ${e?.message || e}`);
    }
  };
  document.getElementById('clearKey').onclick = async () => {
    try {
      const res = await fetch(`${API}/rpc/set_openai_key`, {
        method: 'POST', headers: headers(), body: JSON.stringify({ p_key: '' })
      });
      if (!res.ok) throw new Error(await res.text());
      await refreshKeyStatus();
      alert('Cleared in database');
    } catch (e) {
      alert(`Clear failed: ${e?.message || e}`);
    }
  };
  document.getElementById('saveModels').onclick = () => {
    localStorage.setItem('embed_model', document.getElementById('embedModel').value.trim() || 'text-embedding-3-small');
    localStorage.setItem('chat_model', document.getElementById('chatModel').value.trim() || 'gpt-4o-mini');
    alert('Saved');
  };

  document.getElementById('askBtn').onclick = ask;
  document.getElementById('refreshStatus').onclick = fetchStatus;
  document.getElementById('refreshVec').onclick = fetchVectorizerStatus;
  document.getElementById('ingestNow').onclick = (e) => { e.preventDefault(); ingestNow(); };
  const listBtn = document.getElementById('listDocs');
  if (listBtn) listBtn.onclick = listDocs;

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

  fetchStatus();
  listDocs();
  refreshKeyStatus();
  fetchVectorizerStatus();
}

async function refreshKeyStatus() {
  try {
    const res = await fetch(`${API}/rpc/openai_key_status`, { headers: headers() });
    const data = await res.json();
    const el = document.getElementById('keyStatus');
    if (el) el.textContent = `Key status: ${data?.configured ? 'configured' : 'not set'}${data?.updated_at ? ' (updated ' + new Date(data.updated_at).toLocaleString() + ')' : ''}`;
  } catch (e) {
    const el = document.getElementById('keyStatus');
    if (el) el.textContent = 'Key status: error';
  }
}

window.addEventListener('DOMContentLoaded', init);
