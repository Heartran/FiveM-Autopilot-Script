window.addEventListener('message', function(event) {
  if (event.data.action === 'toggle') {
    document.body.style.display = event.data.show ? 'block' : 'none';
  }
});

document.addEventListener('DOMContentLoaded', function() {
  document.querySelectorAll('button[data-cmd]').forEach(btn => {
    btn.addEventListener('click', () => {
      fetch(`https://${GetParentResourceName()}/command`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cmd: btn.dataset.cmd })
      });
    });
  });
  document.getElementById('close').addEventListener('click', () => {
    fetch(`https://${GetParentResourceName()}/close`, { method: 'POST' });
  });
});
