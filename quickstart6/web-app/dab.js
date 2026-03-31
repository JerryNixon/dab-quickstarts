// ── DAB Data Layer ──
// Depends on: config.js (CONFIG), auth.js (getAuthHeaders, currentAccount, dbg)
// Pure data — no DOM, no rendering.

const API_URL = window.location.hostname === 'localhost' ? CONFIG.apiUrlLocal : CONFIG.apiUrlAzure;

async function fetchTodos() {
    if (!currentAccount) { dbg('fetchTodos: no account'); return []; }
    try {
        const headers = await getAuthHeaders();
        dbg('fetchTodos → ' + API_URL + '/api/Todos (auth=' + !!headers.Authorization + ')');
        const res = await fetch(`${API_URL}/api/Todos`, { headers });
        dbg('fetchTodos status=' + res.status);
        if (!res.ok) { const txt = await res.text(); dbg('fetchTodos body: ' + txt.substring(0,200)); throw new Error(res.status); }
        const data = await res.json();
        return data.value || [];
    } catch (e) {
        dbg('fetchTodos ERROR: ' + e.message);
        return [];
    }
}

async function createTodo(title, dueDate) {
    const headers = { ...await getAuthHeaders(), 'Content-Type': 'application/json' };
    const body = JSON.stringify({
        Title: title,
        DueDate: dueDate,
        Owner: currentAccount.idTokenClaims?.preferred_username || currentAccount.username,
        Completed: false
    });
    dbg('createTodo → POST ' + API_URL + '/api/Todos');
    const res = await fetch(`${API_URL}/api/Todos`, { method: 'POST', headers, body });
    dbg('createTodo status=' + res.status);
    if (!res.ok) { const txt = await res.text(); dbg('createTodo body: ' + txt.substring(0,200)); return false; }
    return true;
}

async function toggleTodo(id, completed) {
    const headers = { ...await getAuthHeaders(), 'Content-Type': 'application/json' };
    const res = await fetch(`${API_URL}/api/Todos/TodoId/${id}`, {
        method: 'PATCH', headers,
        body: JSON.stringify({ Completed: !completed })
    });
    if (!res.ok) { console.error('Update failed:', res.status); return false; }
    return true;
}

async function deleteTodo(id) {
    const headers = await getAuthHeaders();
    const res = await fetch(`${API_URL}/api/Todos/TodoId/${id}`, { method: 'DELETE', headers });
    if (!res.ok) { console.error('Delete failed:', res.status); return false; }
    return true;
}

async function fetchWhoAmI() {
    if (!currentAccount) { dbg('fetchWhoAmI: no account'); return null; }
    try {
        const headers = await getAuthHeaders();
        dbg('fetchWhoAmI → ' + API_URL + '/api/WhoAmI');
        const res = await fetch(`${API_URL}/api/WhoAmI`, { headers });
        dbg('fetchWhoAmI status=' + res.status);
        if (!res.ok) { const txt = await res.text(); dbg('fetchWhoAmI body: ' + txt.substring(0,200)); throw new Error(res.status); }
        const data = await res.json();
        return (data.value && data.value.length > 0) ? data.value[0].UserName : null;
    } catch (e) {
        dbg('fetchWhoAmI ERROR: ' + e.message);
        return null;
    }
}
