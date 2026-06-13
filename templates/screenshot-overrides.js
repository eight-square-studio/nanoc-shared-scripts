window.scrollTo(0, 0);

// Pin all 100vh elements before viewport resize inflates them
const __vh = window.innerHeight;
const __vhFix = document.createElement('style');
__vhFix.textContent = `.hero, .section, .error-page, .login-page { min-height: ${__vh}px !important; }`;
document.head.appendChild(__vhFix);

const style = document.createElement('style');
style.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; } .hero__content { opacity: 1 !important; }';
document.head.appendChild(style);
document.querySelectorAll('[data-animate], [data-animate-stagger], [data-animate-chips]').forEach(el => el.classList.add('is-visible'));
document.querySelectorAll('[data-hero], [data-hero-image], .hero, .hero__image, .hero__bg').forEach(el => {
  el.style.opacity = '1';
  el.style.visibility = 'visible';
});
const hero = document.querySelector('.hero__content');
if (hero) {
  hero.style.setProperty('--hero-opacity', '1');
  hero.style.setProperty('--hero-image-opacity', '1');
}

// Load every @font-face registered by the active theme's stylesheet
// (whatever families/weights it imports), rather than hardcoding a
// specific theme's font list.
const fontPromises = Array.from(document.fonts).map(font =>
  font.load().catch(() => {})
);
const imagePromises = Array.from(document.images).map(img =>
  img.decode ? img.decode().catch(() => {}) : Promise.resolve()
);
Promise.all([...fontPromises, ...imagePromises])
  .then(() => requestAnimationFrame(() => { window.__renderReady = true; }))
  .catch(() => { window.__renderReady = true; });
