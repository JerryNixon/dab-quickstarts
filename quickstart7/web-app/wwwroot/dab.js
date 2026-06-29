// ── DAB Data Layer ──
// Same-origin calls are proxied by ASP.NET to the local DAB process sidecar.

const TODOS_URL = '/api/Todos';

async function fetchTodos() {
    try {
        const res = await fetch(TODOS_URL);
        if (!res.ok) throw new Error(res.status);
        const data = await res.json();
        return data.value || [];
    } catch (e) {
        console.error('Fetch failed:', e.message);
        return [];
    }
}

async function createTodo(title, dueDate) {
    const headers = { 'Content-Type': 'application/json' };
    const body = JSON.stringify({
        Title: title,
        DueDate: dueDate,
        Owner: 'anonymous',
        Completed: false
    });
    const res = await fetch(TODOS_URL, { method: 'POST', headers, body });
    if (!res.ok) { console.error('Create failed:', res.status); return false; }
    return true;
}

async function toggleTodo(id, completed) {
    const headers = { 'Content-Type': 'application/json' };
    const res = await fetch(`${TODOS_URL}/TodoId/${id}`, {
        method: 'PATCH', headers,
        body: JSON.stringify({ Completed: !completed })
    });
    if (!res.ok) { console.error('Update failed:', res.status); return false; }
    return true;
}

async function deleteTodo(id) {
    const res = await fetch(`${TODOS_URL}/TodoId/${id}`, { method: 'DELETE' });
    if (!res.ok) { console.error('Delete failed:', res.status); return false; }
    return true;
}
