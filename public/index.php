<?php
declare(strict_types=1);
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header('X-Frame-Options: DENY');
header('Cache-Control: no-store, max-age=0');
?>
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>NoSQL Lab · Consulta de datos</title>
  <link rel="stylesheet" href="/assets/style.css">
  <script src="/assets/app.js" defer></script>
</head>
<body>
  <main class="page-shell">
    <header class="topbar">
      <a class="brand" href="/" aria-label="NoSQL Lab, inicio">
        <span class="brand-mark" aria-hidden="true">N</span>
        <span><strong>NoSQL Lab</strong><small>Consulta de datos</small></span>
      </a>
      <span class="environment-label">Entorno académico</span>
    </header>

    <section id="login-view" class="login-layout" aria-labelledby="login-title">
      <div class="welcome-copy">
        <p class="eyebrow">PORTAL DE DATOS</p>
        <h1>Accede a tu espacio de trabajo.</h1>
        <p>Inicia sesión para consultar las colecciones que tienes asignadas en el laboratorio.</p>
        <div class="feature-line"><span aria-hidden="true">✓</span> Acceso a datos de laboratorio</div>
        <div class="feature-line"><span aria-hidden="true">✓</span> Consulta de documentos en MongoDB</div>
      </div>
      <form id="login-form" class="panel login-panel">
        <div class="panel-heading">
          <p class="eyebrow">BIENVENIDO</p>
          <h2 id="login-title">Iniciar sesión</h2>
          <p>Introduce las credenciales de tu cuenta.</p>
        </div>
        <label for="username">Usuario</label>
        <input id="username" name="username" type="text" autocomplete="username" required>
        <label for="password">Contraseña</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <p id="login-error" class="message error" role="alert" hidden></p>
        <button class="primary-button" type="submit">Entrar <span aria-hidden="true">→</span></button>
        <p class="form-footnote">Usa una de las cuentas ficticias asignadas a la práctica.</p>
      </form>
    </section>

    <section id="dashboard-view" class="dashboard" hidden aria-labelledby="dashboard-title">
      <div class="dashboard-heading">
        <div>
          <p class="eyebrow">ESPACIO DE TRABAJO</p>
          <h1 id="dashboard-title">Tus colecciones</h1>
          <p id="welcome-user" class="muted">Selecciona una colección para consultar sus documentos.</p>
        </div>
        <button id="logout-button" class="secondary-button" type="button">Cerrar sesión</button>
      </div>
      <div id="dashboard-error" class="message error" role="alert" hidden></div>
      <div class="workspace">
        <aside class="panel collections-panel">
          <div class="panel-heading compact-heading">
            <h2>Colecciones autorizadas</h2>
            <p>Solo se muestran las asignadas a tu cuenta.</p>
          </div>
          <div id="collection-list" class="collection-list" aria-live="polite"></div>
        </aside>
        <section class="panel documents-panel" aria-labelledby="documents-title">
          <div class="panel-heading compact-heading documents-heading">
            <div><h2 id="documents-title">Documentos</h2><p id="documents-subtitle">Selecciona una colección.</p></div>
            <span id="document-count" class="count-pill" hidden>0 documentos</span>
          </div>
          <div id="documents-empty" class="empty-state">
            <span class="empty-icon" aria-hidden="true">▤</span>
            <strong>Aún no has seleccionado una colección</strong>
            <p>Elige una de la lista para ver sus documentos.</p>
          </div>
          <div id="documents-output" class="documents-output" hidden></div>
        </section>
      </div>
    </section>
    <footer class="footer"><span>MongoDB · PHP · Apache</span><span>Uso exclusivo en laboratorio aislado</span></footer>
  </main>
</body>
</html>
