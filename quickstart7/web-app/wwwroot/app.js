// ── App UI Layer ──

let tasks = [];

function renderTasks() {
    const list = document.getElementById('tasksList');

    if (tasks.length === 0) {
        list.innerHTML = `
            <div class="empty-state">
                <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                          d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <p>No tasks yet — add one above</p>
            </div>`;
        return;
    }

    list.innerHTML = tasks.map(t => `
        <div class="task-item">
            <button class="task-check ${t.Completed ? 'completed' : ''}" data-id="${t.TodoId}" data-completed="${t.Completed}" data-action="toggle">
                ${t.Completed ? '✓' : ''}
            </button>
            <div class="task-content">
                <div class="task-title ${t.Completed ? 'completed' : ''}">${escapeHtml(t.Title)}</div>
                <div class="task-meta">Due ${new Date(t.DueDate).toLocaleDateString()}</div>
            </div>
            <button class="task-delete" data-id="${t.TodoId}" data-action="delete">✕</button>
        </div>
    `).join('');
}

function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

async function loadTodos() {
    tasks = await fetchTodos();
    renderTasks();
}

async function loadSidecarStatus() {
    const state = document.getElementById('dabState');
    const pill = document.getElementById('dabPill');
    const message = document.getElementById('dabMessage');
    const output = document.getElementById('dabOutput');

    try {
        const res = await fetch('/dab/status');
        const status = await res.json();
        const isRunning = status.running === true;
        state.textContent = isRunning ? 'Running' : status.state;
        pill.textContent = status.state;
        pill.className = `status-pill ${isRunning ? 'running' : 'failed'}`;
        message.textContent = status.errorMessage || `DAB is exposed through ${status.accessMode}.`;

        if (status.output) {
            output.hidden = false;
            output.textContent = status.output;
        } else {
            output.hidden = true;
            output.textContent = '';
        }
    } catch (e) {
        state.textContent = 'Unknown';
        pill.textContent = 'unknown';
        pill.className = 'status-pill failed';
        message.textContent = `Unable to read DAB status: ${e.message}`;
        output.hidden = true;
    }
}

document.getElementById('refreshBtn').addEventListener('click', async () => {
    await loadSidecarStatus();
    await loadTodos();
});

document.getElementById('addForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const titleInput = document.getElementById('newTitle');
    const dateInput = document.getElementById('newDueDate');
    const title = titleInput.value.trim();
    const dueDate = dateInput.value;
    if (!title || !dueDate) return;
    titleInput.value = '';
    dateInput.value = new Date().toISOString().split('T')[0];
    if (await createTodo(title, dueDate)) await loadTodos();
});

document.getElementById('tasksList').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const id = Number(btn.dataset.id);
    if (btn.dataset.action === 'toggle') {
        if (await toggleTodo(id, btn.dataset.completed === 'true')) await loadTodos();
    } else if (btn.dataset.action === 'delete') {
        if (await deleteTodo(id)) await loadTodos();
    }
});

document.getElementById('newDueDate').value = new Date().toISOString().split('T')[0];
loadSidecarStatus();
loadTodos();
setInterval(loadSidecarStatus, 5000);
