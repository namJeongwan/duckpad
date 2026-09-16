(() => {
  const picker = document.querySelector('.language-picker');
  const trigger = picker.querySelector('summary');
  const search = picker.querySelector('input');
  const list = picker.querySelector('ul');
  const options = [...list.querySelectorAll('a')];
  const empty = picker.querySelector('.language-empty');
  let visible = options;
  let active = -1;
  const normalize = value => value.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().trim();

  search.hidden = false;
  search.setAttribute('role', 'combobox');
  search.setAttribute('aria-autocomplete', 'list');
  search.setAttribute('aria-controls', list.id);
  search.setAttribute('aria-expanded', 'false');
  list.setAttribute('role', 'listbox');
  for (const option of options) {
    option.setAttribute('role', 'option');
    option.tabIndex = -1;
    option.parentElement.setAttribute('role', 'presentation');
  }

  function highlight(index) {
    active = index;
    for (const option of options) {
      const selected = option === visible[active];
      option.toggleAttribute('data-active', selected);
      option.setAttribute('aria-selected', String(selected));
    }
    if (active >= 0) {
      search.setAttribute('aria-activedescendant', visible[active].id);
      visible[active].scrollIntoView({ block: 'nearest' });
    } else search.removeAttribute('aria-activedescendant');
  }

  function filter() {
    const query = normalize(search.value);
    visible = options.filter(option => normalize(option.dataset.search).includes(query));
    for (const option of options) option.parentElement.hidden = !visible.includes(option);
    empty.hidden = visible.length !== 0;
    highlight(visible.length ? 0 : -1);
  }

  function close(restoreFocus = false) {
    picker.open = false;
    search.setAttribute('aria-expanded', 'false');
    if (restoreFocus) trigger.focus();
  }

  picker.addEventListener('toggle', () => {
    search.setAttribute('aria-expanded', String(picker.open));
    if (!picker.open) return;
    search.value = '';
    filter();
    const current = visible.findIndex(option => option.hasAttribute('aria-current'));
    if (current >= 0) highlight(current);
    search.focus({ preventScroll: true });
  });
  search.addEventListener('input', filter);
  search.addEventListener('keydown', event => {
    if (event.isComposing) return;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (visible.length) highlight((active + (event.key === 'ArrowDown' ? 1 : -1) + visible.length) % visible.length);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      if (active >= 0) window.location.assign(visible[active].href);
    }
  });
  picker.addEventListener('keydown', event => {
    if (event.key === 'Escape' && picker.open) {
      event.preventDefault();
      event.stopPropagation();
      close(true);
    }
  });
  picker.addEventListener('focusout', event => {
    if (event.relatedTarget && !picker.contains(event.relatedTarget)) close();
  });
  document.addEventListener('pointerdown', event => {
    if (picker.open && !picker.contains(event.target)) close();
  });
})();
