const copyButton = document.querySelector('[data-copy]');
if (copyButton) {
  copyButton.addEventListener('click', async () => {
    const status = document.querySelector('.copy-status');
    copyButton.disabled = true;
    try {
      await navigator.clipboard.writeText(document.querySelector('#build-command').textContent);
      status.textContent = copyButton.dataset.success;
    } catch {
      status.textContent = copyButton.dataset.failure;
    } finally {
      copyButton.disabled = false;
    }
  });
}
