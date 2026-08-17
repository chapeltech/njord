const languageStorageKey = "njord.language";
const supportedLanguages = new Set(["en-GB", "es-PA", "zh-TW"]);

function browserLanguage() {
  const languages = navigator.languages && navigator.languages.length
    ? navigator.languages
    : [navigator.language];
  for (const language of languages) {
    const base = String(language || "").toLowerCase().split("-")[0];
    if (base === "es") return "es-PA";
    if (base === "zh") return "zh-TW";
  }
  return "en-GB";
}

function storedLanguage() {
  try {
    const language = localStorage.getItem(languageStorageKey);
    return supportedLanguages.has(language) ? language : null;
  } catch {
    return null;
  }
}

function applyDocumentLanguage(language) {
  document.documentElement.lang = language;
}

const initialLanguage = storedLanguage() || browserLanguage();
applyDocumentLanguage(initialLanguage);
const app = Elm.Main.init({
  node: document.getElementById("app"),
  flags: { language: initialLanguage },
});

app.ports.saveLanguage.subscribe((language) => {
  if (!supportedLanguages.has(language)) return;
  try {
    localStorage.setItem(languageStorageKey, language);
  } catch {
    // A private browser context may reject persistence. The active tab still
    // retains the Elm model's selected language.
  }
  applyDocumentLanguage(language);
});

window.addEventListener("storage", (event) => {
  if (event.key !== languageStorageKey || !supportedLanguages.has(event.newValue)) return;
  app.ports.languageChanged.send(event.newValue);
});
