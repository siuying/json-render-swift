// Generates Sources/JSONRenderPDF/Resources/helvetica-metrics.json from pdfkit's Adobe
// Core14 AFM files (freely redistributable), as used by react-pdf for standard fonts.
// Usage: node scripts/gen-helvetica-metrics.cjs <path-to-pdfkit-package>
const path = require("node:path");
const fs = require("node:fs");
const pdfkitDir = process.argv[2];
const PDFDocument = require(path.join(pdfkitDir, "js/pdfkit.js"));
const doc = new PDFDocument({ autoFirstPage: false });

// WinAnsi (cp1252) code -> Unicode scalar for 0x80-0x9F; identity elsewhere.
const cp1252 = {
  0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
  0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018,
  0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc,
  0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
};
// Adobe's AFM terms require the copyright notices and the permission paragraph to be kept
// and modifications to be noted, so the generated file carries them in "notice".
const output = {
  source: "pdfkit Core14 AFM (Adobe), WinAnsi encoding",
  notice:
    "Glyph widths and kerning pairs converted from the Adobe Core14 AFM files for Helvetica, Helvetica-Bold, Helvetica-Oblique and Helvetica-BoldOblique (as shipped in pdfkit). This is a modification: only widths and kern pairs for WinAnsi characters are kept, keyed by Unicode scalar. Copyright (c) 1985, 1987, 1989, 1990, 1997 Adobe Systems Incorporated. All Rights Reserved. Helvetica is a trademark of Linotype-Hell AG and/or its subsidiaries. This file and the 14 PostScript(R) AFM files it accompanies may be used, copied, and distributed for any purpose and without charge, with or without modification, provided that all copyright notices are retained; that the AFM files are not distributed without this file; that all modifications to this file or any of the AFM files are prominently noted in the modified file(s); and that this paragraph is not modified. Adobe Systems has no responsibility or obligation to support the use of the AFM files.",
  ascent: 900, descent: -200, unitsPerEm: 1000, fonts: {},
};
for (const name of ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"]) {
  doc.font(name);
  const afm = doc._font.font;
  const widths = {};
  const glyphOf = {};
  for (let code = 32; code < 256; code++) {
    if (code >= 0x80 && code <= 0x9f && !cp1252[code]) continue;
    const scalar = cp1252[code] ?? code;
    const glyph = afm.characterToGlyph(code);
    if (!glyph || glyph === ".notdef") continue;
    widths[scalar] = afm.widthOfGlyph(glyph);
    glyphOf[scalar] = glyph;
  }
  const kerning = {};
  const scalars = Object.keys(glyphOf);
  for (const left of scalars) {
    for (const right of scalars) {
      const value = afm.getKernPair(glyphOf[left], glyphOf[right]);
      if (value) kerning[`${left},${right}`] = value;
    }
  }
  output.fonts[name] = { widths, kerning };
}
const target = path.join(__dirname, "../Sources/JSONRenderPDF/Resources/helvetica-metrics.json");
fs.writeFileSync(target, JSON.stringify(output));
console.log("wrote", target, fs.statSync(target).size, "bytes");
