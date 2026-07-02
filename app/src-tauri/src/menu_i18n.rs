use serde_json::Value;

/// Native-menu and update-dialog strings, embedded from the SAME locale
/// files the React UI uses (app/src/i18n/locales/*.json) — one source of
/// truth for translations, read here at compile time so the Rust-side
/// window chrome (which React's i18n can't reach) matches the language the
/// user picked in Settings instead of silently following the OS locale.
const LOCALES: &[(&str, &str)] = &[
    ("en", include_str!("../../src/i18n/locales/en.json")),
    ("ja", include_str!("../../src/i18n/locales/ja.json")),
    ("zh-CN", include_str!("../../src/i18n/locales/zh-CN.json")),
    ("zh-TW", include_str!("../../src/i18n/locales/zh-TW.json")),
    ("ko", include_str!("../../src/i18n/locales/ko.json")),
    ("es", include_str!("../../src/i18n/locales/es.json")),
    ("fr", include_str!("../../src/i18n/locales/fr.json")),
    ("de", include_str!("../../src/i18n/locales/de.json")),
    ("pt-BR", include_str!("../../src/i18n/locales/pt-BR.json")),
];

fn locale_json(lang: &str) -> &'static Value {
    use std::sync::OnceLock;
    static PARSED: OnceLock<Vec<(&'static str, Value)>> = OnceLock::new();
    let parsed = PARSED.get_or_init(|| {
        LOCALES
            .iter()
            .map(|(code, raw)| (*code, serde_json::from_str(raw).expect("locale JSON is valid (checked in CI/tests)")))
            .collect()
    });
    parsed
        .iter()
        .find(|(code, _)| *code == lang)
        .or_else(|| parsed.iter().find(|(code, _)| *code == "en"))
        .map(|(_, v)| v)
        .expect("en.json is always present")
}

/// Look up `section.key` (e.g. "nativeMenu.about") for `lang`, falling back
/// to English if the key or language is missing. `{{var}}` placeholders are
/// substituted from `vars` (simple string replace — no templating engine
/// needed for this small, known-shape set of strings).
pub fn t(lang: &str, section: &str, key: &str, vars: &[(&str, &str)]) -> String {
    let lookup = |l: &str| -> Option<String> {
        locale_json(l).get(section)?.get(key)?.as_str().map(String::from)
    };
    let mut s = lookup(lang).or_else(|| lookup("en")).unwrap_or_else(|| format!("{section}.{key}"));
    for (name, value) in vars {
        s = s.replace(&format!("{{{{{name}}}}}"), value);
    }
    s
}
