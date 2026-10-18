/* Keyboard disclosure semantics for the pinned Zensical 0.0.70 navigation. */
(() => {
  const initialized = new WeakSet();
  const wide = matchMedia('(min-width: 76.25em)');
  function enhanceNavigation() {
    for (const label of document.querySelectorAll('.md-nav__item--nested > label[for]')) {
      const toggle = document.getElementById(label.htmlFor);
      const nav = label.nextElementSibling;
      if (!toggle || nav?.tagName !== 'NAV') continue;
      nav.id = `${toggle.id}_panel`;
      const back = nav.querySelector(`label[for="${toggle.id}"]`);
      const controls = [label, back].filter(Boolean);
      const collapsible = () => !wide.matches || !label.parentElement.classList.contains('md-nav__item--section');
      const update = () => {
        for (const control of controls) {
          if (collapsible()) {
            control.tabIndex = 0;
            control.setAttribute('role', 'button');
            control.setAttribute('aria-controls', nav.id);
          } else {
            control.removeAttribute('tabindex');
            control.removeAttribute('role');
            control.removeAttribute('aria-controls');
          }
        }
        if (collapsible()) label.setAttribute('aria-expanded', String(toggle.checked));
        else label.removeAttribute('aria-expanded');
        nav.removeAttribute('aria-expanded');
      };
      if (!initialized.has(label)) {
        initialized.add(label);
        for (const control of controls) {
          control.addEventListener('keydown', event => {
            if (!collapsible() || (event.key !== 'Enter' && event.key !== ' ')) return;
            event.preventDefault();
            event.stopPropagation();
            toggle.click();
            const target = toggle.checked && back?.getClientRects().length ? back : label;
            requestAnimationFrame(() => target?.focus());
          });
        }
        toggle.addEventListener('change', update);
      }
      update();
    }
  }
  wide.addEventListener('change', enhanceNavigation);
  document$.subscribe(enhanceNavigation);
  const style = document.createElement('style');
  style.textContent = '.md-nav label[role="button"]:focus-visible { outline: 2px solid var(--md-accent-fg-color); outline-offset: -2px; }';
  document.head.append(style);
})();
