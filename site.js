(function () {
  const navToggle = document.querySelector(".nav-toggle");
  const siteNav = document.querySelector("#siteNav");
  if (navToggle && siteNav) {
    navToggle.addEventListener("click", () => {
      const expanded = navToggle.getAttribute("aria-expanded") === "true";
      navToggle.setAttribute("aria-expanded", String(!expanded));
      siteNav.classList.toggle("open", !expanded);
    });
  }

  const menuButton = document.querySelector(".menu-button");
  const mobileNavigation = document.querySelector("#mobile-navigation");
  if (menuButton && mobileNavigation) {
    menuButton.addEventListener("click", () => {
      const expanded = menuButton.getAttribute("aria-expanded") === "true";
      menuButton.setAttribute("aria-expanded", String(!expanded));
      menuButton.setAttribute("aria-label", expanded ? "Открыть меню" : "Закрыть меню");
      mobileNavigation.classList.toggle("is-open", !expanded);
    });

    mobileNavigation.querySelectorAll("a").forEach((link) => {
      link.addEventListener("click", () => {
        menuButton.setAttribute("aria-expanded", "false");
        menuButton.setAttribute("aria-label", "Открыть меню");
        mobileNavigation.classList.remove("is-open");
      });
    });
  }

  const siteRoot = new URL(window.ENDLESSNET_SITE_ROOT || "./", window.location.href);
  const adminURL = new URL(
    window.ENDLESSNET_ADMIN_URL || "https://admin.endlessnet.ru/",
    siteRoot,
  ).href;

  document.querySelectorAll("[data-admin-link]").forEach((element) => {
    element.setAttribute("href", adminURL);
  });

  document.querySelectorAll("[data-copy-target]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = document.getElementById(button.dataset.copyTarget);
      if (!target) {
        return;
      }
      try {
        await navigator.clipboard.writeText(target.textContent || "");
        button.textContent = "Скопировано";
        window.setTimeout(() => {
          button.textContent = "Копировать";
        }, 1600);
      } catch {
        button.textContent = "Ошибка";
        window.setTimeout(() => {
          button.textContent = "Копировать";
        }, 1600);
      }
    });
  });

  drawNetworkCanvas();
  window.addEventListener("resize", drawNetworkCanvas);

  function drawNetworkCanvas() {
    const canvas = document.querySelector("#networkCanvas");
    if (!canvas) {
      return;
    }
    const rect = canvas.getBoundingClientRect();
    const scale = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.floor(rect.width * scale));
    canvas.height = Math.max(1, Math.floor(rect.height * scale));

    const ctx = canvas.getContext("2d");
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    ctx.clearRect(0, 0, rect.width, rect.height);

    ctx.fillStyle = "#111815";
    ctx.fillRect(0, 0, rect.width, rect.height);

    const points = makePoints(rect.width, rect.height);
    ctx.lineWidth = 1.5;
    points.forEach((point, index) => {
      for (let offset = 1; offset <= 2; offset += 1) {
        const peer = points[(index + offset * 3) % points.length];
        ctx.strokeStyle = offset === 1 ? "rgba(54, 199, 152, 0.28)" : "rgba(69, 139, 255, 0.18)";
        ctx.beginPath();
        ctx.moveTo(point.x, point.y);
        ctx.lineTo(peer.x, peer.y);
        ctx.stroke();
      }
    });

    points.forEach((point, index) => {
      const radius = index % 5 === 0 ? 8 : 5;
      ctx.fillStyle = index % 3 === 0 ? "#36c798" : "#dbeafe";
      ctx.beginPath();
      ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
      ctx.fill();
    });
  }

  function makePoints(width, height) {
    const count = width < 640 ? 18 : 34;
    const points = [];
    for (let index = 0; index < count; index += 1) {
      const row = Math.floor(index / 6);
      const column = index % 6;
      const x = (width / 6) * column + 40 + ((row * 29) % 60);
      const y = (height / Math.ceil(count / 6)) * row + 46 + ((column * 19) % 44);
      points.push({
        x: Math.min(width - 24, x),
        y: Math.min(height - 24, y),
      });
    }
    return points;
  }
})();
