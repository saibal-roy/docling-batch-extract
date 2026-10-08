// Accessibility (Lighthouse): give the theme's search dialog an accessible name.
document.querySelectorAll('.md-search[role="dialog"]').forEach((el) => el.setAttribute("aria-label", "Search"));
