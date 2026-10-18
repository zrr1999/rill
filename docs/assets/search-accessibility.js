/* Localized guidance for the pinned Zensical 0.0.70 search component. */
(() => {
  const observed = new WeakSet();
  const described = new WeakSet();
  const triggers = '.md-search__button, .md-header label[for="__search"]';
  let returnFocus;
  document.addEventListener('click', event => {
    const trigger = event.target.closest(triggers);
    if (trigger) returnFocus = trigger;
  }, true);

  function describeSearch(root) {
    const dialog = root.querySelector('dialog');
    const input = dialog?.querySelector('input[role="combobox"]');
    if (!input || described.has(dialog)) return;
    described.add(dialog);
    // The theme's trigger wrapper is not the modal search surface.
    const triggerWrapper = document.querySelector('.md-search[data-md-component="search"]');
    triggerWrapper?.removeAttribute('role');
    triggerWrapper?.removeAttribute('aria-label');
    dialog.setAttribute('aria-label', '搜索使用文档');
    input.setAttribute('aria-label', '搜索使用文档');
    input.placeholder = '搜索使用文档';
    const controls = input.parentElement.parentElement;
    for (const [icon, label] of [['lucide-search', '关闭文档搜索'], ['lucide-list-filter', '切换搜索筛选']]) {
      controls.querySelector(`svg.${icon}`)?.closest('button')?.setAttribute('aria-label', label);
    }
    dialog.querySelector('[role="listbox"]')?.setAttribute('aria-label', '文档搜索结果');
    const filterButton = controls.querySelector('svg.lucide-list-filter')?.closest('button');
    const filterPanel = root.getElementById(filterButton?.getAttribute('aria-controls'));
    if (filterPanel) filterPanel.dataset.rillSearchFilters = 'true';
    const help = document.createElement('p');
    help.id = 'rill-search-help';
    help.style.cssText = 'font-size:14px;line-height:1.6;margin:8px 16px 12px';
    help.textContent = '搜索指南，不会搜索 App 中的个人记录。没有结果时试试较短的词，例如“语音”或“剪贴板”；按 Esc 关闭。';
    controls.after(help);
    input.setAttribute('aria-describedby', help.id);

    // Wait for the native dialog close event: focusing outside an open modal fails.
    dialog.addEventListener('close', () => {
      if (document.activeElement !== document.body && document.activeElement !== root.host) return;
      const visible = element => element?.checkVisibility({ visibilityProperty: true });
      const trigger = visible(returnFocus) ? returnFocus : [...document.querySelectorAll(triggers)].find(visible);
      if (!trigger) return;
      if (trigger.tagName === 'LABEL') trigger.tabIndex = -1;
      trigger.focus();
    });

    const style = document.createElement('style');
    style.textContent = `
      button:focus-visible { outline: 2px solid var(--md-accent-fg-color, #526cfe); outline-offset: -3px; }
      @media (max-width: 680px) {
        .e:has([data-rill-search-filters]:not([inert])) #rill-search-help { max-width: calc(100% - 232px); }
      }
      @media (prefers-reduced-motion: reduce) {
        dialog *, dialog *::before, dialog *::after { transition: none !important; animation: none !important; }
      }
    `;
    root.append(style);
  }

  function observeSearchRoots() {
    for (const host of document.body.children) {
      const root = host.shadowRoot;
      if (!root || observed.has(root)) continue;
      observed.add(root);
      new MutationObserver(() => describeSearch(root)).observe(root, { childList: true, subtree: true });
      describeSearch(root);
    }
  }
  new MutationObserver(observeSearchRoots).observe(document.body, { childList: true });
  observeSearchRoots();
})();
