const menuButton = document.querySelector('.menu-button');
const navigation = document.querySelector('.site-nav');
function setMenu(open) {
  menuButton.setAttribute('aria-expanded', String(open));
  navigation.dataset.open = String(open);
  menuButton.textContent = open ? menuButton.dataset.close : menuButton.dataset.menu;
}
menuButton.hidden = false;
setMenu(false);
menuButton.addEventListener('click', () => setMenu(menuButton.getAttribute('aria-expanded') !== 'true'));
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && menuButton.getAttribute('aria-expanded') === 'true') {
    setMenu(false);
    menuButton.focus();
  }
});
window.matchMedia('(min-width: 745px)').addEventListener('change', () => setMenu(false));
