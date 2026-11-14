// marracat.com/app sends people on to the App Store; link-preview crawlers
// (iMessage, WhatsApp) don't run scripts, so they keep the page's own card.
location.replace(document.querySelector("a[data-app-store]").href);
