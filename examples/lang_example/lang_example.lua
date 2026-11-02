-- HD2-Lang: mods/example/lang_example
-- A Chef Shared Loader language file: a few of the loader's own texts, for translators to start from. Turn it on in
-- F9 > Chef Shared Loader > Language, then chef_loader_lang_missing.txt (in the loader's folder) lists the rest.
return {
  name = 'Example (English, louder)',
  code = 'en-x-example',
  text = {
    ['ALL MODS'] = 'EVERY MOD',
    ['PERFORMANCE MONITOR'] = 'MOD COST',
    ['THIS MONITOR'] = 'THIS PANEL',
    ['OPEN THIS MENU'] = 'MENU KEY',
    ['LANGUAGE'] = 'LANGUAGE (EXAMPLE)',
  },
  patterns = {
    { '^FRAME (.*)$', 'GAME FRAME %1' },
  },
}
