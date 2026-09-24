const { Resvg } = require('@resvg/resvg-js');
const fs = require('fs');
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="80"><rect width="300" height="80" fill="#fff"/><text x="10" y="40" font-family="Manrope" font-weight="800" font-size="24" fill="#000">Привет 123 O'zbekcha</text></svg>`;
const r = new Resvg(svg, {
  font: { fontFiles: ['node_modules/@expo-google-fonts/manrope/800ExtraBold/Manrope_800ExtraBold.ttf'], loadSystemFonts: false, defaultFontFamily: 'Manrope' }
});
const png = r.render().asPng();
fs.writeFileSync('test-cyrillic.png', png);
console.log('bytes:', png.length);
