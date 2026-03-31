// Debug helper
function dbg(msg) {
    const el = document.getElementById('debugLog');
    const wrap = document.getElementById('debugWrap');
    if (el) { if (wrap) wrap.style.display = 'block'; el.textContent += new Date().toISOString().slice(11,19) + ' ' + msg + '\n'; el.scrollTop = el.scrollHeight; }
    console.log('[DBG]', msg);
}

// MSAL Configuration
const msalConfig = {
    auth: {
        clientId: CONFIG.clientId,
        authority: `https://login.microsoftonline.com/${CONFIG.tenantId}`,
        redirectUri: window.location.origin
    },
    cache: { cacheLocation: 'localStorage', storeAuthStateInCookie: false }
};

const msalInstance = new msal.PublicClientApplication(msalConfig);
const loginRequest = { scopes: ['User.Read', `api://${CONFIG.clientId}/access_as_user`] };
const tokenRequest = { scopes: [`api://${CONFIG.clientId}/access_as_user`] };

let currentAccount = null;

async function getAuthHeaders() {
    if (!currentAccount) { dbg('getAuthHeaders: no account'); return {}; }
    try {
        dbg('acquireTokenSilent...');
        const r = await msalInstance.acquireTokenSilent({ ...tokenRequest, account: currentAccount });
        dbg('token aud=' + (r.accessToken ? JSON.parse(atob(r.accessToken.split('.')[1])).aud : 'none'));
        return { 'Authorization': `Bearer ${r.accessToken}` };
    } catch (e) {
        dbg('acquireTokenSilent FAILED: ' + e.message);
        try {
            await msalInstance.acquireTokenRedirect(tokenRequest);
        } catch (e2) {
            dbg('acquireTokenRedirect FAILED: ' + e2.message);
        }
        return {};
    }
}

async function handleLogin() {
    await msalInstance.loginRedirect(loginRequest);
}

async function initAuth() {
    dbg('initAuth start, MSAL v=' + (msal.version || 'unknown'));
    try { await msalInstance.initialize(); dbg('initialize() OK'); } catch(e) { dbg('initialize() error: ' + e.message); }
    const response = await msalInstance.handleRedirectPromise();
    dbg('handleRedirectPromise: ' + (response ? 'got response' : 'null'));
    if (response) {
        currentAccount = response.account;
        dbg('account from redirect: ' + currentAccount.username);
    } else {
        const accounts = msalInstance.getAllAccounts();
        dbg('cached accounts: ' + accounts.length);
        if (accounts.length > 0) {
            currentAccount = accounts[0];
            dbg('account from cache: ' + currentAccount.username);
        } else {
            dbg('no accounts, redirecting to login...');
            await handleLogin();
            return;
        }
    }
}
