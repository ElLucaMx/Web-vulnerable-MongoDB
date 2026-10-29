'use strict';

const loginView = document.querySelector('#login-view');
const dashboardView = document.querySelector('#dashboard-view');
const loginForm = document.querySelector('#login-form');
const loginError = document.querySelector('#login-error');
const dashboardError = document.querySelector('#dashboard-error');
const collectionList = document.querySelector('#collection-list');
const documentsTitle = document.querySelector('#documents-title');
const documentsSubtitle = document.querySelector('#documents-subtitle');
const documentsEmpty = document.querySelector('#documents-empty');
const documentsOutput = document.querySelector('#documents-output');
const documentCount = document.querySelector('#document-count');
const welcomeUser = document.querySelector('#welcome-user');

async function apiFetch(url, options = {}) {
  const response = await fetch(url, {
    credentials: 'same-origin',
    cache: 'no-store',
    ...options,
  });
  let payload;
  try {
    payload = await response.json();
  } catch {
    throw new Error('El servidor ha devuelto una respuesta que no es JSON válido.');
  }
  return { response, payload };
}

function showLogin(message = '') {
  loginView.hidden = false;
  dashboardView.hidden = true;
  loginError.hidden = !message;
  loginError.textContent = message;
  dashboardError.hidden = true;
  documentsOutput.hidden = true;
  documentsEmpty.hidden = false;
  loginForm.reset();
}

function showDashboard(user) {
  loginView.hidden = true;
  dashboardView.hidden = false;
  welcomeUser.textContent = `Sesión iniciada como ${user.displayName || user.username}. Selecciona una colección para consultar sus documentos.`;
  dashboardError.hidden = true;
}

function showDashboardError(message) {
  dashboardError.textContent = message;
  dashboardError.hidden = false;
}

function renderCollections(collections) {
  collectionList.replaceChildren();
  if (!Array.isArray(collections) || collections.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'muted small-copy';
    empty.textContent = 'No hay colecciones asignadas a esta cuenta.';
    collectionList.append(empty);
    return;
  }

  for (const collection of collections) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'collection-button';
    button.dataset.collection = collection;
    const icon = document.createElement('span');
    icon.className = 'collection-icon';
    icon.textContent = '▤';
    const label = document.createElement('span');
    label.className = 'collection-name';
    label.textContent = collection;
    const arrow = document.createElement('span');
    arrow.className = 'collection-arrow';
    arrow.textContent = '→';
    button.append(icon, label, arrow);
    button.addEventListener('click', () => loadDocuments(collection, button));
    collectionList.append(button);
  }
}

async function loadCollections(user) {
  try {
    const { response, payload } = await apiFetch('/api/collections.php');
    if (response.status === 401) {
      showLogin();
      return;
    }
    if (!response.ok || !payload.ok) throw new Error(payload.error || 'No se pudieron cargar las colecciones.');
    renderCollections(payload.collections);
  } catch (error) {
    showDashboardError(error.message || 'No se pudieron cargar las colecciones.');
  }
}

async function loadDocuments(collection, selectedButton) {
  for (const button of collectionList.querySelectorAll('.collection-button')) {
    button.classList.toggle('selected', button === selectedButton);
  }
  documentsTitle.textContent = collection;
  documentsSubtitle.textContent = 'Cargando documentos…';
  documentsEmpty.hidden = true;
  documentsOutput.hidden = true;
  documentCount.hidden = true;
  dashboardError.hidden = true;

  try {
    const query = new URLSearchParams({ collection });
    const { response, payload } = await apiFetch(`/api/documents.php?${query.toString()}`);
    if (response.status === 401) {
      showLogin('La sesión ha caducado. Vuelve a iniciar sesión.');
      return;
    }
    if (!response.ok || !payload.ok) throw new Error(payload.error || 'No se pudieron consultar los documentos.');

    documentsSubtitle.textContent = 'Documentos devueltos por MongoDB';
    documentCount.textContent = `${payload.count} ${payload.count === 1 ? 'documento' : 'documentos'}`;
    documentCount.hidden = false;
    documentsOutput.replaceChildren();
    if (payload.documents.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'muted small-copy';
      empty.textContent = 'La colección no contiene documentos.';
      documentsOutput.append(empty);
    } else {
      for (const documentData of payload.documents) {
        const article = document.createElement('article');
        article.className = 'document-card';
        const pre = document.createElement('pre');
        // Se usa textContent, no innerHTML, para que los datos no se interpreten como HTML.
        pre.textContent = JSON.stringify(documentData, null, 2);
        article.append(pre);
        documentsOutput.append(article);
      }
    }
    documentsOutput.hidden = false;
  } catch (error) {
    documentsSubtitle.textContent = 'No se han podido cargar los documentos.';
    showDashboardError(error.message || 'No se pudieron consultar los documentos.');
  }
}

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  loginError.hidden = true;
  const button = loginForm.querySelector('button[type="submit"]');
  button.disabled = true;
  button.textContent = 'Comprobando…';
  try {
    const formData = new FormData(loginForm);
    const body = {
      username: formData.get('username'),
                           password: formData.get('password'),
    };
    const { response, payload } = await apiFetch('/api/login.php', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!response.ok || !payload.ok) throw new Error(payload.error || 'No se ha podido iniciar sesión.');
    showDashboard(payload.user);
    await loadCollections(payload.user);
  } catch (error) {
    loginError.textContent = error.message || 'No se ha podido contactar con el servidor.';
    loginError.hidden = false;
  } finally {
    button.disabled = false;
    button.innerHTML = 'Entrar <span aria-hidden="true">→</span>';
  }
});

document.querySelector('#logout-button').addEventListener('click', async () => {
  try {
    await apiFetch('/api/logout.php', { method: 'POST' });
  } catch {
    // La pantalla vuelve al login aunque la petición de cierre falle.
  }
  showLogin();
});

(async function restoreSession() {
  try {
    const { response, payload } = await apiFetch('/api/collections.php');
    if (!response.ok || !payload.ok) return;
    showDashboard(payload.user || { username: 'usuario', displayName: 'Usuario autenticado' });
    renderCollections(payload.collections);
  } catch {
    // Una sesión ausente es el estado normal al entrar por primera vez.
  }
})();
