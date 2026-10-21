const toggle = document.querySelector('#demo-toggle');
toggle.addEventListener('click', () => {
  const enabled = toggle.getAttribute('aria-checked') !== 'true';
  toggle.setAttribute('aria-checked', String(enabled));
  document.querySelector('#demo-status').textContent = enabled ? 'オン · 起動を維持' : 'オフ · 通常のスリープ';
});
