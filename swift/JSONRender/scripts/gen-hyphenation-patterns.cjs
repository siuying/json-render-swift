// Generates Sources/JSONRenderPDF/Resources/hyphenation-en-us.json from the `hyphen`
// package's en-US Liang patterns (hyph-utf8, Gerard D.C. Kuiken; "Copying and
// distribution of this file, with or without modification, are permitted in any medium
// without royalty provided the copyright notice and this notice are preserved.").
// These are the patterns @react-pdf/hyphenate (react-pdf's default hyphenation) uses.
// Usage: node scripts/gen-hyphenation-patterns.cjs <path-to-hyphen-package>
const path = require("node:path");
const fs = require("node:fs");
const source = require(path.join(process.argv[2], "patterns/en-us.js"));
const output = {
  notice:
    "Hyphenation patterns for American English. Copyright (C) 1990, 2004, 2005 Gerard D.C. Kuiken. " +
    "Copying and distribution of this file, with or without modification, are permitted in any medium " +
    "without royalty provided the copyright notice and this notice are preserved. (hyph-utf8, via the `hyphen` package)",
  patterns: source.patterns,
};
const target = path.join(__dirname, "../Sources/JSONRenderPDF/Resources/hyphenation-en-us.json");
fs.writeFileSync(target, JSON.stringify(output));
console.log("wrote", target, output.patterns.length, "patterns");
