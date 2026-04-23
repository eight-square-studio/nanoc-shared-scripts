const style = document.createElement('style');
style.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }';
document.head.appendChild(style);
document.querySelectorAll('[data-animate], [data-animate-stagger] > *, [data-animate-chips] > *').forEach(el => el.classList.add('is-visible'));
document.querySelectorAll('[data-hero], [data-hero-image], .hero, .hero__image, .hero__bg').forEach(el => {
  el.style.opacity = '1';
  el.style.visibility = 'visible';
});
const hero = document.querySelector('.hero__content');
if (hero) {
  hero.style.setProperty('--hero-opacity', '1');
  hero.style.setProperty('--hero-image-opacity', '1');
}
