(() => {
  const panel = document.querySelector('#reading-toc');
  const toggle = document.querySelector('#toc-toggle');
  const scrim = document.querySelector('.toc-scrim');
  const main = document.querySelector('main');
  const header = document.querySelector('.topbar');
  const wide = matchMedia('(min-width:1280px)');
  const links = [...panel.querySelectorAll('a[href^="#"]')];
  const targets = links.map(link => ({link, target: document.getElementById(link.hash.slice(1))}));
  targets.forEach(({target}) => target.classList.add('toc-target'));
  let open = false;
  let pending = false;
  let current = null;

  function setOpen(value, restoreFocus = false) {
    open = value && !wide.matches;
    document.documentElement.classList.toggle('toc-open', open);
    toggle.setAttribute('aria-expanded', String(open));
    scrim.hidden = !open;
    main.inert = open;
    header.inert = open;
    panel.inert = !wide.matches && !open;
    if (open) {
      panel.setAttribute('role', 'dialog');
      panel.setAttribute('aria-modal', 'true');
      requestAnimationFrame(() => {if (open) panel.querySelector('.toc-close').focus();});
    } else {
      panel.removeAttribute('role');
      panel.removeAttribute('aria-modal');
      if (restoreFocus) toggle.focus();
    }
  }

  function updateCurrent() {
    pending = false;
    let active = targets[0];
    for (const entry of targets) {
      if (entry.target.getBoundingClientRect().top <= 110) active = entry;
    }
    if (scrollY + innerHeight >= document.documentElement.scrollHeight - 4) active = targets[targets.length - 1];
    if (current === active.link) return;
    current = active.link;
    links.forEach(link => {
      link.classList.toggle('is-current', link === current);
      if (link === current) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    });
    const group = current.closest('[data-toc-group]');
    panel.querySelectorAll('[data-toc-group]').forEach(node => node.classList.toggle('is-active', node === group));
    if (wide.matches) {
      const box = current.getBoundingClientRect();
      const bounds = panel.getBoundingClientRect();
      if (box.top < bounds.top + 40 || box.bottom > bounds.bottom) {
        panel.scrollTop += box.top - bounds.top - 60;
      }
    }
  }

  function scheduleUpdate() {
    if (!pending) {
      pending = true;
      requestAnimationFrame(updateCurrent);
    }
  }

  toggle.addEventListener('click', () => setOpen(!open));
  panel.querySelector('.toc-close').addEventListener('click', () => setOpen(false, true));
  scrim.addEventListener('click', () => setOpen(false, true));
  panel.addEventListener('click', event => {
    const link = event.target.closest('a[href^="#"]');
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (open) {
      setOpen(false);
      const target = document.getElementById(link.hash.slice(1));
      target.setAttribute('tabindex', '-1');
      requestAnimationFrame(() => target.focus({preventScroll:true}));
    }
  });
  document.addEventListener('keydown', event => {
    if (!open) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      setOpen(false, true);
    }
    if (event.key === 'Tab') {
      const items = [...panel.querySelectorAll('button,a[href]')];
      const first = items[0], last = items[items.length - 1];
      if (!panel.contains(document.activeElement)) {
        event.preventDefault(); (event.shiftKey ? last : first).focus();
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault(); last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault(); first.focus();
      }
    }
  });
  wide.addEventListener('change', () => {
    const hadFocus = panel.contains(document.activeElement);
    setOpen(false);
    if (hadFocus) (wide.matches ? current : toggle).focus({preventScroll:true});
    scheduleUpdate();
  });
  addEventListener('scroll', scheduleUpdate, {passive:true});
  addEventListener('resize', scheduleUpdate);
  addEventListener('hashchange', scheduleUpdate);
  new ResizeObserver(scheduleUpdate).observe(main);
  document.documentElement.classList.add('toc-ready');
  setOpen(false);
  updateCurrent();
})();
