// Initializes PhotoSwipe 5 lightboxes for all .pswp-gallery elements.
// Requires photoswipe.umd.min.js and photoswipe-lightbox.umd.min.js loaded first
// (both expose UMD globals: PhotoSwipe and PhotoSwipeLightbox).

(function () {
  'use strict';

  function initGallery(galleryEl) {
    const showDownload = galleryEl.dataset.download !== 'false';
    const transition   = galleryEl.dataset.transition || 'zoom';
    const showBullets  = galleryEl.dataset.bullets === 'true';

    const lightbox = new PhotoSwipeLightbox({
      gallery: galleryEl,
      children: 'a.pg-item',
      pswpModule: PhotoSwipe,
      showHideAnimationType: transition,
      paddingFn: () => ({ top: 30, bottom: 70, left: 20, right: 20 }),
    });

    // Carry thumbnail alt text through to the full-size lightbox image.
    // e.content.element is the full-size <img>; the gallery <a> is e.content.data.element.
    lightbox.on('contentLoad', function (e) {
      const galleryItem = e.content.data && e.content.data.element;
      const thumbImg = galleryItem && galleryItem.querySelector('img');
      const alt = thumbImg && thumbImg.getAttribute('alt');
      if (alt && e.content.element && !e.content.element.getAttribute('alt')) {
        e.content.element.setAttribute('alt', alt);
      }
    });

    lightbox.on('uiRegister', function () {
      // Caption mirrored from the thumbnail overlay into the lightbox footer
      lightbox.pswp.ui.registerElement({
        name: 'pg-caption',
        order: 9,
        isButton: false,
        appendTo: 'root',
        html: '',
        onInit(el, pswp) {
          el.classList.add('pswp__pg-caption');
          pswp.on('change', () => {
            const slideData = pswp.currSlide && pswp.currSlide.data;
            const thumbEl = slideData && slideData.element;
            const capEl = thumbEl && thumbEl.querySelector('.pg-caption');
            el.innerHTML = capEl ? capEl.innerHTML : '';
            // Upgrade plain-text description to markdown-rendered HTML in the lightbox.
            // The HTML version is stored in data-pg-desc to avoid nested <a> in the DOM.
            if (thumbEl && thumbEl.dataset.pgDesc) {
              const descEl = el.querySelector('.pg-description');
              if (descEl) descEl.innerHTML = thumbEl.dataset.pgDesc;
            }
          });
        },
      });

      // Download button — links to the full-resolution source image
      if (showDownload) {
        lightbox.pswp.ui.registerElement({
          name: 'download-button',
          order: 8,
          isButton: true,
          tagName: 'a',
          html: {
            isCustomSVG: true,
            inner: '<path d="M20.5 14.3 17.1 18V10h-2.2v7.9l-3.4-3.6L10 16l6 6.1 6-6.1ZM23 23H9v2h14Z" id="pswp__icn-download"/>',
            outlineID: 'pswp__icn-download',
          },
          onInit(el, pswp) {
            el.setAttribute('download', '');
            el.setAttribute('target', '_blank');
            el.setAttribute('rel', 'noopener');
            pswp.on('change', () => { el.href = pswp.currSlide.data.src; });
          },
        });
      }

      // Dot navigation indicator
      if (showBullets) {
        lightbox.pswp.ui.registerElement({
          name: 'bulletsIndicator',
          className: 'pswp__bullets-indicator',
          appendTo: 'wrapper',
          onInit(el, pswp) {
            const bullets = [];
            let prevIndex = -1;
            for (let i = 0; i < pswp.getNumItems(); i++) {
              const bullet = document.createElement('div');
              bullet.className = 'pswp__bullet';
              bullet.onclick = () => pswp.goTo(i);
              el.appendChild(bullet);
              bullets.push(bullet);
            }
            pswp.on('change', () => {
              if (prevIndex >= 0) bullets[prevIndex].classList.remove('pswp__bullet--active');
              bullets[pswp.currIndex].classList.add('pswp__bullet--active');
              prevIndex = pswp.currIndex;
            });
          },
        });
      }
    });

    // Format <time> elements using Day.js. Pick datetime-format when the stored
    // ISO string has a time component (contains 'T'), date-format otherwise.
    galleryEl.querySelectorAll('time[data-date-format]').forEach(el => {
      const iso = el.getAttribute('datetime');
      if (!iso) return;
      const fmt = iso.includes('T') ? el.dataset.datetimeFormat : el.dataset.dateFormat;
      el.textContent = dayjs(iso).format(fmt);
    });

    lightbox.init();
  }

  function init() {
    document.querySelectorAll('.pswp-gallery').forEach(initGallery);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
