#!/usr/bin/env node
"use strict";

// Generates src/regex_unicode.bin and src/regex_unicode.zig directly from
// Node.js's RegExp engine so Unicode property escapes and /i case folding
// match the host Node.js Unicode tables exactly.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const tStart = Date.now();

// ---------------------------------------------------------------------------
// 1. Property definitions (ECMAScript Table 65-69 + Unicode 18.0 scripts)
// ---------------------------------------------------------------------------

const BINARY_PROPS = [
  ["ASCII", ["ASCII"]],
  ["ASCII_Hex_Digit", ["ASCII_Hex_Digit", "AHex"]],
  ["Alphabetic", ["Alphabetic", "Alpha"]],
  ["Any", ["Any"]],
  ["Assigned", ["Assigned"]],
  ["Bidi_Control", ["Bidi_Control", "Bidi_C"]],
  ["Bidi_Mirrored", ["Bidi_Mirrored", "Bidi_M"]],
  ["Case_Ignorable", ["Case_Ignorable", "CI"]],
  ["Cased", ["Cased"]],
  ["Changes_When_Casefolded", ["Changes_When_Casefolded", "CWCF"]],
  ["Changes_When_Casemapped", ["Changes_When_Casemapped", "CWCM"]],
  ["Changes_When_Lowercased", ["Changes_When_Lowercased", "CWL"]],
  ["Changes_When_NFKC_Casefolded", ["Changes_When_NFKC_Casefolded", "CWKCF"]],
  ["Changes_When_Titlecased", ["Changes_When_Titlecased", "CWT"]],
  ["Changes_When_Uppercased", ["Changes_When_Uppercased", "CWU"]],
  ["Dash", ["Dash"]],
  ["Default_Ignorable_Code_Point", ["Default_Ignorable_Code_Point", "DI"]],
  ["Deprecated", ["Deprecated", "Dep"]],
  ["Diacritic", ["Diacritic", "Dia"]],
  ["Emoji", ["Emoji"]],
  ["Emoji_Component", ["Emoji_Component", "EComp"]],
  ["Emoji_Modifier", ["Emoji_Modifier", "EMod"]],
  ["Emoji_Modifier_Base", ["Emoji_Modifier_Base", "EBase"]],
  ["Emoji_Presentation", ["Emoji_Presentation", "EPres"]],
  ["Extended_Pictographic", ["Extended_Pictographic", "ExtPict"]],
  ["Extender", ["Extender", "Ext"]],
  ["Grapheme_Base", ["Grapheme_Base", "Gr_Base"]],
  ["Grapheme_Extend", ["Grapheme_Extend", "Gr_Ext"]],
  ["Hex_Digit", ["Hex_Digit", "Hex"]],
  ["IDS_Binary_Operator", ["IDS_Binary_Operator", "IDSB"]],
  ["IDS_Trinary_Operator", ["IDS_Trinary_Operator", "IDST"]],
  ["ID_Continue", ["ID_Continue", "IDC"]],
  ["ID_Start", ["ID_Start", "IDS"]],
  ["Ideographic", ["Ideographic", "Ideo"]],
  ["Join_Control", ["Join_Control", "Join_C"]],
  ["Logical_Order_Exception", ["Logical_Order_Exception", "LOE"]],
  ["Lowercase", ["Lowercase", "Lower"]],
  ["Math", ["Math"]],
  ["Noncharacter_Code_Point", ["Noncharacter_Code_Point", "NChar"]],
  ["Pattern_Syntax", ["Pattern_Syntax", "Pat_Syn"]],
  ["Pattern_White_Space", ["Pattern_White_Space", "Pat_WS"]],
  ["Quotation_Mark", ["Quotation_Mark", "QMark"]],
  ["Radical", ["Radical"]],
  ["Regional_Indicator", ["Regional_Indicator", "RI"]],
  ["Sentence_Terminal", ["Sentence_Terminal", "STerm"]],
  ["Soft_Dotted", ["Soft_Dotted", "SD"]],
  ["Terminal_Punctuation", ["Terminal_Punctuation", "Term"]],
  ["Unified_Ideograph", ["Unified_Ideograph", "UIdeo"]],
  ["Uppercase", ["Uppercase", "Upper"]],
  ["Variation_Selector", ["Variation_Selector", "VS"]],
  ["White_Space", ["White_Space", "space"]],
  ["XID_Continue", ["XID_Continue", "XIDC"]],
  ["XID_Start", ["XID_Start", "XIDS"]],
];

const GENERAL_CATEGORIES = [
  ["C", ["C", "Other"]],
  ["Cc", ["Cc", "Control", "cntrl"]],
  ["Cf", ["Cf", "Format"]],
  ["Cn", ["Cn", "Unassigned"]],
  ["Co", ["Co", "Private_Use"]],
  ["Cs", ["Cs", "Surrogate"]],
  ["L", ["L", "Letter"]],
  ["LC", ["LC", "Cased_Letter"]],
  ["Ll", ["Ll", "Lowercase_Letter"]],
  ["Lm", ["Lm", "Modifier_Letter"]],
  ["Lo", ["Lo", "Other_Letter"]],
  ["Lt", ["Lt", "Titlecase_Letter"]],
  ["Lu", ["Lu", "Uppercase_Letter"]],
  ["M", ["M", "Mark", "Combining_Mark"]],
  ["Mc", ["Mc", "Spacing_Mark"]],
  ["Me", ["Me", "Enclosing_Mark"]],
  ["Mn", ["Mn", "Nonspacing_Mark"]],
  ["N", ["N", "Number"]],
  ["Nd", ["Nd", "Decimal_Number", "digit"]],
  ["Nl", ["Nl", "Letter_Number"]],
  ["No", ["No", "Other_Number"]],
  ["P", ["P", "Punctuation", "punct"]],
  ["Pc", ["Pc", "Connector_Punctuation"]],
  ["Pd", ["Pd", "Dash_Punctuation"]],
  ["Pe", ["Pe", "Close_Punctuation"]],
  ["Pf", ["Pf", "Final_Punctuation"]],
  ["Pi", ["Pi", "Initial_Punctuation"]],
  ["Po", ["Po", "Other_Punctuation"]],
  ["Ps", ["Ps", "Open_Punctuation"]],
  ["S", ["S", "Symbol"]],
  ["Sc", ["Sc", "Currency_Symbol"]],
  ["Sk", ["Sk", "Modifier_Symbol"]],
  ["Sm", ["Sm", "Math_Symbol"]],
  ["So", ["So", "Other_Symbol"]],
  ["Z", ["Z", "Separator"]],
  ["Zl", ["Zl", "Line_Separator"]],
  ["Zp", ["Zp", "Paragraph_Separator"]],
  ["Zs", ["Zs", "Space_Separator"]],
];

const SCRIPT_CODES = [
  ["Adlm", "Adlam"],
  ["Aghb", "Caucasian_Albanian"],
  ["Ahom", "Ahom"],
  ["Arab", "Arabic"],
  ["Armi", "Imperial_Aramaic"],
  ["Armn", "Armenian"],
  ["Avst", "Avestan"],
  ["Bali", "Balinese"],
  ["Bamu", "Bamum"],
  ["Bass", "Bassa_Vah"],
  ["Batk", "Batak"],
  ["Beng", "Bengali"],
  ["Berf", "Beria_Erfe"],
  ["Bhks", "Bhaiksuki"],
  ["Bopo", "Bopomofo"],
  ["Brah", "Brahmi"],
  ["Brai", "Braille"],
  ["Bugi", "Buginese"],
  ["Buhd", "Buhid"],
  ["Cakm", "Chakma"],
  ["Cans", "Canadian_Aboriginal"],
  ["Cari", "Carian"],
  ["Cham", "Cham"],
  ["Cher", "Cherokee"],
  ["Chrs", "Chorasmian"],
  ["Copt", "Coptic", "Qaac"],
  ["Cpmn", "Cypro_Minoan"],
  ["Cprt", "Cypriot"],
  ["Cyrl", "Cyrillic"],
  ["Deva", "Devanagari"],
  ["Diak", "Dives_Akuru"],
  ["Dogr", "Dogra"],
  ["Dsrt", "Deseret"],
  ["Dupl", "Duployan"],
  ["Egyp", "Egyptian_Hieroglyphs"],
  ["Elba", "Elbasan"],
  ["Elym", "Elymaic"],
  ["Ethi", "Ethiopic"],
  ["Gara", "Garay"],
  ["Geor", "Georgian"],
  ["Glag", "Glagolitic"],
  ["Gong", "Gunjala_Gondi"],
  ["Gonm", "Masaram_Gondi"],
  ["Goth", "Gothic"],
  ["Gran", "Grantha"],
  ["Grek", "Greek"],
  ["Gujr", "Gujarati"],
  ["Gukh", "Gurung_Khema"],
  ["Guru", "Gurmukhi"],
  ["Hang", "Hangul"],
  ["Hani", "Han"],
  ["Hano", "Hanunoo"],
  ["Hatr", "Hatran"],
  ["Hebr", "Hebrew"],
  ["Hira", "Hiragana"],
  ["Hluw", "Anatolian_Hieroglyphs"],
  ["Hmng", "Pahawh_Hmong"],
  ["Hmnp", "Nyiakeng_Puachue_Hmong"],
  ["Hung", "Old_Hungarian"],
  ["Ital", "Old_Italic"],
  ["Java", "Javanese"],
  ["Jurc", "Jurchen"],
  ["Kali", "Kayah_Li"],
  ["Kana", "Katakana"],
  ["Kawi", "Kawi"],
  ["Khar", "Kharoshthi"],
  ["Khmr", "Khmer"],
  ["Khoj", "Khojki"],
  ["Kits", "Khitan_Small_Script"],
  ["Knda", "Kannada"],
  ["Krai", "Kirat_Rai"],
  ["Kthi", "Kaithi"],
  ["Lana", "Tai_Tham"],
  ["Laoo", "Lao"],
  ["Latn", "Latin"],
  ["Lepc", "Lepcha"],
  ["Limb", "Limbu"],
  ["Lina", "Linear_A"],
  ["Linb", "Linear_B"],
  ["Lisu", "Lisu"],
  ["Lyci", "Lycian"],
  ["Lydi", "Lydian"],
  ["Mahj", "Mahajani"],
  ["Maka", "Makasar"],
  ["Mand", "Mandaic"],
  ["Mani", "Manichaean"],
  ["Marc", "Marchen"],
  ["Medf", "Medefaidrin"],
  ["Mend", "Mende_Kikakui"],
  ["Merc", "Meroitic_Cursive"],
  ["Mero", "Meroitic_Hieroglyphs"],
  ["Miao", "Miao", "Plrd"],
  ["Mlym", "Malayalam"],
  ["Modi", "Modi"],
  ["Mong", "Mongolian"],
  ["Mroo", "Mro"],
  ["Mtei", "Meetei_Mayek"],
  ["Mult", "Multani"],
  ["Mymr", "Myanmar"],
  ["Nagm", "Nag_Mundari"],
  ["Nand", "Nandinagari"],
  ["Narb", "Old_North_Arabian"],
  ["Nbat", "Nabataean"],
  ["Newa", "Newa"],
  ["Nkoo", "Nko"],
  ["Nshu", "Nushu"],
  ["Ogam", "Ogham"],
  ["Olck", "Ol_Chiki"],
  ["Onao", "Ol_Onal"],
  ["Orkh", "Old_Turkic"],
  ["Orya", "Oriya"],
  ["Osge", "Osage"],
  ["Osma", "Osmanya"],
  ["Ougr", "Old_Uyghur"],
  ["Palm", "Palmyrene"],
  ["Pauc", "Pau_Cin_Hau"],
  ["Pcun", "Proto_Cuneiform"],
  ["Perm", "Old_Permic"],
  ["Phag", "Phags_Pa"],
  ["Phli", "Inscriptional_Pahlavi"],
  ["Phlp", "Psalter_Pahlavi"],
  ["Phnx", "Phoenician"],
  ["Prti", "Inscriptional_Parthian"],
  ["Rjng", "Rejang"],
  ["Rohg", "Hanifi_Rohingya"],
  ["Runr", "Runic"],
  ["Samr", "Samaritan"],
  ["Sarb", "Old_South_Arabian"],
  ["Saur", "Saurashtra"],
  ["Seal", "Seal"],
  ["Sgnw", "SignWriting"],
  ["Shaw", "Shavian"],
  ["Shrd", "Sharada"],
  ["Sidd", "Siddham"],
  ["Sidt", "Sidetic"],
  ["Sind", "Khudawadi"],
  ["Sinh", "Sinhala"],
  ["Sogd", "Sogdian"],
  ["Sogo", "Old_Sogdian"],
  ["Sora", "Sora_Sompeng"],
  ["Soyo", "Soyombo"],
  ["Sund", "Sundanese"],
  ["Sunu", "Sunuwar"],
  ["Sylo", "Syloti_Nagri"],
  ["Syrc", "Syriac"],
  ["Tagb", "Tagbanwa"],
  ["Takr", "Takri"],
  ["Tale", "Tai_Le"],
  ["Talu", "New_Tai_Lue"],
  ["Taml", "Tamil"],
  ["Tang", "Tangut"],
  ["Tavt", "Tai_Viet"],
  ["Tayo", "Tai_Yo"],
  ["Telu", "Telugu"],
  ["Tfng", "Tifinagh"],
  ["Tglg", "Tagalog"],
  ["Thaa", "Thaana"],
  ["Thai", "Thai"],
  ["Tibt", "Tibetan"],
  ["Tirh", "Tirhuta"],
  ["Tnsa", "Tangsa"],
  ["Todr", "Todhri"],
  ["Tols", "Tolong_Siki"],
  ["Toto", "Toto"],
  ["Tutg", "Tulu_Tigalari"],
  ["Ugar", "Ugaritic"],
  ["Vaii", "Vai"],
  ["Vith", "Vithkuqi"],
  ["Wara", "Warang_Citi"],
  ["Wcho", "Wancho"],
  ["Xpeo", "Old_Persian"],
  ["Xsux", "Cuneiform"],
  ["Yezi", "Yezidi"],
  ["Yiii", "Yi"],
  ["Zanb", "Zanabazar_Square"],
  ["Zinh", "Inherited", "Qaai"],
  ["Zyyy", "Common"],
  ["Zzzz", "Unknown"],
];

// ---------------------------------------------------------------------------
// 2. Build segmented code-point strings for fast /\p{...}+/gu extraction
// ---------------------------------------------------------------------------

function makeRangeStr(lo, hi) {
  const parts = [];
  for (let cp = lo; cp <= hi; cp++) {
    parts.push(String.fromCodePoint(cp));
  }
  return parts.join("");
}

const bmpLowStr = makeRangeStr(0x0000, 0xd7ff);
const bmpHighStr = makeRangeStr(0xe000, 0xffff);
const astralStr = makeRangeStr(0x10000, 0x10ffff);

function extractSegment(re, str, baseCp, isAstral, out) {
  re.lastIndex = 0;
  let m;
  while ((m = re.exec(str)) !== null) {
    const startIdx = m.index;
    const endIdx = re.lastIndex;
    const lo = isAstral ? baseCp + (startIdx >> 1) : baseCp + startIdx;
    const hi = isAstral ? baseCp + (endIdx >> 1) - 1 : baseCp + endIdx - 1;
    out.push([lo, hi]);
  }
}

function mergeRanges(ranges) {
  if (ranges.length === 0) return ranges;
  const merged = [ranges[0]];
  for (let i = 1; i < ranges.length; i++) {
    const prev = merged[merged.length - 1];
    const cur = ranges[i];
    if (cur[0] <= prev[1] + 1) {
      if (cur[1] > prev[1]) prev[1] = cur[1];
    } else {
      merged.push(cur);
    }
  }
  return merged;
}

function extractRanges(spec) {
  const re = new RegExp(`\\p{${spec}}+`, "gu");
  const reSingle = new RegExp(`^\\p{${spec}}$`, "u");
  const out = [];
  extractSegment(re, bmpLowStr, 0x0000, false, out);
  if (reSingle.test("\ud800")) {
    out.push([0xd800, 0xdfff]);
  }
  extractSegment(re, bmpHighStr, 0xe000, false, out);
  extractSegment(re, astralStr, 0x10000, true, out);
  return mergeRanges(out);
}

// ---------------------------------------------------------------------------
// 3. Extract all properties & deduplicate identical range tables
// ---------------------------------------------------------------------------

const uniqueTables = []; // Array<Array<[lo, hi]>>
const keyToTableIdx = new Map();

function internRanges(ranges) {
  const key = ranges.map(([lo, hi]) => `${lo}:${hi}`).join(",");
  let idx = keyToTableIdx.get(key);
  if (idx === undefined) {
    idx = uniqueTables.length;
    keyToTableIdx.set(key, idx);
    uniqueTables.push(ranges);
  }
  return idx;
}

const binEntries = []; // [name, tableIdx]
for (const [canon, aliases] of BINARY_PROPS) {
  const tid = internRanges(extractRanges(canon));
  for (const a of aliases) binEntries.push([a, tid]);
}

const gcEntries = []; // [name, tableIdx]
for (const [canon, aliases] of GENERAL_CATEGORIES) {
  const tid = internRanges(extractRanges(`gc=${canon}`));
  for (const a of aliases) gcEntries.push([a, tid]);
}

const scEntries = []; // [name, tableIdx]
const scxEntries = []; // [name, tableIdx]
for (const aliases of SCRIPT_CODES) {
  const canon = aliases[0];
  try {
    new RegExp(`\\p{sc=${canon}}`, "u");
  } catch {
    continue;
  }
  const scTid = internRanges(extractRanges(`sc=${canon}`));
  const scxTid = internRanges(extractRanges(`scx=${canon}`));
  for (const a of aliases) {
    scEntries.push([a, scTid]);
    scxEntries.push([a, scxTid]);
  }
}

// ---------------------------------------------------------------------------
// 4. Extract v-mode properties of strings (where enumerable)
// ---------------------------------------------------------------------------

function extractPropertiesOfStrings() {
  const result = {};

  {
    const reBasic = /^\p{Basic_Emoji}$/v;
    const reEmoji = /\p{Emoji}/u;
    const seqs = [];
    for (let cp = 0; cp <= 0x10ffff; cp++) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      const s = String.fromCodePoint(cp);
      if (reBasic.test(s)) seqs.push([cp]);
      if (reEmoji.test(s) && reBasic.test(s + "\ufe0f")) seqs.push([cp, 0xfe0f]);
    }
    result.Basic_Emoji = seqs;
  }

  {
    const re = /^\p{Emoji_Keycap_Sequence}$/v;
    const seqs = [];
    for (const cp of [0x23, 0x2a, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]) {
      if (re.test(String.fromCodePoint(cp, 0xfe0f, 0x20e3))) {
        seqs.push([cp, 0xfe0f, 0x20e3]);
      }
    }
    result.Emoji_Keycap_Sequence = seqs;
  }

  {
    const re = /^\p{RGI_Emoji_Modifier_Sequence}$/v;
    const reEBase = /\p{Emoji_Modifier_Base}/u;
    const mods = [0x1f3fb, 0x1f3fc, 0x1f3fd, 0x1f3fe, 0x1f3ff];
    const seqs = [];
    for (let cp = 0; cp <= 0x10ffff; cp++) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      const s = String.fromCodePoint(cp);
      if (reEBase.test(s)) {
        for (const m of mods) {
          if (re.test(s + String.fromCodePoint(m))) seqs.push([cp, m]);
        }
      }
    }
    result.RGI_Emoji_Modifier_Sequence = seqs;
  }

  {
    const re = /^\p{RGI_Emoji_Flag_Sequence}$/v;
    const seqs = [];
    for (let a = 0x1f1e6; a <= 0x1f1ff; a++) {
      for (let b = 0x1f1e6; b <= 0x1f1ff; b++) {
        if (re.test(String.fromCodePoint(a, b))) seqs.push([a, b]);
      }
    }
    result.RGI_Emoji_Flag_Sequence = seqs;
  }

  {
    const re = /^\p{RGI_Emoji_Tag_Sequence}$/v;
    const seqs = [];
    for (const tag of ["gbeng", "gbsct", "gbwls"]) {
      const cps = [0x1f3f4, ...[...tag].map((c) => 0xe0000 + c.charCodeAt(0)), 0xe007f];
      if (re.test(String.fromCodePoint(...cps))) seqs.push(cps);
    }
    result.RGI_Emoji_Tag_Sequence = seqs;
  }

  return result;
}

const propsOfStrings = extractPropertiesOfStrings();

// ---------------------------------------------------------------------------
// 5. Extract case folding tables (/iu and legacy /i)
// ---------------------------------------------------------------------------

function compressFoldMap(mapEntries, mapObj) {
  const runs = [];
  for (let i = 0; i < mapEntries.length; ) {
    const [lo, target0] = mapEntries[i];
    const delta = target0 - lo;
    let hi = lo;
    if (i + 1 < mapEntries.length && mapEntries[i + 1][1] - mapEntries[i + 1][0] === delta) {
      const d = mapEntries[i + 1][0] - lo;
      if (d === 1) {
        let j = i + 1;
        while (
          j < mapEntries.length &&
          mapEntries[j][0] === hi + 1 &&
          mapEntries[j][1] - mapEntries[j][0] === delta
        ) {
          hi = mapEntries[j][0];
          j++;
        }
        runs.push({ lo, hi, step: 1, delta });
        i = j;
        continue;
      } else if (d === 2 && !mapObj.has(lo + 1)) {
        let j = i + 1;
        while (
          j < mapEntries.length &&
          mapEntries[j][0] === hi + 2 &&
          !mapObj.has(hi + 1) &&
          mapEntries[j][1] - mapEntries[j][0] === delta
        ) {
          hi = mapEntries[j][0];
          j++;
        }
        runs.push({ lo, hi, step: 2, delta });
        i = j;
        continue;
      }
    }
    runs.push({ lo, hi, step: 1, delta });
    i++;
  }
  return runs;
}

function extractUnicodeFoldRuns() {
  const reCased = /^\p{Cased}$/u;
  const reCwcf = /^\p{CWCF}$/u;
  const candidates = [];
  for (let cp = 0; cp <= 0x10ffff; cp++) {
    const s = String.fromCodePoint(cp);
    if (reCased.test(s) || reCwcf.test(s) || s.toLowerCase() !== s || s.toUpperCase() !== s) {
      candidates.push(cp);
    }
  }
  const allStr = candidates.map((cp) => String.fromCodePoint(cp)).join("");
  const visited = new Set();
  const canonMap = new Map();
  for (const cp of candidates) {
    if (visited.has(cp)) continue;
    const re = new RegExp(`\\u{${cp.toString(16)}}`, "giu");
    const matches = allStr.match(re);
    if (matches && matches.length > 1) {
      const cls = matches.map((m) => m.codePointAt(0)).sort((a, b) => a - b);
      for (const c of cls) visited.add(c);
      const nonCwcf = cls.filter((c) => !reCwcf.test(String.fromCodePoint(c)));
      const target = nonCwcf.length === 1 ? nonCwcf[0] : cls[0];
      for (const c of cls) {
        if (c !== target) canonMap.set(c, target);
      }
    } else {
      visited.add(cp);
    }
  }
  const entries = [...canonMap.entries()]
    .filter(([k]) => k >= 128)
    .sort((a, b) => a[0] - b[0]);
  return compressFoldMap(entries, canonMap);
}

function extractLegacyFoldRuns() {
  const canonMap = new Map();
  for (let cu = 0; cu <= 0xffff; cu++) {
    const u = String.fromCharCode(cu).toUpperCase();
    if (u.length === 1) {
      const ucu = u.charCodeAt(0);
      if (ucu !== cu && !(cu >= 128 && ucu < 128)) {
        canonMap.set(cu, ucu);
      }
    }
  }
  const entries = [...canonMap.entries()]
    .filter(([k]) => k >= 128)
    .sort((a, b) => a[0] - b[0]);
  return compressFoldMap(entries, canonMap);
}

const unicodeFoldRuns = extractUnicodeFoldRuns();
const legacyFoldRuns = extractLegacyFoldRuns();

// ---------------------------------------------------------------------------
// 6. Pack src/regex_unicode.bin (4-byte aligned, little-endian)
// ---------------------------------------------------------------------------

class BinBuilder {
  constructor() {
    this.chunks = [];
    this.offset = 0;
  }
  align4() {
    const pad = (4 - (this.offset & 3)) & 3;
    if (pad > 0) {
      this.chunks.push(Buffer.alloc(pad));
      this.offset += pad;
    }
  }
  writeBuf(buf) {
    const off = this.offset;
    this.chunks.push(buf);
    this.offset += buf.length;
    return off;
  }
  writeU32Array(arr) {
    this.align4();
    const buf = Buffer.allocUnsafe(arr.length * 4);
    for (let i = 0; i < arr.length; i++) {
      buf.writeUInt32LE(arr[i] >>> 0, i * 4);
    }
    return this.writeBuf(buf);
  }
  reserve(byteLen) {
    this.align4();
    const off = this.offset;
    const buf = Buffer.alloc(byteLen);
    this.chunks.push(buf);
    this.offset += byteLen;
    return { off, buf };
  }
  toBuffer() {
    return Buffer.concat(this.chunks);
  }
}

const bin = new BinBuilder();
// Header: 12 x u32 = 48 bytes
// [0..1] unicode_fold (off, len)
// [2..3] legacy_fold (off, len)
// [4..5] bin_map (off, len)
// [6..7] gc_map (off, len)
// [8..9] sc_map (off, len)
// [10..11] scx_map (off, len)
const header = bin.reserve(12 * 4);

function writeFoldRuns(runs) {
  bin.align4();
  const off = bin.offset;
  const buf = Buffer.allocUnsafe(runs.length * 12);
  for (let i = 0; i < runs.length; i++) {
    const r = runs[i];
    const loStep = (r.lo >>> 0) | (r.step === 2 ? 1 << 21 : 0);
    buf.writeUInt32LE(loStep >>> 0, i * 12);
    buf.writeUInt32LE(r.hi >>> 0, i * 12 + 4);
    buf.writeInt32LE(r.delta, i * 12 + 8);
  }
  bin.writeBuf(buf);
  return [off, runs.length];
}

const [uFoldOff, uFoldLen] = writeFoldRuns(unicodeFoldRuns);
const [lFoldOff, lFoldLen] = writeFoldRuns(legacyFoldRuns);

// Write all unique range tables
const tableSpans = []; // [byteOff, rangeCount]
for (const ranges of uniqueTables) {
  bin.align4();
  const off = bin.offset;
  const buf = Buffer.allocUnsafe(ranges.length * 8);
  for (let i = 0; i < ranges.length; i++) {
    buf.writeUInt32LE(ranges[i][0] >>> 0, i * 8);
    buf.writeUInt32LE(ranges[i][1] >>> 0, i * 8 + 4);
  }
  bin.writeBuf(buf);
  tableSpans.push([off, ranges.length]);
}

// Intern property name strings
const strOffsetMap = new Map();
function internString(s) {
  let info = strOffsetMap.get(s);
  if (!info) {
    const b = Buffer.from(s, "utf8");
    const off = bin.writeBuf(b);
    info = [off, b.length];
    strOffsetMap.set(s, info);
  }
  return info;
}

function writeMap(entries) {
  const sorted = [...entries].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  // Intern strings first
  const resolved = sorted.map(([name, tid]) => {
    const [kOff, kLen] = internString(name);
    const [dOff, dLen] = tableSpans[tid];
    return [kOff, kLen, dOff, dLen];
  });
  bin.align4();
  const off = bin.offset;
  const buf = Buffer.allocUnsafe(resolved.length * 16);
  for (let i = 0; i < resolved.length; i++) {
    const [kOff, kLen, dOff, dLen] = resolved[i];
    buf.writeUInt32LE(kOff >>> 0, i * 16);
    buf.writeUInt32LE(kLen >>> 0, i * 16 + 4);
    buf.writeUInt32LE(dOff >>> 0, i * 16 + 8);
    buf.writeUInt32LE(dLen >>> 0, i * 16 + 12);
  }
  bin.writeBuf(buf);
  return [off, resolved.length];
}

const [binMapOff, binMapLen] = writeMap(binEntries);
const [gcMapOff, gcMapLen] = writeMap(gcEntries);
const [scMapOff, scMapLen] = writeMap(scEntries);
const [scxMapOff, scxMapLen] = writeMap(scxEntries);

// Write string properties (Flat code points + sequence lengths)
const strPropSpans = {};
for (const [name, seqs] of Object.entries(propsOfStrings)) {
  const flatCps = [];
  const seqLens = [];
  for (const seq of seqs) {
    seqLens.push(seq.length);
    for (const cp of seq) flatCps.push(cp);
  }
  const cpsOff = bin.writeU32Array(flatCps);
  const lensOff = bin.writeU32Array(seqLens);
  strPropSpans[name] = { cpsOff, cpsLen: flatCps.length, lensOff, seqCount: seqs.length };
}

const hdrVals = [
  uFoldOff, uFoldLen,
  lFoldOff, lFoldLen,
  binMapOff, binMapLen,
  gcMapOff, gcMapLen,
  scMapOff, scMapLen,
  scxMapOff, scxMapLen,
];
for (let i = 0; i < hdrVals.length; i++) {
  header.buf.writeUInt32LE(hdrVals[i] >>> 0, i * 4);
}

const binBuf = bin.toBuffer();
const binPath = path.resolve(__dirname, "..", "src", "regex_unicode.bin");
fs.writeFileSync(binPath, binBuf);

// ---------------------------------------------------------------------------
// 7. Emit compact src/regex_unicode.zig
// ---------------------------------------------------------------------------

const zigSrc = `// Generated by tools/gen_regex_unicode.js (Node ${process.version}, Unicode ${process.versions.unicode}).
// Do not edit manually.

const std = @import("std");

const bin align(4) = @embedFile("regex_unicode.bin").*;

pub const Range = extern struct {
    lo: u32,
    hi: u32,
};

const FoldRun = extern struct {
    lo_step: u32,
    hi: u32,
    delta: i32,
};

const MapEntry = extern struct {
    key_off: u32,
    key_len: u32,
    data_off: u32,
    data_len: u32,
};

const Header = extern struct {
    unicode_fold_off: u32,
    unicode_fold_len: u32,
    legacy_fold_off: u32,
    legacy_fold_len: u32,
    bin_map_off: u32,
    bin_map_len: u32,
    gc_map_off: u32,
    gc_map_len: u32,
    sc_map_off: u32,
    sc_map_len: u32,
    scx_map_off: u32,
    scx_map_len: u32,
};

const header: *const Header = @ptrCast(&bin);

fn sliceAs(comptime T: type, off: u32, count: u32) []const T {
    const start: usize = off;
    const end: usize = start + @as(usize, count) * @sizeOf(T);
    const bytes: []align(4) const u8 = @alignCast(bin[start..end]);
    return std.mem.bytesAsSlice(T, bytes);
}

/// Binary search over sorted, non-overlapping, inclusive Unicode code point ranges.
pub fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn applyFoldRuns(cp: u21, runs: []const FoldRun) u21 {
    var lo: usize = 0;
    var hi: usize = runs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = runs[mid];
        const r_lo: u21 = @intCast(r.lo_step & 0x1FFFFF);
        if (cp < r_lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            const step2 = (r.lo_step >> 21) != 0;
            if (!step2 or ((cp - r_lo) & 1) == 0) {
                return @intCast(@as(i32, cp) + r.delta);
            }
            return cp;
        }
    }
    return cp;
}

/// ECMAScript Canonicalize(rer, ch) when Unicode is true (Simple Case Folding).
pub fn canonicalizeUnicode(cp: u21) u21 {
    if (cp < 128) {
        if (cp >= 'A' and cp <= 'Z') return cp + 32;
        return cp;
    }
    const runs = sliceAs(FoldRun, header.unicode_fold_off, header.unicode_fold_len);
    return applyFoldRuns(cp, runs);
}

/// ECMAScript Canonicalize(rer, ch) when Unicode is false (legacy UTF-16 toUpperCase).
pub fn canonicalizeLegacy(cu: u16) u16 {
    if (cu < 128) {
        if (cu >= 'a' and cu <= 'z') return cu - 32;
        return cu;
    }
    const runs = sliceAs(FoldRun, header.legacy_fold_off, header.legacy_fold_len);
    return @intCast(applyFoldRuns(cu, runs));
}

pub fn matchesIcaseUnicode(a: u21, b: u21) bool {
    return canonicalizeUnicode(a) == canonicalizeUnicode(b);
}

pub fn matchesIcaseLegacy(a: u16, b: u16) bool {
    return canonicalizeLegacy(a) == canonicalizeLegacy(b);
}

fn lookupMap(entries: []const MapEntry, key: []const u8) ?[]const Range {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = entries[mid];
        const e_key = bin[e.key_off .. e.key_off + e.key_len];
        switch (std.mem.order(u8, key, e_key)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return sliceAs(Range, e.data_off, e.data_len),
        }
    }
    return null;
}

/// Look up a Unicode property escape specification (the raw text inside \\p{...}).
pub fn lookupProperty(spec: []const u8) ?[]const Range {
    if (std.mem.indexOfScalar(u8, spec, '=')) |eq| {
        const prop = spec[0..eq];
        const val = spec[eq + 1 ..];
        if (std.mem.eql(u8, prop, "gc") or std.mem.eql(u8, prop, "General_Category")) {
            return lookupMap(sliceAs(MapEntry, header.gc_map_off, header.gc_map_len), val);
        }
        if (std.mem.eql(u8, prop, "sc") or std.mem.eql(u8, prop, "Script")) {
            return lookupMap(sliceAs(MapEntry, header.sc_map_off, header.sc_map_len), val);
        }
        if (std.mem.eql(u8, prop, "scx") or std.mem.eql(u8, prop, "Script_Extensions")) {
            return lookupMap(sliceAs(MapEntry, header.scx_map_off, header.scx_map_len), val);
        }
        return null;
    }
    return lookupMap(sliceAs(MapEntry, header.bin_map_off, header.bin_map_len), spec) orelse
        lookupMap(sliceAs(MapEntry, header.gc_map_off, header.gc_map_len), spec);
}

fn buildStringProp(
    comptime cps_off: u32,
    comptime cps_len: u32,
    comptime lens_off: u32,
    comptime seq_count: u32,
) []const []const u21 {
    return comptime blk: {
        @setEvalBranchQuota(@max(10000, (cps_len + seq_count) * 4));
        const raw_cps = sliceAs(u32, cps_off, cps_len);
        const raw_lens = sliceAs(u32, lens_off, seq_count);
        var flat: [cps_len]u21 = undefined;
        for (raw_cps, 0..) |cp, i| flat[i] = @intCast(cp);
        const flat_const = flat;
        var slices: [seq_count][]const u21 = undefined;
        var pos: usize = 0;
        for (raw_lens, 0..) |l, i| {
            slices[i] = flat_const[pos .. pos + l];
            pos += l;
        }
        const slices_const = slices;
        break :blk &slices_const;
    };
}

const prop_strings_map = std.StaticStringMap([]const []const u21).initComptime(.{
${Object.entries(strPropSpans)
  .map(
    ([name, s]) =>
      `    .{ "${name}", buildStringProp(${s.cpsOff}, ${s.cpsLen}, ${s.lensOff}, ${s.seqCount}) },`
  )
  .join("\n")}
});

/// Look up a v-mode Unicode property of strings, or null for code-point-only/unsupported properties.
pub fn lookupPropertyOfStrings(spec: []const u8) ?[]const []const u21 {
    return prop_strings_map.get(spec);
}

test "inRanges basic" {
    const ascii = lookupProperty("ASCII").?;
    try std.testing.expect(inRanges(0, ascii));
    try std.testing.expect(inRanges('A', ascii));
    try std.testing.expect(inRanges(127, ascii));
    try std.testing.expect(!inRanges(128, ascii));
    try std.testing.expect(!inRanges(0x10FFFF, ascii));
}

test "case folding unicode and legacy" {
    try std.testing.expect(matchesIcaseUnicode('k', 'K'));
    try std.testing.expect(matchesIcaseUnicode('k', 0x212A));
    try std.testing.expect(matchesIcaseUnicode('K', 0x212A));
    try std.testing.expect(matchesIcaseLegacy('k', 'K'));
    try std.testing.expect(!matchesIcaseLegacy('k', 0x212A));

    try std.testing.expect(matchesIcaseUnicode('s', 'S'));
    try std.testing.expect(matchesIcaseUnicode('s', 0x017F));
    try std.testing.expect(matchesIcaseLegacy('s', 'S'));
    try std.testing.expect(!matchesIcaseLegacy('s', 0x017F));

    try std.testing.expect(matchesIcaseUnicode(0x00E9, 0x00C9));
    try std.testing.expect(matchesIcaseLegacy(0x00E9, 0x00C9));

    try std.testing.expect(matchesIcaseUnicode(0x03A3, 0x03C3));
    try std.testing.expect(matchesIcaseUnicode(0x03A3, 0x03C2));
    try std.testing.expect(matchesIcaseUnicode(0x03C3, 0x03C2));
    try std.testing.expect(matchesIcaseLegacy(0x03A3, 0x03C3));
    try std.testing.expect(matchesIcaseLegacy(0x03A3, 0x03C2));
    try std.testing.expect(matchesIcaseLegacy(0x03C3, 0x03C2));

    try std.testing.expect(matchesIcaseUnicode(0x10400, 0x10428));
    try std.testing.expect(matchesIcaseUnicode(0x1E900, 0x1E922));
    try std.testing.expect(!matchesIcaseUnicode(0x10400, 0x1E900));
}

test "lookupProperty categories and aliases" {
    try std.testing.expectEqual(lookupProperty("L").?, lookupProperty("Letter").?);
    try std.testing.expectEqual(lookupProperty("L").?, lookupProperty("General_Category=Letter").?);
    try std.testing.expectEqual(lookupProperty("Lu").?, lookupProperty("gc=Lu").?);
    try std.testing.expectEqual(lookupProperty("Script=Greek").?, lookupProperty("sc=Grek").?);
    try std.testing.expectEqual(lookupProperty("Script_Extensions=Han").?, lookupProperty("scx=Hani").?);
    try std.testing.expect(lookupProperty("White_Space") != null);
    try std.testing.expectEqual(lookupProperty("White_Space").?, lookupProperty("space").?);
    try std.testing.expect(lookupProperty("Emoji") != null);
    try std.testing.expect(lookupProperty("Greek") == null);
    try std.testing.expect(lookupProperty("gc=Invalid") == null);
    try std.testing.expect(lookupProperty("Foo=Bar") == null);

    try std.testing.expect(inRanges(0x03B1, lookupProperty("sc=Greek").?));
    try std.testing.expect(inRanges(0x1F600, lookupProperty("Emoji").?));
    try std.testing.expect(inRanges(0x0020, lookupProperty("White_Space").?));
    try std.testing.expect(inRanges(0xD800, lookupProperty("Cs").?));
    try std.testing.expect(!inRanges(0xD800, lookupProperty("Cn").?));
}

test "lookupPropertyOfStrings" {
    try std.testing.expect(lookupPropertyOfStrings("Basic_Emoji") != null);
    try std.testing.expect(lookupPropertyOfStrings("Emoji_Keycap_Sequence") != null);
    try std.testing.expect(lookupPropertyOfStrings("RGI_Emoji_Modifier_Sequence") != null);
    try std.testing.expect(lookupPropertyOfStrings("RGI_Emoji_Flag_Sequence") != null);
    try std.testing.expect(lookupPropertyOfStrings("RGI_Emoji_Tag_Sequence") != null);
    try std.testing.expect(lookupPropertyOfStrings("ASCII") == null);
}
`;

const zigPath = path.resolve(__dirname, "..", "src", "regex_unicode.zig");
fs.writeFileSync(zigPath, zigSrc);
execFileSync("zig", ["fmt", zigPath]);
console.log(
  `Generated ${binPath} (${binBuf.length} bytes) and ${zigPath}: ` +
    `${uniqueTables.length} unique range tables, ${unicodeFoldRuns.length} unicode fold runs, ` +
    `${legacyFoldRuns.length} legacy fold runs in ${Date.now() - tStart} ms`
);
